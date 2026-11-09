import AppKit

/// Compact quick-action menu shown from status items and by right-clicking desktop panels,
/// plus the application's standard `NSApp.mainMenu` for global keyboard shortcuts (`⌘Q`, `⌘W`, `⌘M`, `⌘,`).
final class AppMenu: NSObject, NSMenuDelegate {
    private static let offsetStep: TimeInterval = 0.5
    private static let maxTrackTitleLength = 22

    let menu = NSMenu()
    var onOpenControlCenter: ((ControlCenterSection?) -> Void)?
    var onQuit: () -> Void = { NSApp.terminate(nil) }
    private let model: PlaybackModel
    private let preferences: Preferences
    private var actions: [() -> Void] = []

    init(
        model: PlaybackModel,
        preferences: Preferences,
        onOpenControlCenter: ((ControlCenterSection?) -> Void)? = nil
    ) {
        self.model = model
        self.preferences = preferences
        self.onOpenControlCenter = onOpenControlCenter
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
    }

    /// Builds the application `mainMenu` so standard shortcuts (`⌘Q`, `⌘W`, `⌘M`, `⌘,`, `⌘H`)
    /// work when `ControlCenterWindow` or `StageWindow` is the key window.
    func makeMainMenu() -> NSMenu {
        _ = NSApplication.shared
        let mainMenu = NSMenu()

        let appRootItem = NSMenuItem()
        mainMenu.addItem(appRootItem)
        let appSubmenu = NSMenu(title: "SoftLive")
        let settingsItem = NSMenuItem(
            title: L10n.tr("配置中心…", "Control Center…"),
            action: #selector(openControlCenterFromShortcut(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = self
        appSubmenu.addItem(settingsItem)
        appSubmenu.addItem(.separator())
        appSubmenu.addItem(
            withTitle: L10n.tr("隐藏 SoftLive", "Hide SoftLive"),
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        let quitItem = NSMenuItem(
            title: L10n.tr("退出 SoftLive", "Quit SoftLive"),
            action: #selector(quitFromShortcut(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        appSubmenu.addItem(quitItem)
        appRootItem.submenu = appSubmenu

        let windowRootItem = NSMenuItem()
        mainMenu.addItem(windowRootItem)
        let windowSubmenu = NSMenu(title: L10n.tr("窗口", "Window"))
        windowSubmenu.addItem(
            withTitle: L10n.tr("关闭窗口", "Close Window"),
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        windowSubmenu.addItem(
            withTitle: L10n.tr("最小化", "Minimize"),
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        windowSubmenu.addItem(.separator())
        let tabSpecs: [(ControlCenterSection, String)] = [
            (.player, "1"),
            (.monitor, "2"),
            (.cleaner, "3"),
            (.about, "4")
        ]
        for (index, spec) in tabSpecs.enumerated() {
            let tabItem = NSMenuItem(
                title: spec.0.title,
                action: #selector(openSectionFromShortcut(_:)),
                keyEquivalent: spec.1
            )
            tabItem.tag = index
            tabItem.target = self
            windowSubmenu.addItem(tabItem)
        }
        windowRootItem.submenu = windowSubmenu

        return mainMenu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        actions.removeAll()

        if let track = model.playback?.track {
            let raw = track.artist.isEmpty ? track.title : "\(track.title) — \(track.artist)"
            menu.addItem(info(Self.truncated(raw, limit: Self.maxTrackTitleLength)))
        } else {
            menu.addItem(info(L10n.tr("暂未播放", "Not Playing")))
        }
        menu.addItem(.separator())

        menu.addItem(item(L10n.tr("桌面歌词", "Desktop Lyrics"), isOn: preferences.showsDesktopLyrics) { [preferences] in
            preferences.showsDesktopLyrics.toggle()
        })
        menu.addItem(item(L10n.tr("锁定桌面歌词", "Lock Desktop Lyrics"), isOn: preferences.desktopLyricsLocked) { [preferences] in
            preferences.desktopLyricsLocked.toggle()
        })
        menu.addItem(item(L10n.tr("桌面组件", "Desktop Widget"), isOn: preferences.showsDesktopWidget) { [preferences] in
            preferences.showsDesktopWidget.toggle()
        })
        menu.addItem(item(L10n.tr("演示舞台", "Stage Window"), isOn: preferences.showsStageWindow) { [preferences] in
            preferences.showsStageWindow.toggle()
        })

        let hasLyrics = model.lyrics != nil
        let offsetSubmenu = NSMenu()
        offsetSubmenu.autoenablesItems = false
        offsetSubmenu.addItem(item(L10n.tr("提前 0.5 秒", "Earlier +0.5s"), isEnabled: hasLyrics) { [model] in
            model.offset += Self.offsetStep
        })
        offsetSubmenu.addItem(item(L10n.tr("延后 0.5 秒", "Later -0.5s"), isEnabled: hasLyrics) { [model] in
            model.offset -= Self.offsetStep
        })
        offsetSubmenu.addItem(.separator())
        let offsetText = String(format: "%+.1fs", model.offset)
        offsetSubmenu.addItem(item(L10n.tr("重置偏移（\(offsetText)）", "Reset (\(offsetText))"), isEnabled: model.offset != 0) { [model] in
            model.offset = 0
        })
        let offsetItem = NSMenuItem(
            title: L10n.tr("歌词偏移", "Lyrics Offset"),
            action: nil,
            keyEquivalent: ""
        )
        offsetItem.isEnabled = hasLyrics
        offsetItem.submenu = offsetSubmenu
        menu.addItem(offsetItem)
        menu.addItem(.separator())

        menu.addItem(item(L10n.tr("配置中心…", "Control Center…"), key: ",") { [weak self] in
            self?.onOpenControlCenter?(nil)
        })
        menu.addItem(item(L10n.tr("退出 SoftLive", "Quit SoftLive"), key: "q") { [weak self] in
            self?.onQuit()
        })
    }

    private static func truncated(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }

    private func item(
        _ title: String, isOn: Bool? = nil, isEnabled: Bool = true, key: String = "", action: @escaping () -> Void
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(runAction(_:)), keyEquivalent: key)
        item.target = self
        item.tag = actions.count
        item.isEnabled = isEnabled
        if let isOn { item.state = isOn ? .on : .off }
        actions.append(action)
        return item
    }

    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func runAction(_ sender: NSMenuItem) {
        actions[sender.tag]()
    }

    @objc private func openControlCenterFromShortcut(_ sender: Any?) {
        onOpenControlCenter?(nil)
    }

    @objc private func openSectionFromShortcut(_ sender: NSMenuItem) {
        let all: [ControlCenterSection] = [.player, .monitor, .cleaner, .about]
        guard all.indices.contains(sender.tag) else { return }
        onOpenControlCenter?(all[sender.tag])
    }

    @objc private func quitFromShortcut(_ sender: Any?) {
        onQuit()
    }
}
