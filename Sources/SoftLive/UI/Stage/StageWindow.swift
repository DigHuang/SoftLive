import AppKit
import Observation
import SwiftUI

/// Standalone showcase stage window ("演示舞台模式"):
/// fluid album-tinted aurora backdrop, two hardware-accelerated kinetic typography styles
/// (`流光`, `描金`), radial spark bursts, vinyl interlude centerpiece,
/// and hover-revealed dark obsidian HUD controls.
final class StageWindow: NSPanel {
    static let defaultSize = NSSize(width: 920, height: 580)
    static let minWindowSize = NSSize(width: 680, height: 440)
    private static let frameAutosave = "SoftLiveStageWindow"

    private let state = StageWindowState()
    private let onRequestClose: () -> Void
    private var observeTask: Task<Void, Never>?
    private var savedWindowedFrame: NSRect?
    private(set) var isZoomedToScreen = false

    override var minSize: NSSize {
        get { Self.minWindowSize }
        set { super.minSize = Self.minWindowSize }
    }

    override var contentMinSize: NSSize {
        get { Self.minWindowSize }
        set { super.contentMinSize = Self.minWindowSize }
    }

    init(model: PlaybackModel, preferences: Preferences, menu: NSMenu) {
        self.onRequestClose = { [preferences] in preferences.showsStageWindow = false }
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.borderless, .nonactivatingPanel, .resizable, .closable],
            backing: .buffered,
            defer: true
        )
        level = .normal
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        minSize = Self.minWindowSize
        appearance = NSAppearance(named: .darkAqua)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false

        let rootView = StageWindowView(
            model: model,
            preferences: preferences,
            windowState: state,
            onToggleZoom: { [weak self] in self?.toggleScreenZoom() },
            onClose: onRequestClose
        )
        let host = StageHostingView(rootView: rootView)
        host.sizingOptions = []
        host.menu = menu
        contentView = host

        if setFrameUsingName(Self.frameAutosave) {
            let clamped = Self.clampedFrame(frame, minSize: Self.minWindowSize) { screen, size in
                NSPoint(
                    x: round(screen.midX - size.width / 2),
                    y: round(screen.midY - size.height / 2)
                )
            }
            if clamped != frame {
                setFrame(clamped, display: false)
            }
        } else if let screen = NSScreen.main?.visibleFrame {
            let origin = NSPoint(
                x: round(screen.midX - Self.defaultSize.width / 2),
                y: round(screen.midY - Self.defaultSize.height / 2)
            )
            setFrameOrigin(origin)
        }
        setFrameAutosaveName(Self.frameAutosave)

        observeTask = Task { [weak self] in
            var lastVisible: Bool?
            for await isVisible in Observations({ preferences.showsStageWindow }) {
                guard let self else { return }
                guard lastVisible != isVisible else { continue }
                lastVisible = isVisible
                if !isVisible { state.isHovered = false }
                self.contentView?.isHidden = !isVisible
                if isVisible {
                    if NSApp.isActive {
                        self.makeKeyAndOrderFront(nil)
                    } else {
                        self.orderFrontRegardless()
                    }
                } else {
                    self.orderOut(nil)
                }
            }
        }
    }

    isolated deinit {
        observeTask?.cancel()
    }

    override var canBecomeKey: Bool { true }

    // Borderless panels default to returning false for `performClose:` even with `.closable` set.
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(performClose(_:)) {
            return true
        }
        return super.validateMenuItem(menuItem)
    }

    override func performClose(_ sender: Any?) {
        onRequestClose()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func toggleScreenZoom() {
        guard let screen = (self.screen ?? NSScreen.main)?.visibleFrame else { return }
        if isZoomedToScreen, let restore = savedWindowedFrame {
            isZoomedToScreen = false
            state.isZoomed = false
            let clamped = Self.clampedFrame(restore, minSize: Self.minWindowSize)
            setFrame(clamped, display: true, animate: true)
            setFrameAutosaveName(Self.frameAutosave)
        } else {
            savedWindowedFrame = frame
            isZoomedToScreen = true
            state.isZoomed = true
            setFrameAutosaveName("")
            setFrame(screen, display: true, animate: true)
        }
    }
}

@Observable
final class StageWindowState {
    var isHovered = false
    var isZoomed = false

    func palette(for artwork: NSImage?) -> StagePalette {
        StagePalette.cached(for: artwork)
    }
}

private final class StageHostingView<Content: View>: NSHostingView<Content> {
    private var mouseDownPoint: NSPoint?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if NSApp.isActive {
            window?.makeKey()
        }
        mouseDownPoint = event.locationInWindow
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if let start = mouseDownPoint,
           hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) >= 4 {
            mouseDownPoint = nil
            window?.performDrag(with: event)
            return
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownPoint = nil
        super.mouseUp(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu else { return super.rightMouseDown(with: event) }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

struct StageWindowView: View {
    let model: PlaybackModel
    let preferences: Preferences
    let windowState: StageWindowState
    let onToggleZoom: () -> Void
    let onClose: () -> Void

    private var activeArtwork: NSImage? {
        if model.playback != nil { return model.artwork }
        return model.recentArtworks[preferences.preferredPlayer]
    }

    private var activeLine: LyricLine {
        if let line = model.currentLine, !line.text.isEmpty {
            return line
        }
        if let track = model.playback?.track {
            return LyricLine(time: 0, text: track.title)
        }
        if let recent = model.recentTracks[preferences.preferredPlayer] {
            return LyricLine(time: 0, text: recent.title)
        }
        return LyricLine(time: 0, text: L10n.tr("SoftLive 舞台模式", "SoftLive Stage"))
    }

    private var nextLineTime: TimeInterval? {
        guard let lyrics = model.lyrics,
              let nextIdx = lyrics.nextSungIndex(after: model.currentIndex)
        else { return nil }
        return lyrics.lines[nextIdx].time
    }

    private var hasLyricLine: Bool {
        if let line = model.currentLine, !line.text.isEmpty {
            return true
        }
        return false
    }

    var body: some View {
        if !preferences.showsStageWindow {
            Color.clear.frame(width: 0, height: 0)
        } else {
            let palette = windowState.palette(for: activeArtwork)
            let showHUD = windowState.isHovered || model.playback == nil

            ZStack {
                StageCanvasRepresentable(
                    line: activeLine,
                    nextLineTime: nextLineTime,
                    subline: model.subline,
                    interlude: model.interlude,
                    playback: model.playback,
                    offset: model.offset,
                    style: preferences.stageStyle,
                    sparks: preferences.stageSparks,
                    palette: palette,
                    artwork: activeArtwork,
                    isLyricLine: hasLyricLine
                )

                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        if model.playback != nil {
                            model.nextTrack()
                        }
                    }

                VStack(spacing: 0) {
                    topBar(palette: palette)
                        .opacity(showHUD ? 1 : 0)
                        .allowsHitTesting(showHUD)

                    Spacer(minLength: 0)

                    bottomBar(palette: palette)
                        .opacity(showHUD ? 1 : 0)
                        .allowsHitTesting(showHUD)
                }
                .padding(16)
            }
            .clipShape(.rect(cornerRadius: 26))
            .overlay {
                RoundedRectangle(cornerRadius: 26)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .onHover { hovering in
                if windowState.isHovered != hovering {
                    windowState.isHovered = hovering
                }
            }
            .animation(.easeInOut(duration: 0.22), value: showHUD)
        }
    }

    // MARK: - Top Style & Window HUD

    private func topBar(palette: StagePalette) -> some View {
        HStack(spacing: 10) {
            // Top-left: clean standalone window action circles without double-nested capsule borders or verbose text.
            HStack(spacing: 8) {
                hudCircleButton(
                    icon: "xmark",
                    palette: palette,
                    help: L10n.tr("关闭演示舞台", "Close Stage Window"),
                    action: onClose
                )
                hudCircleButton(
                    icon: windowState.isZoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                    palette: palette,
                    help: windowState.isZoomed ? L10n.tr("还原舞台窗口", "Restore Stage Window") : L10n.tr("切换最大化舞台", "Toggle Maximize Stage"),
                    action: onToggleZoom
                )
            }

            Spacer(minLength: 0)

            // Top-right: 32pt segmented style capsule separated by 8pt from standalone Sparks toggle pill.
            HStack(spacing: 8) {
                HStack(spacing: 2) {
                    ForEach(StageStyle.allCases, id: \.self) { style in
                        let isSelected = preferences.stageStyle == style
                        Text(style.displayName)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? .white : .white.opacity(0.62))
                            .padding(.horizontal, 12)
                            .frame(height: 26)
                            .background {
                                if isSelected {
                                    Capsule()
                                        .fill(.white.opacity(0.18))
                                }
                            }
                            .contentShape(.capsule)
                            .help(style.subtitle)
                            .onTapGesture {
                                preferences.stageStyle = style
                            }
                    }
                }
                .padding(3)
                .background { hudSurface(in: Capsule(), palette: palette) }

                sparksTogglePill(palette: palette)
            }
        }
    }

    private func sparksTogglePill(palette: StagePalette) -> some View {
        let isEnabled = preferences.stageSparks
        let accent = Color(nsColor: palette.accent)

        return HStack(spacing: 5) {
            Image(systemName: "sparkle")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(isEnabled ? accent : .white.opacity(0.56))
            Text(L10n.tr("星火", "Sparks"))
                .font(.system(size: 12, weight: isEnabled ? .semibold : .medium))
                .foregroundStyle(isEnabled ? .white : .white.opacity(0.58))
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background { hudSurface(in: Capsule(), palette: palette, isHighlighted: isEnabled) }
        .contentShape(.capsule)
        .help(L10n.tr("切换星火粒子特效", "Toggle Spark Particles"))
        .onTapGesture {
            preferences.stageSparks.toggle()
        }
    }

    // MARK: - Bottom Corner HUD (No Full-Width Bar Background)

    private func bottomBar(palette: StagePalette) -> some View {
        let track = model.playback?.track ?? model.recentTracks[preferences.preferredPlayer]

        return HStack(alignment: .center, spacing: 12) {
            HStack(spacing: 10) {
                Group {
                    if let art = activeArtwork {
                        Image(nsImage: art)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle()
                            .fill(.white.opacity(0.10))
                            .overlay {
                                Image(nsImage: BrandAssets.syncTemplate)
                                    .renderingMode(.template)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 20, height: 20)
                                    .foregroundStyle(.white.opacity(0.72))
                            }
                    }
                }
                .frame(width: 38, height: 38)
                .clipShape(.rect(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.white.opacity(0.16), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.32), radius: 8, y: 3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(track?.title ?? L10n.tr("未在播放", "Not Playing"))
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let artist = track?.artist, !artist.isEmpty {
                        Text(artist)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.68))
                            .lineLimit(1)
                    }
                }
                .shadow(color: .black.opacity(0.55), radius: 4, y: 1)
                .frame(maxWidth: 260, alignment: .leading)
            }
            .allowsHitTesting(false)

            Spacer(minLength: 16)

            hudCircleButton(
                icon: model.isPlaying ? "pause.fill" : "play.fill",
                opticalOffsetX: model.isPlaying ? 0 : 1,
                palette: palette,
                help: model.isPlaying ? L10n.tr("暂停", "Pause") : L10n.tr("播放", "Play")
            ) {
                if model.playback != nil {
                    model.togglePlayPause()
                } else {
                    model.play(preferences.preferredPlayer)
                }
            }
        }
    }

    private func hudSurface<S: InsettableShape>(
        in shape: S,
        palette: StagePalette,
        isHighlighted: Bool = false
    ) -> some View {
        let obsidianTint = Color(nsColor: palette.backgroundTop)
        let accent = Color(nsColor: palette.accent)
        return ZStack {
            shape.fill(Color(red: 0.035, green: 0.04, blue: 0.055).opacity(0.58))
            shape.fill(obsidianTint.opacity(0.36))
            shape.fill(
                LinearGradient(
                    colors: [accent.opacity(0.07), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            if isHighlighted {
                shape.fill(accent.opacity(0.14))
            }
        }
        .overlay {
            shape.strokeBorder(
                LinearGradient(
                    colors: isHighlighted
                        ? [accent.opacity(0.42), Color.white.opacity(0.24), accent.opacity(0.22)]
                        : [Color.white.opacity(0.24), accent.opacity(0.16), Color.white.opacity(0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 0.5
            )
        }
        .shadow(color: .black.opacity(0.30), radius: 10, y: 4)
    }

    private func hudCircleButton(
        icon: String,
        opticalOffsetX: CGFloat = 0,
        palette: StagePalette,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Image(systemName: icon)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(0.90))
            .offset(x: opticalOffsetX)
            .frame(width: 32, height: 32)
            .background { hudSurface(in: Circle(), palette: palette) }
            .contentShape(.circle)
            .help(help)
            .onTapGesture(perform: action)
    }
}

private struct StageCanvasRepresentable: NSViewRepresentable {
    let line: LyricLine
    let nextLineTime: TimeInterval?
    let subline: String?
    let interlude: Interlude?
    let playback: PlaybackState?
    let offset: TimeInterval
    let style: StageStyle
    let sparks: Bool
    let palette: StagePalette
    let artwork: NSImage?
    let isLyricLine: Bool

    func makeNSView(context: Context) -> StageCanvasView {
        StageCanvasView()
    }

    func updateNSView(_ nsView: StageCanvasView, context: Context) {
        nsView.configure(
            line: line,
            nextLineTime: nextLineTime,
            subline: subline,
            interlude: interlude,
            playback: playback,
            offset: offset,
            style: style,
            sparks: sparks,
            palette: palette,
            artwork: artwork,
            isLyricLine: isLyricLine
        )
    }
}
