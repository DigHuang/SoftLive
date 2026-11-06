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
    private lazy var appMenu = AppMenu(model: model, preferences: preferences)
    private var lyricsStatusBar: LyricsStatusBar?
    private var monitorStatusBar: MonitorStatusBar?
    private var desktopLyrics: OverlayPanel?
    private var desktopWidget: OverlayPanel?
    private var stageWindow: StageWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement only applies to the bundled app; keep `swift run` out of the Dock too.
        NSApp.setActivationPolicy(.accessory)
        monitorStatusBar = MonitorStatusBar(monitor: monitor, preferences: preferences, menu: appMenu.menu)
        lyricsStatusBar = LyricsStatusBar(model: model, preferences: preferences, menu: appMenu.menu)
        desktopLyrics = DesktopLyrics.makePanel(model: model, preferences: preferences, menu: appMenu.menu)
        desktopWidget = DesktopWidget.makePanel(model: model, preferences: preferences, menu: appMenu.menu)
        stageWindow = StageWindow(model: model, preferences: preferences, menu: appMenu.menu)
        model.start()
    }

    /// Opening the app again while it runs pops the menu up at the pointer: a way back in
    /// when the status item is hidden and the desktop lyrics are locked.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.activate() // An inactive app's pop-up menu closes right away.
        appMenu.menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        return false
    }
}
