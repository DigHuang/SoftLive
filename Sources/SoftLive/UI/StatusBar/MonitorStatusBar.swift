import AppKit
import Observation
import SwiftUI

/// Non-activating floating popover panel for `MonitorStatusBar`.
/// Using `.nonactivatingPanel` avoids calling `NSApp.activate()`, which on notched MacBooks
/// would otherwise replace the foreground app's menu bar and cause macOS WindowServer to
/// reflow/teleport status bar items across the camera notch on click.
private final class MonitorPopoverPanel: NSPanel {
    private static let outsideDismissSuppressionWindow: Duration = .milliseconds(300)
    private static let postShowIgnoreWindow: Duration = .milliseconds(150)

    var onClose: (() -> Void)?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private weak var statusBarWindow: NSWindow?
    private weak var statusBarButton: NSStatusBarButton?
    private var hostView: FirstMouseHostingView<MonitorPopoverView>?
    private var lastShowTime: ContinuousClock.Instant?
    private var lastOutsideDismissTime: ContinuousClock.Instant?
    private var openingEventNumber: Int?

    init(rootView: MonitorPopoverView) {
        let size = MonitorPopoverView.panelSize
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false

        var view = rootView
        view.onActiveHeightChange = { [weak self] activeHeight in
            self?.hostView?.activeTopHeight = activeHeight
        }
        let host = FirstMouseHostingView(rootView: view)
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        contentView = host
        hostView = host
    }

    override var canBecomeKey: Bool { true }

    func show(below button: NSStatusBarButton, now: ContinuousClock.Instant = .now) {
        statusBarWindow = button.window
        statusBarButton = button
        lastOutsideDismissTime = nil
        lastShowTime = now
        let eventNumber = NSApp.currentEvent?.eventNumber ?? 0
        openingEventNumber = eventNumber != 0 ? eventNumber : nil
        let size = MonitorPopoverView.panelSize
        let margin = MonitorPopoverView.margin
        if let buttonWindow = button.window {
            let buttonFrame = buttonWindow.frame
            let screenFrame = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
            var x = buttonFrame.midX - size.width / 2
            if screenFrame.width > 0 {
                x = min(max(x, screenFrame.minX + 8 - margin), screenFrame.maxX - size.width - 8 + margin)
            }
            let y = buttonFrame.minY - size.height + margin - 6
            setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        }
        contentView?.isHidden = false
        makeKeyAndOrderFront(nil)
        button.highlight(true)
        DispatchQueue.main.async { [weak self, weak button] in
            if self?.isVisible == true {
                button?.highlight(true)
            }
        }
        installMonitors()
    }

    func dismiss(fromOutsideClick: Bool = false, now: ContinuousClock.Instant = .now) {
        removeMonitors()
        clearButtonHighlight()
        guard isVisible else { return }
        lastOutsideDismissTime = fromOutsideClick ? now : nil
        contentView?.isHidden = true
        orderOut(nil)
        onClose?()
    }

    func consumeRecentOutsideDismiss(now: ContinuousClock.Instant = .now) -> Bool {
        guard let lastOutsideDismissTime else { return false }
        self.lastOutsideDismissTime = nil
        let isRecent = now - lastOutsideDismissTime < Self.outsideDismissSuppressionWindow
        if isRecent {
            clearButtonHighlight()
        }
        return isRecent
    }

    private func clearButtonHighlight() {
        let button = statusBarButton
        button?.highlight(false)
        DispatchQueue.main.async { [weak self, weak button] in
            if self?.isVisible != true {
                button?.highlight(false)
            }
        }
    }

    private func isPointInsideCard(_ pointInWindow: NSPoint) -> Bool {
        let margin = MonitorPopoverView.margin
        let fromTop = frame.height - pointInWindow.y
        let maxTop = (hostView?.activeTopHeight ?? frame.height) - margin
        return pointInWindow.x >= margin
            && pointInWindow.x <= frame.width - margin
            && fromTop >= margin
            && fromTop <= maxTop
    }

    private func isOpeningClickEvent(_ event: NSEvent, now: ContinuousClock.Instant = .now) -> Bool {
        guard let lastShowTime, now - lastShowTime < Self.postShowIgnoreWindow else {
            return false
        }
        if let openingEventNumber, event.eventNumber == openingEventNumber {
            return true
        }
        if let eventWindow = event.window,
           eventWindow === statusBarWindow || eventWindow === statusBarButton?.window {
            return true
        }
        if let buttonWindow = statusBarButton?.window ?? statusBarWindow {
            return buttonWindow.frame.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation)
        }
        return false
    }

    private func installMonitors() {
        removeMonitors()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, !self.isOpeningClickEvent(event) else { return }
            self.dismiss(fromOutsideClick: true)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            if event.type == .leftMouseUp {
                if self.isVisible {
                    let btn = self.statusBarButton
                    DispatchQueue.main.async { [weak self, weak btn] in
                        if self?.isVisible == true {
                            btn?.highlight(true)
                        }
                    }
                }
                return event
            }
            if event.type == .keyDown {
                if event.keyCode == 53 {
                    self.dismiss()
                    return nil
                }
                return event
            }
            if self.isOpeningClickEvent(event) {
                return event
            }
            if event.window === self, self.isPointInsideCard(event.locationInWindow) {
                return event
            }
            self.dismiss(fromOutsideClick: true)
            return event
        }
    }

    private func removeMonitors() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    isolated deinit {
        removeMonitors()
    }
}

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    var activeTopHeight: CGFloat?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let fromTop = isFlipped ? local.y : bounds.height - local.y
        let margin = MonitorPopoverView.margin
        let maxTop = (activeTopHeight ?? bounds.height) - margin
        if local.x < margin || local.x > bounds.width - margin || fromTop < margin || fromTop > maxTop {
            return nil
        }
        return super.hitTest(point)
    }
}

final class MonitorStatusBar: NSObject {
    static let fullWidth: CGFloat = 60
    static let barsOnlyWidth: CGFloat = 20
    private static let itemHeight: CGFloat = 22
    private static let rateFont = NSFont.monospacedDigitSystemFont(ofSize: 8.0, weight: .semibold)
    private static let arrowFont = NSFont.systemFont(ofSize: 7.5, weight: .semibold)
    private static let rightParagraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        style.lineBreakMode = .byClipping
        return style
    }()
    private static let leftParagraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.alignment = .left
        style.lineBreakMode = .byClipping
        return style
    }()
    private static let rightAttributes: [NSAttributedString.Key: Any] = [
        .font: rateFont,
        .foregroundColor: NSColor.labelColor,
        .paragraphStyle: rightParagraphStyle,
    ]
    private static let arrowAttributes: [NSAttributedString.Key: Any] = [
        .font: arrowFont,
        .foregroundColor: NSColor.labelColor.withAlphaComponent(0.58),
        .paragraphStyle: leftParagraphStyle,
    ]

    private static let frostAccent = adaptiveColor(
        light: (0.05, 0.47, 0.58),
        dark: (0.36, 0.80, 0.92)
    )
    private static let frostWarning = adaptiveColor(
        light: (0.70, 0.40, 0.02),
        dark: (0.96, 0.72, 0.24)
    )
    private static let frostCritical = adaptiveColor(
        light: (0.82, 0.19, 0.22),
        dark: (0.97, 0.43, 0.44)
    )

    private static func adaptiveColor(
        light: (CGFloat, CGFloat, CGFloat),
        dark: (CGFloat, CGFloat, CGFloat)
    ) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let rgb = isDark ? dark : light
            return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        }
    }

    enum BarTone: Equatable {
        case monochrome
        case accent
        case warning
        case critical
    }

    struct DisplayKey: Equatable {
        let style: MonitorStatusBarStyle
        let coloredBars: Bool
        let upText: String
        let downText: String
        let cpuBarSteps: Int
        let ramBarSteps: Int
        let tmpBarSteps: Int
        let cpuTone: BarTone
        let ramTone: BarTone
        let tmpTone: BarTone

        var isTemplate: Bool {
            cpuTone == .monochrome && ramTone == .monochrome && tmpTone == .monochrome
        }

        init(
            metrics: SystemMetrics,
            style: MonitorStatusBarStyle = .rateAndBars,
            coloredBars: Bool = false,
            cpuThreshold: Double = MonitorCPUAlertThreshold.standard.fraction,
            ramThreshold: Double = MonitorRAMAlertThreshold.standard.fraction,
            thermalThreshold: Double = MonitorThermalAlertThreshold.standard.celsius
        ) {
            self.style = style
            self.coloredBars = coloredBars
            upText = style == .rateAndBars ? SystemMetrics.formatCompactRate(metrics.uploadBytesPerSec) : ""
            downText = style == .rateAndBars ? SystemMetrics.formatCompactRate(metrics.downloadBytesPerSec) : ""
            cpuBarSteps = Self.barStep(for: metrics.cpuUsage)
            ramBarSteps = Self.barStep(for: metrics.memoryUsage)
            tmpBarSteps = Self.barStep(for: SystemMetrics.thermalProgress(metrics.temperatureCelsius))

            if metrics.cpuUsage >= cpuThreshold {
                cpuTone = .critical
            } else if coloredBars {
                cpuTone = metrics.cpuUsage >= max(0.55, cpuThreshold - 0.15) ? .warning : .accent
            } else {
                cpuTone = .monochrome
            }

            switch metrics.memoryPressure {
            case .critical:
                ramTone = .critical
            case .warning:
                ramTone = .warning
            case .normal:
                if metrics.memoryUsage >= ramThreshold {
                    ramTone = .warning
                } else {
                    ramTone = coloredBars ? .accent : .monochrome
                }
            }

            let temp = metrics.temperatureCelsius ?? 0
            if temp >= thermalThreshold {
                tmpTone = .critical
            } else if coloredBars {
                tmpTone = temp >= max(55, thermalThreshold - 10) ? .warning : .accent
            } else {
                tmpTone = .monochrome
            }
        }

        private static func barStep(for fraction: Double) -> Int {
            let clamped = min(max(fraction, 0), 1)
            guard clamped > 0.01 else { return 0 }
            return max(1, Int((clamped * 17).rounded()))
        }
    }

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let monitor: SystemMonitor
    private let menu: NSMenu
    private var panel: MonitorPopoverPanel?
    private var observeTask: Task<Void, Never>?
    private var lastDisplayKey: DisplayKey?

    init(
        monitor: SystemMonitor,
        preferences: Preferences,
        menu: NSMenu,
        onOpenSettings: (() -> Void)? = nil
    ) {
        self.monitor = monitor
        self.menu = menu
        super.init()

        let initialKey = DisplayKey(
            metrics: monitor.metrics,
            style: preferences.monitorStatusBarStyle,
            coloredBars: preferences.monitorColoredBars,
            cpuThreshold: preferences.monitorCPUAlertThreshold.fraction,
            ramThreshold: preferences.monitorRAMAlertThreshold.fraction,
            thermalThreshold: preferences.monitorThermalAlertThreshold.celsius
        )
        lastDisplayKey = initialKey
        item.isVisible = preferences.showsSystemMonitor
        item.button?.image = Self.renderImage(for: monitor.metrics, key: initialKey)
        item.button?.toolTip = Self.tooltipText(for: monitor.metrics)
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.sendAction(on: [.leftMouseDown, .rightMouseUp])

        let popoverPanel = MonitorPopoverPanel(
            rootView: MonitorPopoverView(
                monitor: monitor,
                preferences: preferences,
                onOpenSettings: { [weak self] in
                    self?.panel?.dismiss()
                    onOpenSettings?()
                }
            )
        )
        popoverPanel.onClose = { [weak monitor] in
            monitor?.setDetailActive(false)
        }
        self.panel = popoverPanel

        observeTask = Task { [weak self] in
            for await (metrics, visible, style, coloredBars, cpuAlert, ramAlert, thermalAlert, _) in Observations({
                (
                    monitor.metrics,
                    preferences.showsSystemMonitor,
                    preferences.monitorStatusBarStyle,
                    preferences.monitorColoredBars,
                    preferences.monitorCPUAlertThreshold.fraction,
                    preferences.monitorRAMAlertThreshold.fraction,
                    preferences.monitorThermalAlertThreshold.celsius,
                    L10n.resolved
                )
            }) {
                guard let self else { return }
                if self.item.isVisible != visible {
                    self.item.isVisible = visible
                }
                guard visible else {
                    self.panel?.dismiss()
                    continue
                }
                let nextTooltip = Self.tooltipText(for: metrics)
                if self.item.button?.toolTip != nextTooltip {
                    self.item.button?.toolTip = nextTooltip
                }
                let key = DisplayKey(
                    metrics: metrics,
                    style: style,
                    coloredBars: coloredBars,
                    cpuThreshold: cpuAlert,
                    ramThreshold: ramAlert,
                    thermalThreshold: thermalAlert
                )
                guard key != self.lastDisplayKey else { continue }
                self.lastDisplayKey = key
                self.item.button?.image = Self.renderImage(for: metrics, key: key)
            }
        }
    }

    var isPopoverVisible: Bool {
        panel?.isVisible ?? false
    }

    func handleLeftClick(now: ContinuousClock.Instant = .now) {
        guard let button = item.button, let panel else { return }
        if panel.isVisible {
            panel.dismiss(now: now)
        } else if panel.consumeRecentOutsideDismiss(now: now) {
            return
        } else {
            monitor.setDetailActive(true)
            panel.show(below: button, now: now)
        }
    }

    func dismissFromOutsideClick(now: ContinuousClock.Instant = .now) {
        panel?.dismiss(fromOutsideClick: true, now: now)
    }

    isolated deinit {
        observeTask?.cancel()
        panel?.dismiss()
        NSStatusBar.system.removeStatusItem(item)
    }

    @objc private func statusItemClicked() {
        let currentEvent = NSApp.currentEvent
        let eventType = currentEvent?.type
        if eventType == .rightMouseUp || eventType == .rightMouseDown {
            panel?.dismiss()
            if let currentEvent, let button = item.button {
                NSMenu.popUpContextMenu(menu, with: currentEvent, for: button)
            } else {
                menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            }
            return
        }
        handleLeftClick()
    }

    static func tooltipText(for metrics: SystemMetrics) -> String {
        let cpu = "CPU \(SystemMetrics.formatPercentage(metrics.cpuUsage))"
        let ram = "RAM \(SystemMetrics.formatPercentage(metrics.memoryUsage))"
        let temp = "\(L10n.tr("温度", "Temp")) \(SystemMetrics.formatTemperatureDetail(metrics.temperatureCelsius))"
        let net = "↑ \(SystemMetrics.formatRate(metrics.uploadBytesPerSec)) ↓ \(SystemMetrics.formatRate(metrics.downloadBytesPerSec))"
        return "\(cpu) · \(ram) · \(temp) · \(net)"
    }

    static func renderImage(
        for metrics: SystemMetrics,
        style: MonitorStatusBarStyle = .rateAndBars,
        coloredBars: Bool = false,
        cpuThreshold: Double = MonitorCPUAlertThreshold.standard.fraction,
        ramThreshold: Double = MonitorRAMAlertThreshold.standard.fraction,
        thermalThreshold: Double = MonitorThermalAlertThreshold.standard.celsius
    ) -> NSImage {
        renderImage(
            for: metrics,
            key: DisplayKey(
                metrics: metrics,
                style: style,
                coloredBars: coloredBars,
                cpuThreshold: cpuThreshold,
                ramThreshold: ramThreshold,
                thermalThreshold: thermalThreshold
            )
        )
    }

    private static func renderImage(for metrics: SystemMetrics, key: DisplayKey) -> NSImage {
        let width = key.style == .rateAndBars ? fullWidth : barsOnlyWidth
        let size = NSSize(width: width, height: itemHeight)
        let image = NSImage(size: size, flipped: true) { _ in
            if key.style == .rateAndBars {
                ("↑" as NSString).draw(
                    in: NSRect(x: 1.0, y: 1.5, width: 7.0, height: 9.0),
                    withAttributes: arrowAttributes
                )
                ("↓" as NSString).draw(
                    in: NSRect(x: 1.0, y: 11.5, width: 7.0, height: 9.0),
                    withAttributes: arrowAttributes
                )
                (key.upText as NSString).draw(
                    in: NSRect(x: 8.0, y: 1.0, width: 33.5, height: 10.0),
                    withAttributes: rightAttributes
                )
                (key.downText as NSString).draw(
                    in: NSRect(x: 8.0, y: 11.0, width: 33.5, height: 10.0),
                    withAttributes: rightAttributes
                )
            }

            drawVerticalBars(
                originX: key.style == .rateAndBars ? 45.0 : 3.5,
                originY: 2.5,
                barWidth: 3.0,
                barHeight: 17,
                spacing: 2.0,
                bars: [
                    (metrics.cpuUsage, barColor(for: key.cpuTone)),
                    (metrics.memoryUsage, barColor(for: key.ramTone)),
                    (SystemMetrics.thermalProgress(metrics.temperatureCelsius), barColor(for: key.tmpTone)),
                ]
            )
            return true
        }
        image.isTemplate = key.isTemplate
        return image
    }

    private static func barColor(for tone: BarTone) -> NSColor {
        switch tone {
        case .monochrome: NSColor.labelColor.withAlphaComponent(0.88)
        case .accent: frostAccent
        case .warning: frostWarning
        case .critical: frostCritical
        }
    }

    private static func drawVerticalBars(
        originX: CGFloat,
        originY: CGFloat,
        barWidth: CGFloat,
        barHeight: CGFloat,
        spacing: CGFloat,
        bars: [(fraction: Double, color: NSColor)]
    ) {
        let radius = barWidth / 2
        for (index, bar) in bars.enumerated() {
            let x = originX + CGFloat(index) * (barWidth + spacing)
            let trackRect = NSRect(x: x, y: originY, width: barWidth, height: barHeight)
            let trackPath = NSBezierPath(roundedRect: trackRect, xRadius: radius, yRadius: radius)
            NSColor.labelColor.withAlphaComponent(0.22).setFill()
            trackPath.fill()

            let clamped = min(max(bar.fraction, 0), 1)
            guard clamped > 0.01 else { continue }
            let fillHeight = max(barWidth, barHeight * CGFloat(clamped))
            let fillRect = NSRect(
                x: x,
                y: originY + (barHeight - fillHeight),
                width: barWidth,
                height: fillHeight
            )
            let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius)
            bar.color.setFill()
            fillPath.fill()
        }
    }
}
