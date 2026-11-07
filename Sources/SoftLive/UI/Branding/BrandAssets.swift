import AppKit

/// Cached brand artwork shared by menu-bar and desktop UI.
enum BrandAssets {
    static let syncTemplate: NSImage = {
        let url = Bundle.main.url(forResource: "SyncTemplate", withExtension: "png")
            ?? Bundle.module.url(forResource: "SyncTemplate", withExtension: "png")
        guard let url, let image = NSImage(contentsOf: url) else {
            preconditionFailure("Missing bundled SyncTemplate.png")
        }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        image.accessibilityDescription = "SoftLive"
        return image
    }()
}
