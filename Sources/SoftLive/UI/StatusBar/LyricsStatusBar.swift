import AppKit
import Observation

/// Menu-bar lyrics item.
final class LyricsStatusBar {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var lastMaxWidth: CGFloat = 0

    init(model: PlaybackModel, preferences: Preferences, menu: NSMenu) {
        item.menu = menu
        if let button = item.button {
            button.image = BrandAssets.syncTemplate
            button.cell?.lineBreakMode = .byTruncatingTail
        }
        Task { [weak self] in
            for await (showsLyrics, showsMonitor, headline, maxWidth) in Observations({
                (
                    preferences.showsStatusBarLyrics,
                    preferences.showsSystemMonitor,
                    model.headline,
                    preferences.statusBarWidthPreset.maxWidth
                )
            }) {
                guard let self else { return }
                // Hide the lyrics status item completely when the user turned it off and the
                // system monitor item is already visible in the menu bar.
                let shouldBeVisible = showsLyrics || !showsMonitor
                if self.item.isVisible != shouldBeVisible {
                    self.item.isVisible = shouldBeVisible
                }
                guard shouldBeVisible else { continue }
                self.show(showsLyrics ? headline : "", maxWidth: maxWidth)
            }
        }
    }

    private func show(_ text: String, maxWidth: CGFloat) {
        guard let button = item.button,
              button.title != text || item.length == 0 || lastMaxWidth != maxWidth
        else { return }
        lastMaxWidth = maxWidth
        button.title = text
        // The Sync icon only stands in while there is no text, to save menu-bar space.
        button.imagePosition = text.isEmpty ? .imageOnly : .noImage
        item.length = text.isEmpty
            ? NSStatusItem.squareLength
            : min(button.attributedTitle.size().width + 16, maxWidth)
    }
}
