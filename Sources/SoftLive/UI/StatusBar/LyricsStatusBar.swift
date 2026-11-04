import AppKit
import Observation

/// Menu-bar lyrics item.
final class LyricsStatusBar {
    /// Long lines truncate instead of pushing other items away. If the menu bar has no room left
    /// (common next to the notch) macOS hides the item; the menu stays reachable from the desktop panels.
    private static let maxWidth: CGFloat = 260

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    init(model: PlaybackModel, preferences: Preferences, menu: NSMenu) {
        item.menu = menu
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "SoftLive")
            button.cell?.lineBreakMode = .byTruncatingTail
        }
        Task { [weak self] in
            for await (shows, headline) in Observations({ (preferences.showsStatusBarLyrics, model.headline) }) {
                self?.show(shows ? headline : "")
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
