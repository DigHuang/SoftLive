import AppKit
import SwiftUI

/// A Liquid Glass card pinned to the desktop, beneath every window like a desktop widget:
/// cover, track, the current line filling in word by word, the next line and progress.
///
/// WidgetKit cannot do this: widget timelines are refreshed on the system's schedule, far too
/// rarely for lyrics. A desktop-level panel renders live instead.
enum DesktopWidget {
    static func makePanel(model: PlaybackModel, preferences: Preferences, menu: NSMenu) -> OverlayPanel {
        OverlayPanel(
            frameName: "SoftLiveDesktopWidget",
            size: DesktopWidgetView.panelSize,
            level: .desktopWidget,
            allowsKey: true,
            menu: menu,
            content: DesktopWidgetView(model: model, preferences: preferences)
        ) { screen, size in
            NSPoint(x: screen.maxX - size.width - 24, y: screen.maxY - size.height - 24)
        }
        .bind(
            { (preferences.showsDesktopWidget, false) },
            activeTopHeight: { model.playback == nil ? DesktopWidgetView.compactPanelHeight : nil }
        )
    }
}

struct DesktopWidgetView: View {
    static let cardWidth: CGFloat = 368
    static let expandedHeight: CGFloat = 154
    static let compactHeight: CGFloat = 88
    static let innerPadding: CGFloat = 16
    /// Room around the card for the glass rim and shadow.
    static let margin: CGFloat = 14
    static let expandedPanelHeight = expandedHeight + 2 * margin
    static let compactPanelHeight = compactHeight + 2 * margin
    static let panelSize = NSSize(width: cardWidth + 2 * margin, height: expandedPanelHeight)

    let model: PlaybackModel
    let preferences: Preferences

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if !preferences.showsDesktopWidget {
            Color.clear.frame(width: 0, height: 0)
        } else {
            let playback = model.playback
            let isExpanded = playback != nil
            let selected = preferences.preferredPlayer
            let recent = model.recentTracks[selected]
            let activeImage = playback != nil ? model.artwork : model.recentArtworks[selected]
            let palette = StagePalette.cached(for: activeImage)
            let accent = Color(nsColor: palette.accent)

            VStack(alignment: .leading, spacing: 0) {
                header(
                    playback: playback,
                    selected: selected,
                    recent: recent,
                    artwork: activeImage,
                    accent: accent
                )
                .frame(height: 56)

                if playback != nil {
                    Rectangle()
                        .fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06))
                        .frame(height: 0.5)
                        .padding(.top, 9)
                        .padding(.bottom, 7)
                        .allowsHitTesting(false)

                    lyrics
                        .frame(maxWidth: .infinity, minHeight: 48, maxHeight: 48, alignment: .leading)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .padding(Self.innerPadding)
            .frame(width: Self.cardWidth, height: isExpanded ? Self.expandedHeight : Self.compactHeight, alignment: .top)
            .clipped()
            .background {
                cardSurface(palette: palette, hasArtwork: activeImage != nil)
                    .contentShape(.rect(cornerRadius: 24))
                    .onTapGesture(count: 2) {
                        if playback != nil { model.nextTrack() }
                    }
            }
            .padding(Self.margin)
            .frame(width: Self.panelSize.width, height: Self.panelSize.height, alignment: .top)
            .animation(.spring(duration: 0.36, bounce: 0.08), value: isExpanded)
            .onChange(of: model.playback?.track.source) { _, source in
                if let source { preferences.preferredPlayer = source }
            }
        }
    }

    // MARK: - Artwork Aura + Frost Glass Surface

    private func cardSurface(palette: StagePalette, hasArtwork: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        let isDark = colorScheme == .dark
        let primaryGlow = Color(nsColor: palette.accent)
        let secondaryGlow = Color(nsColor: palette.orbSecondary)

        return ZStack {
            shape.fill(
                isDark
                    ? Color(red: 0.06, green: 0.08, blue: 0.13).opacity(0.46)
                    : Color.white.opacity(0.52)
            )

            if hasArtwork {
                LinearGradient(
                    colors: [
                        primaryGlow.opacity(isDark ? 0.24 : 0.16),
                        secondaryGlow.opacity(isDark ? 0.14 : 0.09),
                        .clear,
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .clipShape(shape)
            }

            Color.clear
                .glassEffect(.regular, in: .rect(cornerRadius: 24))

            shape.strokeBorder(
                isDark ? Color.white.opacity(0.15) : Color.white.opacity(0.62),
                lineWidth: 0.5
            )
        }
    }

    // MARK: - Header

    private func header(
        playback: PlaybackState?,
        selected: PlayerKind,
        recent: Track?,
        artwork: NSImage?,
        accent: Color
    ) -> some View {
        HStack(spacing: 12) {
            Artwork(image: artwork)
                .frame(width: 54, height: 54)
                .clipShape(.rect(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.primary.opacity(0.10), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.28 : 0.10), radius: 5, y: 2)
                .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: playback != nil ? 3 : 4) {
                Text(playback?.track.title ?? recent?.title ?? L10n.tr("未在播放", "Not Playing"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(subtitle(playback: playback, selected: selected, recent: recent))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                if playback != nil {
                    PlaybackProgress(
                        model: model,
                        accent: accent,
                        isActive: preferences.showsDesktopWidget
                    )
                    .padding(.top, 2)
                    .transition(.opacity)
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .allowsHitTesting(false)

            if playback != nil {
                HStack(spacing: 8) {
                    circleButton(
                        icon: model.isPlaying ? "pause.fill" : "play.fill",
                        isProminent: true,
                        help: model.isPlaying ? L10n.tr("暂停", "Pause") : L10n.tr("继续播放", "Resume"),
                        action: model.togglePlayPause
                    )
                    circleButton(
                        icon: "xmark",
                        help: L10n.tr("关闭", "Close"),
                        action: model.closePlayback
                    )
                }
            } else {
                VStack(alignment: .trailing, spacing: 6) {
                    playPillButton(selected: selected)
                    playerIconBar(selected: selected)
                }
            }
        }
    }

    private func subtitle(playback: PlaybackState?, selected: PlayerKind, recent: Track?) -> String {
        if let track = playback?.track {
            return track.artist.isEmpty ? track.source.displayName : track.artist
        }
        if let artist = recent?.artist, !artist.isEmpty { return artist }
        return selected.displayName
    }

    private var controlFill: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.14)
            : Color(red: 0.08, green: 0.12, blue: 0.20).opacity(0.08)
    }

    private var prominentControlFill: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.22)
            : Color(red: 0.08, green: 0.12, blue: 0.20).opacity(0.13)
    }

    private var controlBorder: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.16)
            : Color.black.opacity(0.08)
    }

    private func circleButton(
        icon: String,
        isProminent: Bool = false,
        isSubtle: Bool = false,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Image(systemName: icon)
            .font(.system(size: isSubtle ? 9.5 : 10.5, weight: .bold))
            .foregroundStyle(isSubtle ? .secondary : .primary)
            .frame(width: 28, height: 28)
            .background(
                isProminent ? prominentControlFill : (isSubtle ? .clear : controlFill),
                in: .circle
            )
            .overlay {
                if !isSubtle {
                    Circle().strokeBorder(controlBorder, lineWidth: 0.5)
                }
            }
            .contentShape(.circle)
            .help(help)
            .onTapGesture(perform: action)
    }

    private func playPillButton(selected: PlayerKind) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "play.fill")
                .font(.system(size: 10, weight: .bold))
            Text(L10n.tr("播放", "Play"))
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(prominentControlFill, in: .capsule)
        .overlay {
            Capsule().strokeBorder(controlBorder, lineWidth: 0.5)
        }
        .contentShape(.capsule)
        .help(L10n.tr("启动 \(selected.displayName) 并播放", "Launch \(selected.displayName) and play"))
        .onTapGesture {
            model.play(selected)
        }
    }

    private func playerIconBar(selected: PlayerKind) -> some View {
        HStack(spacing: 4) {
            ForEach(PlayerKind.allCases, id: \.self) { kind in
                let isSelected = selected == kind
                PlayerIcon(kind: kind)
                    .frame(width: 20, height: 20)
                    .frame(width: 28, height: 28)
                    .opacity(isSelected ? 1.0 : 0.42)
                    .background(
                        isSelected ? controlFill : .clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .overlay {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(controlBorder, lineWidth: 0.5)
                        }
                    }
                    .contentShape(Rectangle())
                    .help(kind.displayName)
                    .onTapGesture {
                        withAnimation(.snappy(duration: 0.2)) {
                            preferences.preferredPlayer = kind
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private var lyrics: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.interlude != nil || (model.currentLine?.text.isEmpty == false) {
                KaraokeText(
                    line: model.currentLine ?? LyricLine(time: 0, text: ""),
                    model: model,
                    fontSize: 19,
                    weight: .bold
                )
                if let sub = model.subline, !sub.isEmpty {
                    Text(sub)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else if let sub = model.subline, !sub.isEmpty {
                Text(sub)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

private struct PlayerIcon: View {
    let kind: PlayerKind

    var body: some View {
        if let icon = kind.icon {
            Image(nsImage: icon).resizable().aspectRatio(contentMode: .fill)
        } else {
            Rectangle().fill(.quaternary).overlay {
                Image(systemName: "music.note").foregroundStyle(.secondary)
            }
        }
    }
}

private struct Artwork: View {
    let image: NSImage?

    var body: some View {
        if let image {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
            Rectangle().fill(.quaternary).overlay {
                Image(nsImage: BrandAssets.syncTemplate)
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 28, height: 28)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct PlaybackProgress: View {
    private static let barWidth: CGFloat = 78

    let model: PlaybackModel
    let accent: Color
    let isActive: Bool

    var body: some View {
        let duration = model.playback?.track.duration ?? 0
        let remaining = max(0, duration - (model.playback?.position() ?? 0))
        TimelineView(ProgressSchedule(until: isActive && model.isPlaying && duration > 0 ? .now + remaining : .now)) { context in
            let position = min(model.playback?.position(at: context.date) ?? 0, duration)
            let fraction = duration > 0 ? min(max(position / duration, 0), 1) : 0
            HStack(spacing: 7) {
                Capsule()
                    .fill(.quaternary)
                    .frame(width: Self.barWidth, height: 3.5)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(accent)
                            .frame(width: max(3.5, Self.barWidth * fraction), height: 3.5)
                    }
                Text("\(Self.format(position)) / \(Self.format(duration))")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds), 0)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct ProgressSchedule: TimelineSchedule {
    let until: Date

    func entries(from start: Date, mode: TimelineScheduleMode) -> StrideThrough<Date> {
        stride(from: start, through: max(start, until), by: 1.0)
    }
}
