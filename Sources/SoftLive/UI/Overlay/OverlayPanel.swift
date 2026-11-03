import AppKit
import SwiftUI

/// A borderless, transparent, non-activating panel that hosts SwiftUI content on every Space:
/// the base of the desktop lyrics and the desktop widget. It is dragged by its background,
/// right-clicking it opens `menu`, and its position is remembered under `frameName`.
final class OverlayPanel: NSPanel {
    init(
        frameName: String,
        size: NSSize,
        level: NSWindow.Level,
        extraBehavior: NSWindow.CollectionBehavior = [],
        menu: NSMenu,
        content: some View,
        defaultOrigin: (_ visibleFrame: NSRect, _ size: NSSize) -> NSPoint
    ) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        self.level = level
        // On every Space, fixed in Mission Control, never in window cycling.
        collectionBehavior = extraBehavior.union([.canJoinAllSpaces, .stationary, .ignoresCycle])
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = true

        let host = OverlayHostingView(rootView: content)
        host.sizingOptions = []
        host.menu = menu
        contentView = host

        if !setFrameUsingName(frameName), let screen = NSScreen.main?.visibleFrame {
            setFrameOrigin(defaultOrigin(screen, size))
        }
        setFrameAutosaveName(frameName)
    }

    /// Keeps visibility and click-through in sync with observable state.
    func bind(_ state: @escaping @MainActor () -> (isVisible: Bool, clicksThrough: Bool)) -> Self {
        Task { [weak self] in
            for await (isVisible, clicksThrough) in Observations(state) {
                guard let self else { return }
                ignoresMouseEvents = clicksThrough
                contentView?.isHidden = !isVisible
                if isVisible { orderFrontRegardless() } else { orderOut(nil) }
            }
        }
        return self
    }
}

extension NSWindow.Level {
    /// Just above the Finder's desktop icons and below every app window: where desktop widgets live.
    static let desktopWidget = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
}

/// SwiftUI hosting views swallow background drags and right-clicks; route them to the window and `menu`.
private final class OverlayHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu else { return super.rightMouseDown(with: event) }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}
