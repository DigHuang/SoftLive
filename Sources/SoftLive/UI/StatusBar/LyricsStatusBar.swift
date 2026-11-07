import AppKit
import Observation

/// Menu-bar lyrics item.
final class LyricsStatusBar {
    /// Long lines truncate instead of pushing other items away. If the menu bar has no room left
    /// (common next to the notch) macOS hides the item; the menu stays reachable from the desktop panels.
    private static let maxWidth: CGFloat = 260

    private static let icon: NSImage = {
        let url = Bundle.main.url(forResource: "StatusBarIcon", withExtension: "png")
            ?? Bundle.module.url(forResource: "StatusBarIcon", withExtension: "png")
        guard let url, let image = NSImage(contentsOf: url) else {
            preconditionFailure("Missing bundled StatusBarIcon.png")
        }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        image.accessibilityDescription = "SoftLive"
        return image
    }()

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    init(model: PlaybackModel, preferences: Preferences, menu: NSMenu) {
        item.menu = menu
        if let button = item.button {
            button.image = Self.icon
            button.cell?.lineBreakMode = .byTruncatingTail
        }
        Task { [weak self] in
            for await (showsLyrics, showsMonitor, headline) in Observations({
                (preferences.showsStatusBarLyrics, preferences.showsSystemMonitor, model.headline)
            }) {
                guard let self else { return }
                // Hide the lyrics status item completely when the user turned it off and the
                // system monitor item is already visible in the menu bar.
                let shouldBeVisible = showsLyrics || !showsMonitor
                if self.item.isVisible != shouldBeVisible {
                    self.item.isVisible = shouldBeVisible
                }
                guard shouldBeVisible else { continue }
                self.show(showsLyrics ? headline : "")
            }
        }
    }

    private func show(_ text: String) {
        guard let button = item.button, button.title != text || item.length == 0 else { return }
        button.title = text
        // The Sync icon only stands in while there is no text, to save menu-bar space.
        button.imagePosition = text.isEmpty ? .imageOnly : .noImage
        item.length = text.isEmpty
            ? NSStatusItem.squareLength
            : min(button.attributedTitle.size().width + 16, Self.maxWidth)
    }
}
