import AppKit
import SwiftUI

enum FrostMenuEntry {
    case item(
        title: String,
        image: NSImage? = nil,
        isSelected: Bool = false,
        isEnabled: Bool = true,
        action: () -> Void
    )
    case separator
}

enum FrostDropdownAlignment {
    case leading
    case trailing
}

enum FrostDropdownIndicator {
    case picker
    case menu
    case none
}

enum FrostDropdownChrome {
    case controlCenter
    case toolbar(height: CGFloat)
    case iconSquare(size: CGFloat)
    case borderless(height: CGFloat)

    var height: CGFloat {
        switch self {
        case .controlCenter: 28
        case .toolbar(let height), .borderless(let height): height
        case .iconSquare(let size): size
        }
    }

    var fixedWidth: CGFloat? {
        switch self {
        case .iconSquare(let size): size
        case .controlCenter, .toolbar, .borderless: nil
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .controlCenter: 10
        case .toolbar: 9
        case .iconSquare: 0
        case .borderless: 7
        }
    }

    var cornerRadius: CGFloat {
        switch self {
        case .controlCenter: 7
        case .toolbar, .iconSquare, .borderless: 6.5
        }
    }

    var hasBorder: Bool {
        switch self {
        case .controlCenter, .toolbar, .iconSquare: true
        case .borderless: false
        }
    }

    var spacing: CGFloat {
        switch self {
        case .controlCenter: 6
        case .toolbar, .borderless: 5
        case .iconSquare: 0
        }
    }

    var indicatorPointSize: CGFloat {
        switch self {
        case .controlCenter: 9.5
        case .toolbar, .iconSquare, .borderless: 8.5
        }
    }
}

enum FrostDropdownLayout {
    static let defaultVerticalGap: CGFloat = 6
    static let menuItemIconSize = NSSize(width: 16, height: 16)

    /// Computes the flipped trigger-view origin so the popup `NSMenu` opens cleanly below the pill.
    static func menuOrigin(
        bounds: CGRect,
        menuWidth: CGFloat,
        alignment: FrostDropdownAlignment,
        verticalGap: CGFloat = defaultVerticalGap
    ) -> NSPoint {
        let effectiveWidth = max(bounds.width, menuWidth)
        let x: CGFloat = switch alignment {
        case .leading:
            0
        case .trailing:
            bounds.width - effectiveWidth
        }
        return NSPoint(x: x, y: bounds.height + verticalGap)
    }

    static func resizedMenuIcon(_ image: NSImage) -> NSImage {
        let copy = image.copy() as? NSImage ?? image
        copy.size = menuItemIconSize
        return copy
    }

    static func buildMenu(
        entries: [FrostMenuEntry],
        minimumWidth: CGFloat,
        target: AnyObject?,
        action: Selector
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.font = NSFont.menuFont(ofSize: 13)
        menu.minimumWidth = minimumWidth

        for entry in entries {
            switch entry {
            case .separator:
                menu.addItem(.separator())
            case let .item(title, image, isSelected, isEnabled, handler):
                let item = NSMenuItem(
                    title: title,
                    action: isEnabled ? action : nil,
                    keyEquivalent: ""
                )
                item.target = isEnabled ? target : nil
                item.isEnabled = isEnabled
                item.state = isSelected ? .on : .off
                if let image {
                    item.image = resizedMenuIcon(image)
                }
                item.representedObject = FrostMenuActionBox(handler: handler)
                menu.addItem(item)
            }
        }
        return menu
    }
}

final class FrostMenuActionBox: NSObject {
    let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler
    }
}

/// Compact Frost pill trigger backed by a native AppKit `NSMenu` anchored strictly below its frame.
struct FrostDropdown<Label: View>: View {
    let entries: [FrostMenuEntry]
    let chrome: FrostDropdownChrome
    let alignment: FrostDropdownAlignment
    let indicator: FrostDropdownIndicator
    let accessibilityLabelText: String?
    let accessibilityValueText: String?
    let toolTipText: String?
    @ViewBuilder let label: () -> Label

    @State private var isHovered = false
    @State private var isMenuOpen = false

    init(
        entries: [FrostMenuEntry],
        chrome: FrostDropdownChrome,
        alignment: FrostDropdownAlignment = .trailing,
        indicator: FrostDropdownIndicator = .picker,
        accessibilityLabel: String? = nil,
        accessibilityValue: String? = nil,
        toolTip: String? = nil,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.entries = entries
        self.chrome = chrome
        self.alignment = alignment
        self.indicator = indicator
        self.accessibilityLabelText = accessibilityLabel
        self.accessibilityValueText = accessibilityValue
        self.toolTipText = toolTip
        self.label = label
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: chrome.cornerRadius, style: .continuous)

        HStack(spacing: chrome.spacing) {
            label()
            indicatorView
        }
        .accessibilityHidden(true)
        .padding(.horizontal, chrome.horizontalPadding)
        .frame(width: chrome.fixedWidth, height: chrome.height)
        .fixedSize(horizontal: chrome.fixedWidth == nil, vertical: true)
        .background(backgroundFill, in: shape)
        .overlay {
            if chrome.hasBorder {
                shape.strokeBorder(SoftLiveTheme.hairline, lineWidth: 0.5)
            }
        }
        .overlay {
            DropdownTriggerRepresentable(
                entries: entries,
                alignment: alignment,
                accessibilityTitle: accessibilityLabelText,
                accessibilityCurrentValue: accessibilityValueText,
                toolTipText: toolTipText,
                onHoverChange: { hovering in
                    isHovered = hovering
                },
                onMenuOpenChange: { open in
                    isMenuOpen = open
                }
            )
        }
        .contentShape(shape)
    }

    private var backgroundFill: Color {
        if isMenuOpen {
            return SoftLiveTheme.controlActive
        }
        if isHovered {
            return SoftLiveTheme.controlHover
        }
        return chrome.hasBorder ? SoftLiveTheme.insetWell : .clear
    }

    @ViewBuilder
    private var indicatorView: some View {
        switch indicator {
        case .picker:
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: chrome.indicatorPointSize, weight: .semibold))
                .foregroundStyle(.secondary)
        case .menu:
            Image(systemName: "chevron.down")
                .font(.system(size: chrome.indicatorPointSize, weight: .semibold))
                .foregroundStyle(.secondary)
        case .none:
            EmptyView()
        }
    }
}

private struct DropdownTriggerRepresentable: NSViewRepresentable {
    let entries: [FrostMenuEntry]
    let alignment: FrostDropdownAlignment
    let accessibilityTitle: String?
    let accessibilityCurrentValue: String?
    let toolTipText: String?
    let onHoverChange: (Bool) -> Void
    let onMenuOpenChange: (Bool) -> Void

    func makeNSView(context: Context) -> DropdownTriggerNSView {
        let view = DropdownTriggerNSView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: DropdownTriggerNSView, context: Context) {
        view.entries = entries
        view.alignment = alignment
        view.accessibilityTitle = accessibilityTitle
        view.accessibilityCurrentValue = accessibilityCurrentValue
        view.toolTip = toolTipText
        view.onHoverChange = onHoverChange
        view.onMenuOpenChange = onMenuOpenChange
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: DropdownTriggerNSView,
        context: Context
    ) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

final class DropdownTriggerNSView: NSView {
    var entries: [FrostMenuEntry] = []
    var alignment: FrostDropdownAlignment = .trailing
    var accessibilityTitle: String?
    var accessibilityCurrentValue: String?
    var onHoverChange: ((Bool) -> Void)?
    var onMenuOpenChange: ((Bool) -> Void)?

    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
    }

    override func mouseDown(with event: NSEvent) {
        guard event.buttonNumber == 0 else {
            super.mouseDown(with: event)
            return
        }
        openMenu()
    }

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .popUpButton }

    override func accessibilityLabel() -> String? { accessibilityTitle }

    override func accessibilityValue() -> Any? { accessibilityCurrentValue }

    override func accessibilityPerformPress() -> Bool {
        openMenu()
        return true
    }

    private func openMenu() {
        onMenuOpenChange?(true)
        let menu = FrostDropdownLayout.buildMenu(
            entries: entries,
            minimumWidth: bounds.width,
            target: self,
            action: #selector(performMenuAction(_:))
        )
        let origin = FrostDropdownLayout.menuOrigin(
            bounds: bounds,
            menuWidth: menu.size.width,
            alignment: alignment
        )
        menu.popUp(positioning: nil, at: origin, in: self)
        onMenuOpenChange?(false)
        syncHoverState()
    }

    private func syncHoverState() {
        guard let window else {
            onHoverChange?(false)
            return
        }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        onHoverChange?(bounds.contains(point))
    }

    @objc private func performMenuAction(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? FrostMenuActionBox else { return }
        box.handler()
    }
}
