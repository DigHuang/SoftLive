import AppKit

/// The app menu, shown from the status item and by right-clicking the desktop lyrics or widget
/// (the latter matter when a crowded, notched menu bar hides the status item).
final class AppMenu: NSObject, NSMenuDelegate {
    private static let offsetStep: TimeInterval = 0.5

    let menu = NSMenu()
    var onOpenControlCenter: ((ControlCenterSection?) -> Void)?
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

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        actions.removeAll()

        if let track = model.playback?.track {
            menu.addItem(info(track.artist.isEmpty ? track.title : "\(track.title) — \(track.artist)"))
            menu.addItem(info(L10n.tr("来源：\(track.source.displayName)", "Source: \(track.source.displayName)")))
        } else {
            menu.addItem(info(L10n.tr("未检测到正在播放的 Apple Music / 网易云音乐", "No active playback in Apple Music or NetEase Music")))
        }
        menu.addItem(.separator())

        menu.addItem(item(L10n.tr("配置中心…", "Control Center…"), key: ",") { [weak self] in
            self?.onOpenControlCenter?(nil)
        })
        let languageSubmenu = NSMenu()
        for lang in AppLanguage.allCases {
            languageSubmenu.addItem(item(lang.displayName, isOn: preferences.language == lang) { [preferences] in
                preferences.language = lang
            })
        }
        let languageItem = NSMenuItem(
            title: L10n.tr("界面语言（\(preferences.language.displayName)）", "Language (\(preferences.language.displayName))"),
            action: nil,
            keyEquivalent: ""
        )
        languageItem.submenu = languageSubmenu
        menu.addItem(languageItem)
        menu.addItem(.separator())

        menu.addItem(item(L10n.tr("显示状态栏监控", "Show Status Bar Monitor"), isOn: preferences.showsSystemMonitor) { [preferences] in
            preferences.showsSystemMonitor.toggle()
        })
        menu.addItem(item(L10n.tr("状态栏歌词", "Status Bar Lyrics"), isOn: preferences.showsStatusBarLyrics) { [preferences] in
            preferences.showsStatusBarLyrics.toggle()
        })
        menu.addItem(item(L10n.tr("桌面歌词", "Desktop Lyrics"), isOn: preferences.showsDesktopLyrics) { [preferences] in
            preferences.showsDesktopLyrics.toggle()
        })
        menu.addItem(item(L10n.tr("锁定桌面歌词（按住 ⌘ 移入唤醒）", "Lock Desktop Lyrics (Hold ⌘ to Wake)"), isOn: preferences.desktopLyricsLocked) { [preferences] in
            preferences.desktopLyricsLocked.toggle()
        })
        menu.addItem(item(L10n.tr("桌面组件", "Desktop Widget"), isOn: preferences.showsDesktopWidget) { [preferences] in
            preferences.showsDesktopWidget.toggle()
        })
        menu.addItem(item(L10n.tr("演示舞台模式", "Stage Mode"), isOn: preferences.showsStageWindow) { [preferences] in
            preferences.showsStageWindow.toggle()
        })
        let stageSubmenu = NSMenu()
        for style in StageStyle.allCases {
            stageSubmenu.addItem(item("\(style.displayName) — \(style.subtitle)", isOn: preferences.stageStyle == style) { [preferences] in
                preferences.stageStyle = style
                preferences.showsStageWindow = true
            })
        }
        stageSubmenu.addItem(.separator())
        stageSubmenu.addItem(item(L10n.tr("星火特效", "Spark Particles"), isOn: preferences.stageSparks) { [preferences] in
            preferences.stageSparks.toggle()
        })
        let stageStyleItem = NSMenuItem(
            title: L10n.tr("舞台律动风格（\(preferences.stageStyle.displayName)）", "Stage Style (\(preferences.stageStyle.displayName))"),
            action: nil,
            keyEquivalent: ""
        )
        stageStyleItem.submenu = stageSubmenu
        menu.addItem(stageStyleItem)
        menu.addItem(.separator())

        let hasLyrics = model.lyrics != nil
        menu.addItem(item(L10n.tr("歌词提前 \(Self.offsetStep) 秒", "Lyrics Earlier by \(Self.offsetStep)s"), isEnabled: hasLyrics) { [model] in
            model.offset += Self.offsetStep
        })
        menu.addItem(item(L10n.tr("歌词延后 \(Self.offsetStep) 秒", "Lyrics Later by \(Self.offsetStep)s"), isEnabled: hasLyrics) { [model] in
            model.offset -= Self.offsetStep
        })
        let offsetText = String(format: "%+.1f", model.offset)
        menu.addItem(item(L10n.tr("重置偏移（当前 \(offsetText) 秒）", "Reset Offset (Current \(offsetText)s)"), isEnabled: model.offset != 0) { [model] in
            model.offset = 0
        })
        menu.addItem(.separator())

        menu.addItem(item(L10n.tr("退出 SoftLive", "Quit SoftLive"), key: "q") { NSApp.terminate(nil) })
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
}
