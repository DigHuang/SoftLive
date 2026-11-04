import AppKit

/// The app menu, shown from the status item and by right-clicking the desktop lyrics or widget
/// (the latter matter when a crowded, notched menu bar hides the status item).
final class AppMenu: NSObject, NSMenuDelegate {
    private static let offsetStep: TimeInterval = 0.5

    let menu = NSMenu()
    private let model: PlaybackModel
    private let preferences: Preferences
    private var actions: [() -> Void] = []

    init(model: PlaybackModel, preferences: Preferences) {
        self.model = model
        self.preferences = preferences
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        actions.removeAll()

        if let track = model.playback?.track {
            menu.addItem(info(track.artist.isEmpty ? track.title : "\(track.title) — \(track.artist)"))
            menu.addItem(info("来源：\(track.source.displayName)"))
        } else {
            menu.addItem(info("未检测到正在播放的 Apple Music / 网易云音乐"))
        }
        menu.addItem(.separator())

        menu.addItem(item("显示状态栏监控", isOn: preferences.showsSystemMonitor) { [preferences] in
            preferences.showsSystemMonitor.toggle()
        })
        menu.addItem(item("状态栏歌词", isOn: preferences.showsStatusBarLyrics) { [preferences] in
            preferences.showsStatusBarLyrics.toggle()
        })
        menu.addItem(item("桌面歌词", isOn: preferences.showsDesktopLyrics) { [preferences] in
            preferences.showsDesktopLyrics.toggle()
        })
        menu.addItem(item("锁定桌面歌词（按住 ⌘ 移入唤醒）", isOn: preferences.desktopLyricsLocked) { [preferences] in
            preferences.desktopLyricsLocked.toggle()
        })
        menu.addItem(item("桌面组件", isOn: preferences.showsDesktopWidget) { [preferences] in
            preferences.showsDesktopWidget.toggle()
        })
        menu.addItem(.separator())

        let hasLyrics = model.lyrics != nil
        menu.addItem(item("歌词提前 \(Self.offsetStep) 秒", isEnabled: hasLyrics) { [model] in
            model.offset += Self.offsetStep
        })
        menu.addItem(item("歌词延后 \(Self.offsetStep) 秒", isEnabled: hasLyrics) { [model] in
            model.offset -= Self.offsetStep
        })
        let offsetText = String(format: "%+.1f", model.offset)
        menu.addItem(item("重置偏移（当前 \(offsetText) 秒）", isEnabled: model.offset != 0) { [model] in
            model.offset = 0
        })
        menu.addItem(.separator())

        menu.addItem(item("退出 SoftLive", key: "q") { NSApp.terminate(nil) })
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
