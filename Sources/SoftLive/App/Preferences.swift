import Foundation
import Observation

/// User toggles, persisted in `UserDefaults`.
@Observable
final class Preferences {
    var showsStatusBarLyrics: Bool { didSet { defaults.set(showsStatusBarLyrics, forKey: Key.statusBar) } }
    var showsSystemMonitor: Bool { didSet { defaults.set(showsSystemMonitor, forKey: Key.monitor) } }
    var showsDesktopLyrics: Bool { didSet { defaults.set(showsDesktopLyrics, forKey: Key.desktop) } }
    /// Locked desktop lyrics ignore the mouse (click-through) and cannot be dragged.
    var desktopLyricsLocked: Bool { didSet { defaults.set(desktopLyricsLocked, forKey: Key.locked) } }
    var showsDesktopWidget: Bool { didSet { defaults.set(showsDesktopWidget, forKey: Key.widget) } }
    var preferredPlayer: PlayerKind { didSet { defaults.set(preferredPlayer.rawValue, forKey: Key.player) } }

    private enum Key {
        static let statusBar = "showsStatusBarLyrics"
        static let monitor = "showsSystemMonitor"
        static let desktop = "showsDesktopLyrics"
        static let locked = "desktopLyricsLocked"
        static let widget = "showsDesktopWidget"
        static let player = "preferredPlayer"
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.statusBar: true,
            Key.monitor: true,
            Key.desktop: true,
            Key.locked: true,
            Key.widget: false,
            Key.player: PlayerKind.netEase.rawValue,
        ])
        showsStatusBarLyrics = defaults.bool(forKey: Key.statusBar)
        showsSystemMonitor = defaults.bool(forKey: Key.monitor)
        showsDesktopLyrics = defaults.bool(forKey: Key.desktop)
        desktopLyricsLocked = defaults.bool(forKey: Key.locked)
        showsDesktopWidget = defaults.bool(forKey: Key.widget)
        preferredPlayer = defaults.string(forKey: Key.player).flatMap(PlayerKind.init(rawValue:)) ?? .netEase
    }
}
