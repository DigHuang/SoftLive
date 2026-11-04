import AppKit
import SwiftUI

/// A borderless, transparent, non-activating panel that hosts SwiftUI content on every Space:
/// the base of the desktop lyrics and the desktop widget. It is dragged by its background,
/// right-clicking it opens `menu`, and its position is remembered under `frameName`.
final class OverlayPanel: NSPanel {
    private let allowsKey: Bool

    init(
        frameName: String,
        size: NSSize,
        level: NSWindow.Level,
        extraBehavior: NSWindow.CollectionBehavior = [],
        allowsKey: Bool = false,
        menu: NSMenu,
        content: some View,
        defaultOrigin: (_ visibleFrame: NSRect, _ size: NSSize) -> NSPoint
    ) {
        self.allowsKey = allowsKey
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

        let host = OverlayHostingView(rootView: content)
        host.sizingOptions = []
        host.menu = menu
        contentView = host

        if setFrameUsingName(frameName) {
            if abs(frame.width - size.width) > 0.5 || abs(frame.height - size.height) > 0.5 {
                setFrame(NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height), display: false)
            }
        } else if let screen = NSScreen.main?.visibleFrame {
            setFrameOrigin(defaultOrigin(screen, size))
        }
        setFrameAutosaveName(frameName)
    }

    override var canBecomeKey: Bool { allowsKey && !ignoresMouseEvents }

    /// Keeps visibility, click-through and active hit height in sync with observable state.
    func bind(
        _ state: @escaping @MainActor () -> (isVisible: Bool, clicksThrough: Bool),
        activeTopHeight: (@MainActor () -> CGFloat?)? = nil
    ) -> Self {
        Task { [weak self] in
            for await (isVisible, clicksThrough, topHeight) in Observations({
                let (visible, through) = state()
                return (visible, through, activeTopHeight?())
            }) {
                guard let self else { return }
                ignoresMouseEvents = clicksThrough
                (contentView as? OverlayHitTesting)?.activeTopHeight = topHeight
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

private protocol OverlayHitTesting: AnyObject {
    var activeTopHeight: CGFloat? { get set }
}

/// Routes first-click interaction to SwiftUI controls, drags the window on mouse-drag,
/// and forwards right-clicks to `menu`.
private final class OverlayHostingView<Content: View>: NSHostingView<Content>, OverlayHitTesting {
    var activeTopHeight: CGFloat?
    private var mouseDownPoint: NSPoint?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let activeTopHeight {
            let local = convert(point, from: superview)
            let fromTop = isFlipped ? local.y : bounds.height - local.y
            if fromTop > activeTopHeight { return nil }
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if let start = mouseDownPoint,
           hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) >= 4 {
            mouseDownPoint = nil
            window?.performDrag(with: event)
            return
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownPoint = nil
        super.mouseUp(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu else { return super.rightMouseDown(with: event) }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}
