import AppKit

/// Menu-bar lyrics.
final class StatusBarController {
    /// Long lines truncate instead of pushing other items away. If the menu bar has no room left
    /// (common next to the notch) macOS hides the item; the menu stays reachable from the desktop panels.
    private static let maxWidth: CGFloat = 260

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    init(model: AppModel, preferences: Preferences, menu: NSMenu) {
        item.menu = menu
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "SoftLive")
            button.cell?.lineBreakMode = .byTruncatingTail
        }
        Task { [weak self] in
            for await text in Observations({ preferences.showsStatusBarLyrics ? model.headline : "" }) {
                guard let self else { return }
                show(text)
            }
        }
    }

    private func show(_ text: String) {
        guard let button = item.button, button.title != text || item.length == 0 else { return }
        button.title = text
        // The note icon only stands in while there is no text, to save menu-bar space.
        button.imagePosition = text.isEmpty ? .imageOnly : .noImage
        item.length = text.isEmpty
            ? NSStatusItem.squareLength
            : min(button.attributedTitle.size().width + 16, Self.maxWidth)
    }
}
