import Foundation
import Observation

/// User toggles, persisted in `UserDefaults`.
@MainActor
@Observable
final class Preferences {
    var showsStatusBarLyrics: Bool { didSet { save(showsStatusBarLyrics, Key.statusBar) } }
    var showsDesktopLyrics: Bool { didSet { save(showsDesktopLyrics, Key.desktop) } }
    /// Locked desktop lyrics ignore the mouse (click-through) and cannot be dragged.
    var desktopLyricsLocked: Bool { didSet { save(desktopLyricsLocked, Key.locked) } }
    var showsDesktopWidget: Bool { didSet { save(showsDesktopWidget, Key.widget) } }

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

    private func save(_ value: Bool, _ key: String) {
        defaults.set(value, forKey: key)
    }
}
