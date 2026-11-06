import AppKit
import Observation
import SwiftUI

/// Standalone showcase stage window ("演示舞台模式"):
/// fluid album-tinted aurora backdrop, four hardware-accelerated kinetic typography styles
/// (`流光`, `云阶`, `海报`, `描金`), radial spark bursts, vinyl interlude centerpiece,
/// and hover-revealed Liquid Glass HUD controls.
final class StageWindow: NSPanel {
    static let defaultSize = NSSize(width: 920, height: 580)
    static let minWindowSize = NSSize(width: 680, height: 440)
    private static let frameAutosave = "SoftLiveStageWindow"

    private var savedWindowedFrame: NSRect?
    private(set) var isZoomedToScreen = false

    init(model: PlaybackModel, preferences: Preferences, menu: NSMenu) {
        let state = StageWindowState()
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: true
        )
        level = .normal
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        minSize = Self.minWindowSize
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false

        let rootView = StageWindowView(
            model: model,
            preferences: preferences,
            windowState: state,
            onToggleZoom: { [weak self] in self?.toggleScreenZoom() },
            onClose: { [preferences] in preferences.showsStageWindow = false }
        )
        let host = StageHostingView(rootView: rootView)
        host.sizingOptions = []
        host.menu = menu
        contentView = host

        if !setFrameUsingName(Self.frameAutosave), let screen = NSScreen.main?.visibleFrame {
            let origin = NSPoint(
                x: round(screen.midX - Self.defaultSize.width / 2),
                y: round(screen.midY - Self.defaultSize.height / 2)
            )
            setFrameOrigin(origin)
        }
        setFrameAutosaveName(Self.frameAutosave)

        Task { [weak self] in
            for await isVisible in Observations({ preferences.showsStageWindow }) {
                guard let self else { return }
                if !isVisible { state.isHovered = false }
                self.contentView?.isHidden = !isVisible
                if isVisible {
                    self.orderFrontRegardless()
                } else {
                    self.orderOut(nil)
                }
            }
        }
    }

    override var canBecomeKey: Bool { true }

    func toggleScreenZoom() {
        guard let screen = (self.screen ?? NSScreen.main)?.visibleFrame else { return }
        if isZoomedToScreen, let restore = savedWindowedFrame {
            isZoomedToScreen = false
            setFrame(restore, display: true, animate: true)
        } else {
            savedWindowedFrame = frame
            isZoomedToScreen = true
            setFrame(screen, display: true, animate: true)
        }
    }
}

@Observable
final class StageWindowState {
    var isHovered = false
    @ObservationIgnored private var cachedPalette: StagePalette = .fallback
    @ObservationIgnored private var lastArtworkID: ObjectIdentifier?

    func palette(for artwork: NSImage?) -> StagePalette {
        let id = artwork.map(ObjectIdentifier.init)
        if id != lastArtworkID {
            lastArtworkID = id
            cachedPalette = StagePalette.extract(from: artwork)
        }
        return cachedPalette
    }
}

private final class StageHostingView<Content: View>: NSHostingView<Content> {
    private var mouseDownPoint: NSPoint?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
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

private struct StageWindowView: View {
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
        return LyricLine(time: 0, text: "SoftLive 舞台模式")
    }

    private var nextLineTime: TimeInterval? {
        guard let lyrics = model.lyrics,
              let nextIdx = lyrics.nextSungIndex(after: model.currentIndex)
        else { return nil }
        return lyrics.lines[nextIdx].time
    }

    var body: some View {
        let isVisible = preferences.showsStageWindow
        let palette = windowState.palette(for: activeArtwork)
        let showHUD = windowState.isHovered || model.playback == nil

        ZStack {
            if isVisible {
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
                    artwork: activeArtwork
                )

                VStack(spacing: 0) {
                    topBar(palette: palette)
                        .opacity(showHUD ? 1 : 0)
                        .allowsHitTesting(showHUD)

                    Spacer(minLength: 0)

                    bottomBar(palette: palette)
                        .opacity(showHUD ? 1 : 0)
                        .allowsHitTesting(showHUD)
                }
                .padding(18)
            } else {
                Color.clear
            }
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

    // MARK: - Top Style & Window HUD

    private func topBar(palette: StagePalette) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                hudCircleButton(icon: "xmark", help: "关闭演示舞台", action: onClose)
                hudCircleButton(icon: "arrow.up.left.and.arrow.down.right", help: "切换最大化舞台", action: onToggleZoom)

                Text(preferences.stageStyle.subtitle)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
                    .padding(.leading, 4)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.black.opacity(0.46), in: .capsule)
            .overlay {
                Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                ForEach(StageStyle.allCases, id: \.self) { style in
                    let isSelected = preferences.stageStyle == style
                    Text(style.displayName)
                        .font(.system(size: 12.5, weight: isSelected ? .bold : .medium))
                        .foregroundStyle(isSelected ? .black : .white.opacity(0.82))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(
                            isSelected ? Color(nsColor: palette.accent) : Color.white.opacity(0.08),
                            in: .capsule
                        )
                        .contentShape(.capsule)
                        .onTapGesture {
                            preferences.stageStyle = style
                        }
                }

                Divider()
                    .frame(height: 14)
                    .overlay(.white.opacity(0.2))
                    .padding(.horizontal, 2)

                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .bold))
                    Text("星火")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(preferences.stageSparks ? Color(nsColor: palette.accent) : .white.opacity(0.55))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    preferences.stageSparks ? Color.white.opacity(0.16) : Color.white.opacity(0.06),
                    in: .capsule
                )
                .contentShape(.capsule)
                .onTapGesture {
                    preferences.stageSparks.toggle()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.black.opacity(0.46), in: .capsule)
            .overlay {
                Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
            }
        }
    }

    // MARK: - Bottom Transport HUD

    private func bottomBar(palette: StagePalette) -> some View {
        let track = model.playback?.track ?? model.recentTracks[preferences.preferredPlayer]
        return HStack(spacing: 14) {
            Group {
                if let art = activeArtwork {
                    Image(nsImage: art)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle()
                        .fill(.white.opacity(0.12))
                        .overlay {
                            Image(systemName: "music.note")
                                .foregroundStyle(.white.opacity(0.6))
                        }
                }
            }
            .frame(width: 42, height: 42)
            .clipShape(.rect(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 2) {
                Text(track?.title ?? "未在播放")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(track?.artist.isEmpty == false ? track!.artist : preferences.preferredPlayer.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
            }
            .frame(maxWidth: 260, alignment: .leading)

            Spacer(minLength: 0)

            HStack(spacing: 12) {
                hudCircleButton(
                    icon: model.isPlaying ? "pause.fill" : "play.fill",
                    size: 34,
                    help: model.isPlaying ? "暂停" : "播放"
                ) {
                    if model.playback != nil {
                        model.togglePlayPause()
                    } else {
                        model.play(preferences.preferredPlayer)
                    }
                }

                hudCircleButton(
                    icon: "forward.fill",
                    size: 30,
                    help: "下一首",
                    action: model.nextTrack
                )
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                ForEach(PlayerKind.allCases, id: \.self) { kind in
                    let isSelected = (model.playback?.track.source ?? preferences.preferredPlayer) == kind
                    Text(kind.displayName)
                        .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? .white : .white.opacity(0.5))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(isSelected ? .white.opacity(0.18) : .clear, in: .capsule)
                        .contentShape(.capsule)
                        .onTapGesture {
                            preferences.preferredPlayer = kind
                            if model.playback == nil {
                                model.play(kind)
                            }
                        }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.black.opacity(0.48), in: .rect(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
        }
    }

    private func hudCircleButton(icon: String, size: CGFloat = 28, help: String, action: @escaping () -> Void) -> some View {
        Image(systemName: icon)
            .font(.system(size: size * 0.40, weight: .bold))
            .foregroundStyle(.white.opacity(0.92))
            .frame(width: size, height: size)
            .background(.white.opacity(0.14), in: .circle)
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
            artwork: artwork
        )
    }
}
