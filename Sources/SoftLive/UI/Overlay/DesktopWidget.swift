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
    static let compactHeight: CGFloat = 92
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
            let hasArtwork = activeImage != nil
            let palette = StagePalette.cached(for: activeImage)
            let accent = hasArtwork ? Color(nsColor: palette.accent) : SoftLiveTheme.accent

            VStack(alignment: .leading, spacing: 0) {
                header(
                    playback: playback,
                    selected: selected,
                    recent: recent,
                    artwork: activeImage,
                    hasArtwork: hasArtwork,
                    accent: accent
                )
                .frame(height: isExpanded ? 56 : 60)

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
        hasArtwork: Bool,
        accent: Color
    ) -> some View {
        let tintColor = hasArtwork ? accent : SoftLiveTheme.accent

        return HStack(spacing: 12) {
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
                        accentTint: tintColor,
                        opticalOffsetX: model.isPlaying ? 0 : 1,
                        help: model.isPlaying ? L10n.tr("暂停", "Pause") : L10n.tr("继续播放", "Play"),
                        action: model.togglePlayPause
                    )
                    circleButton(
                        icon: "stop.fill",
                        help: L10n.tr("停止并退出播放器", "Stop & Quit Player"),
                        action: model.closePlayback
                    )
                }
            } else {
                HStack(spacing: 10) {
                    sourceSelector(selected: selected)
                    circleButton(
                        icon: "play.fill",
                        diameter: 32,
                        iconSize: 13,
                        isProminent: true,
                        accentTint: tintColor,
                        opticalOffsetX: 1,
                        help: L10n.tr("启动 \(selected.displayName) 并播放", "Launch \(selected.displayName) and play")
                    ) {
                        model.play(selected)
                    }
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
        diameter: CGFloat = 28,
        iconSize: CGFloat = 11,
        isProminent: Bool = false,
        accentTint: Color? = nil,
        opticalOffsetX: CGFloat = 0,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        let isDark = colorScheme == .dark
        let tintFillAlpha = diameter > 28 ? (isDark ? 0.20 : 0.16) : (isDark ? 0.16 : 0.12)
        let tintBorderAlpha = diameter > 28 ? (isDark ? 0.36 : 0.30) : (isDark ? 0.30 : 0.24)
        return Image(systemName: icon)
            .font(.system(size: iconSize, weight: .medium))
            .foregroundStyle(.primary)
            .offset(x: opticalOffsetX)
            .frame(width: diameter, height: diameter)
            .background {
                Circle()
                    .fill(isProminent ? prominentControlFill : controlFill)
                    .overlay {
                        if let accentTint {
                            Circle().fill(accentTint.opacity(tintFillAlpha))
                        }
                    }
            }
            .overlay {
                Circle().strokeBorder(
                    accentTint.map { $0.opacity(tintBorderAlpha) } ?? controlBorder,
                    lineWidth: 0.5
                )
            }
            .contentShape(.circle)
            .help(help)
            .onTapGesture(perform: action)
    }

    private func sourceSelector(selected: PlayerKind) -> some View {
        let isDark = colorScheme == .dark
        return HStack(spacing: 5) {
            ForEach(PlayerKind.allCases, id: \.self) { kind in
                let isSelected = selected == kind
                let shape = RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                PlayerIcon(kind: kind)
                    .frame(width: 20, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .saturation(isSelected ? 0.78 : 0.12)
                    .opacity(isSelected ? 1.0 : (isDark ? 0.45 : 0.48))
                    .frame(width: 24, height: 24)
                    .background(
                        isSelected ? controlFill : controlFill.opacity(0.45),
                        in: shape
                    )
                    .overlay {
                        shape.strokeBorder(
                            isSelected
                                ? SoftLiveTheme.accent.opacity(isDark ? 0.55 : 0.42)
                                : controlBorder.opacity(0.65),
                            lineWidth: 0.5
                        )
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
            Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
        } else {
            Rectangle().fill(.quaternary).overlay {
                Image(systemName: "music.note")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
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
    private static let barWidth: CGFloat = 100

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
