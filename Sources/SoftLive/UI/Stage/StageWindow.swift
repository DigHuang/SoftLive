import AppKit
import Observation
import SwiftUI

/// Standalone showcase stage window ("演示舞台模式"):
/// fluid album-tinted aurora backdrop, two hardware-accelerated kinetic typography styles
/// (`流光`, `描金`), radial spark bursts, vinyl interlude centerpiece,
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

    func palette(for artwork: NSImage?) -> StagePalette {
        StagePalette.cached(for: artwork)
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
            // Top-left: clean standalone window action circles without double-nested capsule borders or verbose text.
            HStack(spacing: 8) {
                hudCircleButton(icon: "xmark", help: L10n.tr("关闭演示舞台", "Close Stage Window"), action: onClose)
                hudCircleButton(
                    icon: "arrow.up.left.and.arrow.down.right",
                    help: L10n.tr("切换最大化舞台", "Toggle Maximize Stage"),
                    action: onToggleZoom
                )
            }

            Spacer(minLength: 0)

            // Top-right: uniform 4pt inset segmented capsule with monochrome frost selection.
            HStack(spacing: 2) {
                ForEach(StageStyle.allCases, id: \.self) { style in
                    let isSelected = preferences.stageStyle == style
                    Text(style.displayName)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? .white : .white.opacity(0.60))
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(.white.opacity(0.18))
                                    .overlay {
                                        Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.5)
                                    }
                            }
                        }
                        .contentShape(.capsule)
                        .help(style.subtitle)
                        .onTapGesture {
                            preferences.stageStyle = style
                        }
                }

                Rectangle()
                    .fill(.white.opacity(0.14))
                    .frame(width: 0.5, height: 14)
                    .padding(.horizontal, 4)

                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(
                            preferences.stageSparks
                                ? Color(nsColor: palette.accent)
                                : .white.opacity(0.50)
                        )
                    Text(L10n.tr("星火", "Sparks"))
                        .font(.system(size: 12, weight: preferences.stageSparks ? .semibold : .medium))
                        .foregroundStyle(preferences.stageSparks ? .white : .white.opacity(0.55))
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background {
                    if preferences.stageSparks {
                        Capsule()
                            .fill(.white.opacity(0.14))
                            .overlay {
                                Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
                            }
                    }
                }
                .contentShape(.capsule)
                .help(L10n.tr("切换星火粒子特效", "Toggle Spark Particles"))
                .onTapGesture {
                    preferences.stageSparks.toggle()
                }
            }
            .padding(4)
            .background { hudSurface(in: Capsule()) }
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
                .clipShape(.rect(cornerRadius: 9))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
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

    private func hudSurface<S: InsettableShape>(in shape: S) -> some View {
        shape
            .fill(Color(red: 0.06, green: 0.07, blue: 0.10).opacity(0.68))
            .overlay {
                shape.strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
    }

    private func hudCircleButton(
        icon: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Image(systemName: icon)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.white.opacity(0.88))
            .frame(width: 32, height: 32)
            .background { hudSurface(in: Circle()) }
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
