import AppKit
import Observation
import SwiftUI

/// Floating desktop lyrics: above all windows (full-screen apps included).
/// By default they click through completely; holding Command (⌘) while hovering wakes up the
/// Liquid Glass card and keeps it awake while the cursor remains inside, so you can release ⌘
/// and click, double-click for next track, or drag normally.
enum DesktopLyrics {
    static func makePanel(model: PlaybackModel, preferences: Preferences, menu: NSMenu) -> OverlayPanel {
        let interaction = LyricsInteraction()
        let panel = OverlayPanel(
            frameName: "SoftLiveDesktopLyrics",
            size: DesktopLyricsView.panelSize,
            level: .floating,
            extraBehavior: .fullScreenAuxiliary,
            allowsKey: true,
            menu: menu,
            content: DesktopLyricsView(model: model, preferences: preferences, interaction: interaction)
        ) { screen, size in
            NSPoint(x: screen.midX - size.width / 2, y: screen.minY + 48)
        }
        interaction.attach(to: panel)
        return panel.bind {
            let isVisible = preferences.showsDesktopLyrics && model.playback != nil
            if !isVisible { interaction.reset() }
            let clicksThrough = preferences.desktopLyricsLocked && !interaction.isCommandHeld && !interaction.isAwake
            return (isVisible, clicksThrough)
        }
    }
}

/// Tracks the Command (⌘) wakeup key and mouse hover so locked lyrics stay 100% click-through
/// when the cursor passes over them without ⌘, and wake up only when ⌘ is held.
@Observable
final class LyricsInteraction {
    var isCommandHeld = false
    var isAwake = false

    @ObservationIgnored private weak var panel: NSPanel?
    @ObservationIgnored private var globalMonitor: Any?
    @ObservationIgnored private var localMonitor: Any?

    func attach(to panel: NSPanel) {
        self.panel = panel
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .leftMouseUp]) { [weak self] event in
            guard let self, let panel = self.panel, panel.isVisible else { return }
            let command = event.modifierFlags.contains(.command)
            let buttonsPressed = event.type != .leftMouseUp && NSEvent.pressedMouseButtons != 0
            Task { @MainActor [weak self] in self?.reevaluate(command: command, buttonsPressed: buttonsPressed) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .leftMouseUp]) { [weak self] event in
            let command = event.modifierFlags.contains(.command)
            let buttonsPressed = event.type != .leftMouseUp && NSEvent.pressedMouseButtons != 0
            MainActor.assumeIsolated { self?.reevaluate(command: command, buttonsPressed: buttonsPressed) }
            return event
        }
    }

    isolated deinit {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }

    func reset() {
        if isCommandHeld { isCommandHeld = false }
        if isAwake { isAwake = false }
    }

    func setHovered(_ hovering: Bool, isLocked: Bool) {
        let command = NSEvent.modifierFlags.contains(.command)
        if isCommandHeld != command { isCommandHeld = command }
        if hovering {
            if (!isLocked || command) && !isAwake {
                isAwake = true
            }
        } else if NSEvent.pressedMouseButtons == 0, isAwake {
            isAwake = false
        }
    }

    func reevaluate(command: Bool, buttonsPressed: Bool, mouseLocation: NSPoint = NSEvent.mouseLocation) {
        guard let panel, panel.isVisible else {
            reset()
            return
        }
        if isCommandHeld != command { isCommandHeld = command }
        let cardFrame = panel.frame.insetBy(dx: DesktopLyricsView.margin, dy: DesktopLyricsView.margin)
        let inside = cardFrame.contains(mouseLocation)
        if command, inside {
            if !isAwake { isAwake = true }
        } else if !inside, !buttonsPressed {
            if isAwake { isAwake = false }
        }
    }
}

private struct DesktopLyricsView: View {
    static let cardWidth: CGFloat = 640
    static let cardHeight: CGFloat = 112
    static let margin: CGFloat = 12
    static let panelSize = NSSize(width: cardWidth + 2 * margin, height: cardHeight + 2 * margin)

    let model: PlaybackModel
    let preferences: Preferences
    let interaction: LyricsInteraction

    private var activeLine: LyricLine {
        if let line = model.currentLine, !line.text.isEmpty { return line }
        return LyricLine(time: 0, text: model.headline)
    }

    private var showsControls: Bool {
        interaction.isAwake
    }

    var body: some View {
        VStack(spacing: 4) {
            controlBar
                .opacity(showsControls ? 1 : 0)
                .allowsHitTesting(showsControls)

            KaraokeText(
                line: activeLine,
                model: model,
                fontSize: 26,
                weight: .semibold,
                color: .white,
                centered: true,
                hasShadow: true
            )
            .allowsHitTesting(false)

            Text(model.subline ?? " ")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.76))
                .shadow(color: .black.opacity(0.55), radius: 2, y: 0.8)
                .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
                .frame(height: 20)
                .opacity(model.subline == nil ? 0 : 1)
                .allowsHitTesting(false)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .frame(width: Self.cardWidth, height: Self.cardHeight)
        .background {
            Group {
                if showsControls {
                    Color.clear.glassEffect(.regular, in: .rect(cornerRadius: 22))
                } else {
                    Color.clear
                }
            }
            .contentShape(.rect(cornerRadius: 22))
            .onTapGesture(count: 2) {
                model.nextTrack()
            }
        }
        .onHover { hovering in
            interaction.setHovered(hovering, isLocked: preferences.desktopLyricsLocked)
        }
        .onChange(of: preferences.desktopLyricsLocked) { _, isLocked in
            if isLocked { interaction.isAwake = false }
        }
        .padding(Self.margin)
        .frame(width: Self.panelSize.width, height: Self.panelSize.height)
        .animation(.easeInOut(duration: 0.18), value: showsControls)
    }

    private var controlBar: some View {
        HStack(spacing: 6) {
            barButton(
                icon: model.isPlaying ? "pause.fill" : "play.fill",
                help: model.isPlaying ? "暂停" : "继续播放",
                action: model.togglePlayPause
            )
            barButton(
                icon: preferences.desktopLyricsLocked ? "lock.fill" : "lock.open.fill",
                help: preferences.desktopLyricsLocked ? "已开启穿透（按住 ⌘ 移入唤醒；点击改为普通悬停唤醒）" : "已解锁（点击开启鼠标穿透）"
            ) {
                preferences.desktopLyricsLocked.toggle()
            }
            barButton(icon: "xmark", help: "隐藏桌面歌词") {
                interaction.isAwake = false
                preferences.showsDesktopLyrics = false
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(.black.opacity(0.26), in: .capsule)
        .frame(height: 26)
    }

    private func barButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: 24, height: 22)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
