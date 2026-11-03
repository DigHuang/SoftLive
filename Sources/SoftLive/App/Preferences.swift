import Foundation
import Observation

/// User toggles, persisted in `UserDefaults`.
@Observable
final class Preferences {
    var showsStatusBarLyrics: Bool { didSet { defaults.set(showsStatusBarLyrics, forKey: Key.statusBar) } }
    var showsDesktopLyrics: Bool { didSet { defaults.set(showsDesktopLyrics, forKey: Key.desktop) } }
    /// Locked desktop lyrics ignore the mouse (click-through) and cannot be dragged.
    var desktopLyricsLocked: Bool { didSet { defaults.set(desktopLyricsLocked, forKey: Key.locked) } }
    var showsDesktopWidget: Bool { didSet { defaults.set(showsDesktopWidget, forKey: Key.widget) } }

    private enum Key {
        static let statusBar = "showsStatusBarLyrics"
        static let desktop = "showsDesktopLyrics"
        static let locked = "desktopLyricsLocked"
        static let widget = "showsDesktopWidget"
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Key.statusBar: true, Key.desktop: true, Key.locked: false, Key.widget: false])
        showsStatusBarLyrics = defaults.bool(forKey: Key.statusBar)
        showsDesktopLyrics = defaults.bool(forKey: Key.desktop)
        desktopLyricsLocked = defaults.bool(forKey: Key.locked)
        showsDesktopWidget = defaults.bool(forKey: Key.widget)
    }
}
