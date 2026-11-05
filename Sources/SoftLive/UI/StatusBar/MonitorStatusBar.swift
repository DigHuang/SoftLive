import AppKit
import Observation
import SwiftUI

/// Non-activating floating popover panel for `MonitorStatusBar`.
/// Using `.nonactivatingPanel` avoids calling `NSApp.activate()`, which on notched MacBooks
/// would otherwise replace the foreground app's menu bar and cause macOS WindowServer to
/// reflow/teleport status bar items across the camera notch on click.
private final class MonitorPopoverPanel: NSPanel {
    var onClose: (() -> Void)?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private weak var statusBarWindow: NSWindow?
    private weak var statusBarButton: NSStatusBarButton?
    private var hostView: FirstMouseHostingView<MonitorPopoverView>?

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

    func show(below button: NSStatusBarButton) {
        statusBarWindow = button.window
        statusBarButton = button
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

    func dismiss() {
        removeMonitors()
        statusBarButton?.highlight(false)
        guard isVisible else { return }
        contentView?.isHidden = true
        orderOut(nil)
        onClose?()
    }

    private func installMonitors() {
        removeMonitors()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.dismiss()
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
            if event.type == .keyDown, event.keyCode == 53 {
                self.dismiss()
                return nil
            }
            if let eventWindow = event.window {
                if eventWindow === self.statusBarWindow {
                    return event
                }
                if eventWindow === self {
                    if let host = self.hostView, let activeTop = host.activeTopHeight {
                        let pt = event.locationInWindow
                        let fromTop = self.frame.height - pt.y
                        if fromTop > activeTop {
                            self.dismiss()
                            return event
                        }
                    }
                    return event
                }
            }
            self.dismiss()
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
        if let activeTopHeight {
            let local = convert(point, from: superview)
            let fromTop = isFlipped ? local.y : bounds.height - local.y
            if fromTop > activeTopHeight { return nil }
        }
        return super.hitTest(point)
    }
}

final class MonitorStatusBar: NSObject {
    private static let itemWidth: CGFloat = 52
    private static let itemHeight: CGFloat = 22
    private static let rateFont = NSFont.monospacedDigitSystemFont(ofSize: 8.0, weight: .semibold)
    private static let rightParagraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        style.lineBreakMode = .byClipping
        return style
    }()

    private static let cpuCyan = adaptiveColor(
        light: (0.01, 0.52, 0.78),
        dark: (0.22, 0.74, 0.97)
    )
    private static let cpuOrange = adaptiveColor(
        light: (0.90, 0.35, 0.05),
        dark: (0.98, 0.45, 0.09)
    )
    private static let ramEmerald = adaptiveColor(
        light: (0.02, 0.59, 0.41),
        dark: (0.20, 0.83, 0.60)
    )
    private static let ramAmber = adaptiveColor(
        light: (0.85, 0.47, 0.02),
        dark: (0.98, 0.75, 0.14)
    )
    private static let ramCoral = adaptiveColor(
        light: (0.86, 0.15, 0.15),
        dark: (0.97, 0.36, 0.36)
    )
    private static let tmpTeal = adaptiveColor(
        light: (0.05, 0.58, 0.53),
        dark: (0.18, 0.83, 0.75)
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

    private struct DisplayKey: Equatable {
        let upText: String
        let downText: String
        let cpuBarSteps: Int
        let ramBarSteps: Int
        let tmpBarSteps: Int
        let pressure: MemoryPressureLevel

        init(metrics: SystemMetrics) {
            upText = SystemMetrics.formatRate(metrics.uploadBytesPerSec)
            downText = SystemMetrics.formatRate(metrics.downloadBytesPerSec)
            cpuBarSteps = Int((min(max(metrics.cpuUsage, 0), 1) * 17).rounded())
            ramBarSteps = Int((min(max(metrics.memoryUsage, 0), 1) * 17).rounded())
            tmpBarSteps = Int((SystemMetrics.thermalProgress(metrics.temperatureCelsius) * 17).rounded())
            pressure = metrics.memoryPressure
        }
    }

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let monitor: SystemMonitor
    private let menu: NSMenu
    private var panel: MonitorPopoverPanel?
    private var observeTask: Task<Void, Never>?
    private var lastDisplayKey: DisplayKey?

    init(monitor: SystemMonitor, preferences: Preferences, menu: NSMenu) {
        self.monitor = monitor
        self.menu = menu
        super.init()

        let initialKey = DisplayKey(metrics: monitor.metrics)
        lastDisplayKey = initialKey
        item.isVisible = preferences.showsSystemMonitor
        item.button?.image = Self.renderImage(for: monitor.metrics, key: initialKey)
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.sendAction(on: [.leftMouseDown, .rightMouseUp])

        let popoverPanel = MonitorPopoverPanel(
            rootView: MonitorPopoverView(
                monitor: monitor,
                onOpenMenu: { [weak self] in
                    guard let self else { return }
                    self.panel?.dismiss()
                    NSApp.activate()
                    self.menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
                }
            )
        )
        popoverPanel.onClose = { [weak monitor] in
            monitor?.setDetailActive(false)
        }
        self.panel = popoverPanel

        observeTask = Task { [weak self] in
            for await (metrics, visible) in Observations({
                (monitor.metrics, preferences.showsSystemMonitor)
            }) {
                guard let self else { return }
                if self.item.isVisible != visible {
                    self.item.isVisible = visible
                }
                guard visible else {
                    self.panel?.dismiss()
                    continue
                }
                let key = DisplayKey(metrics: metrics)
                guard key != self.lastDisplayKey else { continue }
                self.lastDisplayKey = key
                self.item.button?.image = Self.renderImage(for: metrics, key: key)
            }
        }
    }

    @objc private func statusItemClicked() {
        let eventType = NSApp.currentEvent?.type
        if eventType == .rightMouseUp || eventType == .rightMouseDown {
            panel?.dismiss()
            NSApp.activate()
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            return
        }
        guard let button = item.button, let panel else { return }
        if panel.isVisible {
            panel.dismiss()
        } else {
            panel.show(below: button)
            monitor.setDetailActive(true)
        }
    }

    static func renderImage(for metrics: SystemMetrics) -> NSImage {
        renderImage(for: metrics, key: DisplayKey(metrics: metrics))
    }

    private static func renderImage(for metrics: SystemMetrics, key: DisplayKey) -> NSImage {
        let size = NSSize(width: itemWidth, height: itemHeight)
        let image = NSImage(size: size, flipped: true) { _ in
            let rightAttributes: [NSAttributedString.Key: Any] = [
                .font: rateFont,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: rightParagraphStyle,
            ]
            // 1. Left column (0...33 pt): clean two-line right-aligned upload / download rates (no arrows)
            (key.upText as NSString).draw(
                in: NSRect(x: 0, y: 1.5, width: 33, height: 10),
                withAttributes: rightAttributes
            )
            (key.downText as NSString).draw(
                in: NSRect(x: 0, y: 11.0, width: 33, height: 10),
                withAttributes: rightAttributes
            )

            // 2. Right column (39.0...52.0 pt, 6.0 pt gap from text): 3 semantic colored vertical bars (CPU / RAM / TMP, each 0...100)
            let cpuColor = metrics.cpuUsage >= 0.75 ? cpuOrange : cpuCyan
            let ramColor: NSColor = switch metrics.memoryPressure {
            case .critical: ramCoral
            case .warning: ramAmber
            case .normal: metrics.memoryUsage >= 0.88 ? ramAmber : ramEmerald
            }
            let temp = metrics.temperatureCelsius ?? 0
            let tmpColor: NSColor = if temp >= 72 {
                ramCoral
            } else if temp >= 55 {
                ramAmber
            } else {
                tmpTeal
            }

            drawVerticalBars(
                originX: 39.0,
                originY: 2.5,
                barWidth: 3.0,
                barHeight: 17,
                spacing: 2.0,
                bars: [
                    (metrics.cpuUsage, cpuColor),
                    (metrics.memoryUsage, ramColor),
                    (SystemMetrics.thermalProgress(metrics.temperatureCelsius), tmpColor),
                ]
            )
            return true
        }
        image.isTemplate = false
        return image
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
