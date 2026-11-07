import CoreGraphics
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

enum DesktopLyricsSize: String, CaseIterable, Sendable {
    case compact
    case standard
    case large

    var displayName: String {
        switch self {
        case .compact: "22 pt"
        case .standard: "26 pt"
        case .large: "30 pt"
        }
    }

    var mainFontSize: CGFloat {
        switch self {
        case .compact: 22
        case .standard: 26
        case .large: 30
        }
    }

    var sublineFontSize: CGFloat {
        switch self {
        case .compact: 13.5
        case .standard: 15
        case .large: 16.5
        }
    }
}

enum DesktopLyricsSublineMode: String, CaseIterable, Sendable {
    case translationThenNext
    case translationOnly
    case singleLine

    var displayName: String {
        switch self {
        case .translationThenNext: "翻译优先"
        case .translationOnly: "仅翻译"
        case .singleLine: "单行"
        }
    }
}

enum StatusBarWidthPreset: String, CaseIterable, Sendable {
    case compact
    case standard
    case wide

    var displayName: String {
        switch self {
        case .compact: "180 pt"
        case .standard: "260 pt"
        case .wide: "340 pt"
        }
    }

    var maxWidth: CGFloat {
        switch self {
        case .compact: 180
        case .standard: 260
        case .wide: 340
        }
    }
}

enum MonitorStatusBarStyle: String, CaseIterable, Sendable {
    case rateAndBars
    case barsOnly

    var displayName: String {
        switch self {
        case .rateAndBars: "网速 + 柱状图"
        case .barsOnly: "仅柱状图"
        }
    }
}

enum MonitorSampleInterval: Double, CaseIterable, Sendable {
    case fast = 1.0
    case standard = 2.0
    case eco = 5.0

    var displayName: String {
        switch self {
        case .fast: "1 秒"
        case .standard: "2 秒"
        case .eco: "5 秒"
        }
    }
}

enum MonitorCPUAlertThreshold: Int, CaseIterable, Sendable {
    case low = 70
    case standard = 80
    case high = 90

    var displayName: String { "\(rawValue)%" }
    var fraction: Double { Double(rawValue) / 100.0 }
}

enum MonitorRAMAlertThreshold: Int, CaseIterable, Sendable {
    case low = 80
    case standard = 85
    case high = 90

    var displayName: String { "\(rawValue)%" }
    var fraction: Double { Double(rawValue) / 100.0 }
}

enum MonitorThermalAlertThreshold: Int, CaseIterable, Sendable {
    case cool = 65
    case standard = 72
    case warm = 80

    var displayName: String { "\(rawValue)°C" }
    var celsius: Double { Double(rawValue) }
}

/// User toggles and customization options, persisted in `UserDefaults`.
@Observable
final class Preferences {
    var showsStatusBarLyrics: Bool { didSet { defaults.set(showsStatusBarLyrics, forKey: Key.statusBar) } }
    var showsSystemMonitor: Bool { didSet { defaults.set(showsSystemMonitor, forKey: Key.monitor) } }
    var showsDesktopLyrics: Bool { didSet { defaults.set(showsDesktopLyrics, forKey: Key.desktop) } }
    /// Locked desktop lyrics ignore the mouse (click-through) and cannot be dragged.
    var desktopLyricsLocked: Bool { didSet { defaults.set(desktopLyricsLocked, forKey: Key.locked) } }
    var desktopLyricsSize: DesktopLyricsSize { didSet { defaults.set(desktopLyricsSize.rawValue, forKey: Key.desktopSize) } }
    var desktopLyricsSublineMode: DesktopLyricsSublineMode { didSet { defaults.set(desktopLyricsSublineMode.rawValue, forKey: Key.desktopSubline) } }
    var statusBarWidthPreset: StatusBarWidthPreset { didSet { defaults.set(statusBarWidthPreset.rawValue, forKey: Key.statusBarWidth) } }
    var showsDesktopWidget: Bool { didSet { defaults.set(showsDesktopWidget, forKey: Key.widget) } }
    var showsStageWindow: Bool { didSet { defaults.set(showsStageWindow, forKey: Key.stageWindow) } }
    var stageStyle: StageStyle { didSet { defaults.set(stageStyle.rawValue, forKey: Key.stageStyle) } }
    var stageSparks: Bool { didSet { defaults.set(stageSparks, forKey: Key.stageSparks) } }
    var preferredPlayer: PlayerKind { didSet { defaults.set(preferredPlayer.rawValue, forKey: Key.player) } }
    var monitorStatusBarStyle: MonitorStatusBarStyle { didSet { defaults.set(monitorStatusBarStyle.rawValue, forKey: Key.monitorStyle) } }
    var monitorColoredBars: Bool { didSet { defaults.set(monitorColoredBars, forKey: Key.monitorColoredBars) } }
    var monitorDefaultTab: MonitorTab { didSet { defaults.set(monitorDefaultTab.rawValue, forKey: Key.monitorDefaultTab) } }
    var monitorSampleInterval: MonitorSampleInterval { didSet { defaults.set(monitorSampleInterval.rawValue, forKey: Key.monitorInterval) } }
    var monitorCPUAlertThreshold: MonitorCPUAlertThreshold { didSet { defaults.set(monitorCPUAlertThreshold.rawValue, forKey: Key.monitorCPUAlert) } }
    var monitorRAMAlertThreshold: MonitorRAMAlertThreshold { didSet { defaults.set(monitorRAMAlertThreshold.rawValue, forKey: Key.monitorRAMAlert) } }
    var monitorThermalAlertThreshold: MonitorThermalAlertThreshold { didSet { defaults.set(monitorThermalAlertThreshold.rawValue, forKey: Key.monitorThermalAlert) } }

    private enum Key {
        static let statusBar = "showsStatusBarLyrics"
        static let monitor = "showsSystemMonitor"
        static let desktop = "showsDesktopLyrics"
        static let locked = "desktopLyricsLocked"
        static let desktopSize = "desktopLyricsSize"
        static let desktopSubline = "desktopLyricsSublineMode"
        static let statusBarWidth = "statusBarWidthPreset"
        static let widget = "showsDesktopWidget"
        static let stageWindow = "showsStageWindow"
        static let stageStyle = "stageStyle"
        static let stageSparks = "stageSparks"
        static let player = "preferredPlayer"
        static let monitorStyle = "monitorStatusBarStyle"
        static let monitorColoredBars = "monitorColoredBars"
        static let monitorDefaultTab = "monitorDefaultTab"
        static let monitorInterval = "monitorSampleInterval"
        static let monitorCPUAlert = "monitorCPUAlertThreshold"
        static let monitorRAMAlert = "monitorRAMAlertThreshold"
        static let monitorThermalAlert = "monitorThermalAlertThreshold"
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.statusBar: true,
            Key.monitor: true,
            Key.desktop: true,
            Key.locked: true,
            Key.desktopSize: DesktopLyricsSize.standard.rawValue,
            Key.desktopSubline: DesktopLyricsSublineMode.translationThenNext.rawValue,
            Key.statusBarWidth: StatusBarWidthPreset.standard.rawValue,
            Key.widget: false,
            Key.stageWindow: false,
            Key.stageStyle: StageStyle.luminous.rawValue,
            Key.stageSparks: true,
            Key.player: PlayerKind.netEase.rawValue,
            Key.monitorStyle: MonitorStatusBarStyle.rateAndBars.rawValue,
            Key.monitorColoredBars: true,
            Key.monitorDefaultTab: MonitorTab.cpu.rawValue,
            Key.monitorInterval: MonitorSampleInterval.standard.rawValue,
            Key.monitorCPUAlert: MonitorCPUAlertThreshold.standard.rawValue,
            Key.monitorRAMAlert: MonitorRAMAlertThreshold.standard.rawValue,
            Key.monitorThermalAlert: MonitorThermalAlertThreshold.standard.rawValue,
        ])
        showsStatusBarLyrics = defaults.bool(forKey: Key.statusBar)
        showsSystemMonitor = defaults.bool(forKey: Key.monitor)
        showsDesktopLyrics = defaults.bool(forKey: Key.desktop)
        desktopLyricsLocked = defaults.bool(forKey: Key.locked)
        desktopLyricsSize = defaults.string(forKey: Key.desktopSize).flatMap(DesktopLyricsSize.init(rawValue:)) ?? .standard
        desktopLyricsSublineMode = defaults.string(forKey: Key.desktopSubline).flatMap(DesktopLyricsSublineMode.init(rawValue:)) ?? .translationThenNext
        statusBarWidthPreset = defaults.string(forKey: Key.statusBarWidth).flatMap(StatusBarWidthPreset.init(rawValue:)) ?? .standard
        showsDesktopWidget = defaults.bool(forKey: Key.widget)
        showsStageWindow = defaults.bool(forKey: Key.stageWindow)
        stageStyle = defaults.string(forKey: Key.stageStyle).flatMap(StageStyle.init(rawValue:)) ?? .luminous
        stageSparks = defaults.bool(forKey: Key.stageSparks)
        preferredPlayer = defaults.string(forKey: Key.player).flatMap(PlayerKind.init(rawValue:)) ?? .netEase
        monitorStatusBarStyle = defaults.string(forKey: Key.monitorStyle).flatMap(MonitorStatusBarStyle.init(rawValue:)) ?? .rateAndBars
        monitorColoredBars = defaults.bool(forKey: Key.monitorColoredBars)
        monitorDefaultTab = defaults.string(forKey: Key.monitorDefaultTab).flatMap(MonitorTab.init(rawValue:)) ?? .cpu
        let rawInterval = defaults.double(forKey: Key.monitorInterval)
        monitorSampleInterval = MonitorSampleInterval(rawValue: rawInterval) ?? .standard
        monitorCPUAlertThreshold = MonitorCPUAlertThreshold(rawValue: defaults.integer(forKey: Key.monitorCPUAlert)) ?? .standard
        monitorRAMAlertThreshold = MonitorRAMAlertThreshold(rawValue: defaults.integer(forKey: Key.monitorRAMAlert)) ?? .standard
        monitorThermalAlertThreshold = MonitorThermalAlertThreshold(rawValue: defaults.integer(forKey: Key.monitorThermalAlert)) ?? .standard
    }
}
