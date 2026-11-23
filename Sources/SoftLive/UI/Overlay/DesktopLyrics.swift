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
        return panel.bind(
            {
                let isVisible = preferences.showsDesktopLyrics && model.playback != nil
                guard isVisible else { return (false, true) }
                let clicksThrough = preferences.desktopLyricsLocked && !interaction.isAwake
                return (true, clicksThrough)
            },
            onVisibilityChange: { visible in
                if !visible { interaction.reset() }
            }
        )
    }
}

/// Tracks the Command (⌘) wakeup key and mouse hover so locked lyrics stay 100% click-through
/// when the cursor passes over them without ⌘, and wake up only when ⌘ is held.
@Observable
final class LyricsInteraction {
    @ObservationIgnored var isCommandHeld = false
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
            guard let self, let panel = self.panel, panel.isVisible else { return event }
            let command = event.modifierFlags.contains(.command)
            let buttonsPressed = event.type != .leftMouseUp && NSEvent.pressedMouseButtons != 0
            MainActor.assumeIsolated { self.reevaluate(command: command, buttonsPressed: buttonsPressed) }
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

struct DesktopLyricsView: View {
    static let cardWidth: CGFloat = 640
    static let cardHeight: CGFloat = 122
    static let margin: CGFloat = 12
    static let panelSize = NSSize(width: cardWidth + 2 * margin, height: cardHeight + 2 * margin)
    private static let offsetStep: TimeInterval = 0.5

    let model: PlaybackModel
    let preferences: Preferences
    let interaction: LyricsInteraction

    @Environment(\.colorScheme) private var colorScheme

    private var activeLine: LyricLine {
        if let line = model.currentLine, !line.text.isEmpty { return line }
        return LyricLine(time: 0, text: model.headline)
    }

    private var showsControls: Bool {
        interaction.isAwake
    }

    private var trackTitleSummary: String {
        guard let track = model.playback?.track else { return "SoftLive" }
        return track.artist.isEmpty ? track.title : "\(track.title) — \(track.artist)"
    }

    private var displayedSubline: String? {
        switch preferences.desktopLyricsSublineMode {
        case .translationThenNext:
            model.subline
        case .translationOnly:
            model.currentLine?.translation
        case .singleLine:
            nil
        }
    }

    var body: some View {
        if !preferences.showsDesktopLyrics || (model.playback == nil && !interaction.isAwake) {
            Color.clear.frame(width: 0, height: 0)
        } else {
            let sizePreset = preferences.desktopLyricsSize
            let sublineText = displayedSubline

            VStack(spacing: 4) {
                controlBar
                    .opacity(showsControls ? 1 : 0)
                    .allowsHitTesting(showsControls)

                KaraokeText(
                    line: activeLine,
                    model: model,
                    fontSize: sizePreset.mainFontSize,
                    weight: .semibold,
                    color: .white,
                    centered: true,
                    hasShadow: true
                )
                .allowsHitTesting(false)

                if preferences.desktopLyricsSublineMode != .singleLine {
                    Text(sublineText ?? " ")
                        .font(.system(size: sizePreset.sublineFontSize, weight: .medium))
                        .foregroundStyle(.white.opacity(0.76))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .shadow(color: .black.opacity(0.55), radius: 2, y: 0.8)
                        .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
                        .frame(height: 21)
                        .opacity(sublineText == nil ? 0 : 1)
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 12)
            .frame(width: Self.cardWidth, height: Self.cardHeight)
            .background {
                Group {
                    if showsControls {
                        ZStack {
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .fill(Color.black.opacity(0.24))
                            Color.clear
                                .glassEffect(.regular, in: .rect(cornerRadius: 24))
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
                        }
                    } else {
                        Color.clear
                    }
                }
                .contentShape(.rect(cornerRadius: 24))
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
    }

    private var controlBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(nsImage: BrandAssets.syncTemplate)
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 13, height: 13)
                    .foregroundStyle(.white.opacity(0.78))
                Text(trackTitleSummary)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.84))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .allowsHitTesting(false)

            Spacer(minLength: 8)

            if model.lyrics != nil {
                offsetStepper
            }

            HStack(spacing: 6) {
                barButton(
                    icon: model.isPlaying ? "pause.fill" : "play.fill",
                    opticalOffsetX: model.isPlaying ? 0 : 1,
                    help: model.isPlaying ? L10n.tr("暂停", "Pause") : L10n.tr("继续播放", "Play"),
                    action: model.togglePlayPause
                )
                barButton(
                    icon: preferences.desktopLyricsLocked ? "cursorarrow.motionlines" : "cursorarrow",
                    help: preferences.desktopLyricsLocked
                        ? L10n.tr("已开启穿透（按住 ⌘ 移入唤醒；点击改为普通悬停唤醒）", "Click-through enabled (Hold ⌘ to wake; click to wake on normal hover)")
                        : L10n.tr("已解锁（点击开启鼠标穿透）", "Unlocked (Click to enable click-through)")
                ) {
                    preferences.desktopLyricsLocked.toggle()
                }
                barButton(icon: "eye.slash", help: L10n.tr("隐藏桌面歌词", "Hide Desktop Lyrics")) {
                    interaction.isAwake = false
                    preferences.showsDesktopLyrics = false
                }
            }
        }
        .frame(height: 26)
    }

    private var offsetStepper: some View {
        HStack(spacing: 0) {
            stepperAdjustButton("-0.5s", help: L10n.tr("歌词延后 0.5 秒", "Delay lyrics by 0.5s")) {
                model.offset -= Self.offsetStep
            }

            if model.offset != 0 {
                Text(String(format: "%+.1fs", model.offset))
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(colorScheme == .dark ? Color.black.opacity(0.88) : .white)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(SoftLiveTheme.accent, in: .capsule)
                    .contentShape(.capsule)
                    .help(L10n.tr("点击重置歌词偏移", "Click to reset lyrics offset"))
                    .onTapGesture {
                        model.offset = 0
                    }
            } else {
                Rectangle()
                    .fill(.white.opacity(0.16))
                    .frame(width: 0.5, height: 12)
            }

            stepperAdjustButton("+0.5s", help: L10n.tr("歌词提前 0.5 秒", "Advance lyrics by 0.5s")) {
                model.offset += Self.offsetStep
            }
        }
        .padding(.horizontal, 3)
        .frame(height: 26)
        .background(.white.opacity(0.14), in: .capsule)
        .overlay {
            Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 0.5)
        }
    }

    private func stepperAdjustButton(_ title: String, help: String, action: @escaping () -> Void) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.88))
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 7)
            .frame(height: 26)
            .contentShape(Rectangle())
            .help(help)
            .onTapGesture(perform: action)
    }

    private func barButton(
        icon: String,
        opticalOffsetX: CGFloat = 0,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Image(systemName: icon)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.94))
            .offset(x: opticalOffsetX)
            .frame(width: 26, height: 26)
            .background(.white.opacity(0.14), in: .circle)
            .overlay {
                Circle().strokeBorder(.white.opacity(0.16), lineWidth: 0.5)
            }
            .contentShape(.circle)
            .help(help)
            .onTapGesture(perform: action)
    }
}
