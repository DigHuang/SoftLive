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

    /// Full-color app icon (`Sync / 同频 × 霜光`) for brand entry and product overview surfaces.
    static var appIcon: NSImage {
        if let named = NSImage(named: "AppIcon") {
            return named
        }
        if let bundleURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icns = NSImage(contentsOf: bundleURL) {
            return icns
        }
        return NSApp.applicationIconImage ?? syncTemplate
    }
}
