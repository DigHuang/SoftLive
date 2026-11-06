import Foundation
import Observation

enum StageStyle: String, CaseIterable, Sendable {
    case luminous
    case inkTrace

    var displayName: String {
        switch self {
        case .luminous: "流光"
        case .inkTrace: "描金"
        }
    }

    var subtitle: String {
        switch self {
        case .luminous: "3D 飞散弹射 · 十字星芒与冲击环"
        case .inkTrace: "霓虹笔画激光 · 残影重影与几何爆闪"
        }
    }
}

/// User toggles, persisted in `UserDefaults`.
@Observable
final class Preferences {
    var showsStatusBarLyrics: Bool { didSet { defaults.set(showsStatusBarLyrics, forKey: Key.statusBar) } }
    var showsSystemMonitor: Bool { didSet { defaults.set(showsSystemMonitor, forKey: Key.monitor) } }
    var showsDesktopLyrics: Bool { didSet { defaults.set(showsDesktopLyrics, forKey: Key.desktop) } }
    /// Locked desktop lyrics ignore the mouse (click-through) and cannot be dragged.
    var desktopLyricsLocked: Bool { didSet { defaults.set(desktopLyricsLocked, forKey: Key.locked) } }
    var showsDesktopWidget: Bool { didSet { defaults.set(showsDesktopWidget, forKey: Key.widget) } }
    var showsStageWindow: Bool { didSet { defaults.set(showsStageWindow, forKey: Key.stageWindow) } }
    var stageStyle: StageStyle { didSet { defaults.set(stageStyle.rawValue, forKey: Key.stageStyle) } }
    var stageSparks: Bool { didSet { defaults.set(stageSparks, forKey: Key.stageSparks) } }
    var preferredPlayer: PlayerKind { didSet { defaults.set(preferredPlayer.rawValue, forKey: Key.player) } }

    private enum Key {
        static let statusBar = "showsStatusBarLyrics"
        static let monitor = "showsSystemMonitor"
        static let desktop = "showsDesktopLyrics"
        static let locked = "desktopLyricsLocked"
        static let widget = "showsDesktopWidget"
        static let stageWindow = "showsStageWindow"
        static let stageStyle = "stageStyle"
        static let stageSparks = "stageSparks"
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
            Key.stageWindow: false,
            Key.stageStyle: StageStyle.luminous.rawValue,
            Key.stageSparks: true,
            Key.player: PlayerKind.netEase.rawValue,
        ])
        showsStatusBarLyrics = defaults.bool(forKey: Key.statusBar)
        showsSystemMonitor = defaults.bool(forKey: Key.monitor)
        showsDesktopLyrics = defaults.bool(forKey: Key.desktop)
        desktopLyricsLocked = defaults.bool(forKey: Key.locked)
        showsDesktopWidget = defaults.bool(forKey: Key.widget)
        showsStageWindow = defaults.bool(forKey: Key.stageWindow)
        stageStyle = defaults.string(forKey: Key.stageStyle).flatMap(StageStyle.init(rawValue:)) ?? .luminous
        stageSparks = defaults.bool(forKey: Key.stageSparks)
        preferredPlayer = defaults.string(forKey: Key.player).flatMap(PlayerKind.init(rawValue:)) ?? .netEase
    }
}
