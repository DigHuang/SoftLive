import AppKit

@main
enum SoftLive {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = PlaybackModel()
    private let preferences = Preferences()
    private lazy var monitor = SystemMonitor(preferences: preferences)
    private lazy var cleaner = DiskCleaner(preferences: preferences)
    private lazy var appMenu = AppMenu(model: model, preferences: preferences) { [weak self] section in
        self?.controlCenterWindow?.show(section: section)
    }
    private var lyricsStatusBar: LyricsStatusBar?
    private var monitorStatusBar: MonitorStatusBar?
    private var desktopLyrics: OverlayPanel?
    private var desktopWidget: OverlayPanel?
    private var stageWindow: StageWindow?
    private var controlCenterWindow: ControlCenterWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement only applies to the bundled app; keep `swift run` out of the Dock too.
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = appMenu.makeMainMenu()
        monitorStatusBar = MonitorStatusBar(
            monitor: monitor,
            preferences: preferences,
            menu: appMenu.menu,
            onOpenSettings: { [weak self] in
                self?.controlCenterWindow?.show(section: .monitor)
            }
        )
        lyricsStatusBar = LyricsStatusBar(model: model, preferences: preferences, menu: appMenu.menu)
        desktopLyrics = DesktopLyrics.makePanel(model: model, preferences: preferences, menu: appMenu.menu)
        desktopWidget = DesktopWidget.makePanel(model: model, preferences: preferences, menu: appMenu.menu)
        stageWindow = StageWindow(model: model, preferences: preferences, menu: appMenu.menu)
        controlCenterWindow = ControlCenterWindow(
            model: model,
            monitor: monitor,
            cleaner: cleaner,
            preferences: preferences
        )
        model.start()
    }

    /// Reopening the app brings up the unified Desktop Configuration Center window:
    /// a discoverable entry point even when the status item is hidden behind the notch
    /// and the desktop lyrics are locked.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controlCenterWindow?.show()
        return false
    }
}
