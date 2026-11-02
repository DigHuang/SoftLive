import AppKit

/// The app menu, shown from the status item and by right-clicking the desktop lyrics or widget
/// (the latter matter when a crowded, notched menu bar hides the status item).
@MainActor
final class AppMenu: NSObject, NSMenuDelegate {
    private static let offsetStep: TimeInterval = 0.5

    let menu = NSMenu()
    private let model: AppModel
    private let preferences: Preferences

    init(model: AppModel, preferences: Preferences) {
        self.model = model
        self.preferences = preferences
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if let track = model.playback?.track {
            menu.addItem(.info(track.artist.isEmpty ? track.title : "\(track.title) — \(track.artist)"))
            menu.addItem(.info("来源：\(track.source.displayName)"))
        } else {
            menu.addItem(.info("未检测到正在播放的 Apple Music / 网易云音乐"))
        }
        menu.addItem(.separator())

        menu.addItem(ActionMenuItem("状态栏歌词", isOn: preferences.showsStatusBarLyrics) { [preferences] in
            preferences.showsStatusBarLyrics.toggle()
        })
        menu.addItem(ActionMenuItem("桌面歌词", isOn: preferences.showsDesktopLyrics) { [preferences] in
            preferences.showsDesktopLyrics.toggle()
        })
        menu.addItem(ActionMenuItem("锁定桌面歌词（鼠标穿透）", isOn: preferences.desktopLyricsLocked) { [preferences] in
            preferences.desktopLyricsLocked.toggle()
        })
        menu.addItem(ActionMenuItem("桌面组件", isOn: preferences.showsDesktopWidget) { [preferences] in
            preferences.showsDesktopWidget.toggle()
        })
        menu.addItem(.separator())

        let hasLyrics = model.lyrics != nil
        menu.addItem(ActionMenuItem("歌词提前 \(Self.offsetStep) 秒", isEnabled: hasLyrics) { [model] in
            model.offset += Self.offsetStep
        })
        menu.addItem(ActionMenuItem("歌词延后 \(Self.offsetStep) 秒", isEnabled: hasLyrics) { [model] in
            model.offset -= Self.offsetStep
        })
        let offsetText = String(format: "%+.1f", model.offset)
        menu.addItem(ActionMenuItem("重置偏移（当前 \(offsetText) 秒）", isEnabled: model.offset != 0) { [model] in
            model.offset = 0
        })
        menu.addItem(.separator())

        menu.addItem(ActionMenuItem("退出 SoftLive", key: "q") { NSApp.terminate(nil) })
    }
}

/// A menu item that runs a closure.
@MainActor
private final class ActionMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, isOn: Bool? = nil, isEnabled: Bool = true, key: String = "", handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
        self.isEnabled = isEnabled
        if let isOn { state = isOn ? .on : .off }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() { handler() }
}

private extension NSMenuItem {
    static func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}
