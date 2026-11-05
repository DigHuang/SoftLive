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

private struct DesktopWidgetView: View {
    static let cardWidth: CGFloat = 360
    static let expandedHeight: CGFloat = 146
    static let compactHeight: CGFloat = 88
    static let innerPadding: CGFloat = 16
    /// Room around the card for the glass rim and shadow.
    static let margin: CGFloat = 14
    static let expandedPanelHeight = expandedHeight + 2 * margin
    static let compactPanelHeight = compactHeight + 2 * margin
    static let panelSize = NSSize(width: cardWidth + 2 * margin, height: expandedPanelHeight)

    let model: PlaybackModel
    let preferences: Preferences

    var body: some View {
        if !preferences.showsDesktopWidget {
            Color.clear.frame(width: 0, height: 0)
        } else {
            let playback = model.playback
            let isExpanded = playback != nil
            let selected = preferences.preferredPlayer
            let recent = model.recentTracks[selected]

            VStack(alignment: .leading, spacing: 0) {
                header(playback: playback, selected: selected, recent: recent)
                    .frame(height: 56)

                if playback != nil {
                    lyrics
                        .frame(maxWidth: .infinity, minHeight: 48, maxHeight: 48, alignment: .leading)
                        .padding(.top, 10)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .padding(Self.innerPadding)
            .frame(width: Self.cardWidth, height: isExpanded ? Self.expandedHeight : Self.compactHeight, alignment: .top)
            .clipped()
            .background {
                Color.clear
                    .glassEffect(.regular, in: .rect(cornerRadius: 24))
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

    // MARK: Header

    private func header(playback: PlaybackState?, selected: PlayerKind, recent: Track?) -> some View {
        HStack(spacing: 12) {
            Artwork(image: playback != nil ? model.artwork : model.recentArtworks[selected])
                .frame(width: 52, height: 52)
                .clipShape(.rect(cornerRadius: 11))
                .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: playback != nil ? 2 : 4) {
                Text(playback?.track.title ?? recent?.title ?? "未在播放")
                    .font(playback != nil ? .subheadline.weight(.semibold) : .headline)
                Text(subtitle(playback: playback, selected: selected, recent: recent))
                    .font(playback != nil ? .caption : .subheadline)
                    .foregroundStyle(.secondary)
                if playback != nil {
                    PlaybackProgress(model: model, isActive: preferences.showsDesktopWidget)
                        .padding(.top, 2)
                        .transition(.opacity)
                }
            }
            .lineLimit(1)
            .allowsHitTesting(false)

            Spacer(minLength: 0)

            if playback != nil {
                HStack(spacing: 8) {
                    circleButton(
                        icon: model.isPlaying ? "pause.fill" : "play.fill",
                        help: model.isPlaying ? "暂停" : "继续播放",
                        action: model.togglePlayPause
                    )
                    circleButton(
                        icon: "xmark",
                        help: "关闭",
                        action: model.closePlayback
                    )
                }
            } else {
                VStack(alignment: .trailing, spacing: 8) {
                    Button {
                        model.play(selected)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 10, weight: .bold))
                            Text("播放")
                                .font(.caption.weight(.semibold))
                        }
                        .padding(.horizontal, 13)
                        .padding(.vertical, 6)
                        .background(.white.opacity(0.2), in: .capsule)
                        .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)

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

    private func circleButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 28, height: 28)
                .background(.white.opacity(0.2), in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func playerIconBar(selected: PlayerKind) -> some View {
        HStack(spacing: 6) {
            ForEach(PlayerKind.allCases, id: \.self) { kind in
                let isSelected = selected == kind
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        preferences.preferredPlayer = kind
                    }
                } label: {
                    PlayerIcon(kind: kind)
                        .frame(width: 24, height: 24)
                        .opacity(isSelected ? 1.0 : 0.35)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(kind.displayName)
            }
        }
    }

    @ViewBuilder
    private var lyrics: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let line = model.currentLine, !line.text.isEmpty {
                KaraokeText(line: line, model: model, fontSize: 19, weight: .bold)
                if let sub = line.translation ?? model.line(1)?.text, !sub.isEmpty {
                    Text(sub).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            } else if let sub = model.subline, !sub.isEmpty {
                Text(sub).font(.subheadline.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
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
                Image(systemName: "music.note").foregroundStyle(.secondary)
            }
        }
    }
}

private struct PlaybackProgress: View {
    private static let barWidth: CGFloat = 68

    let model: PlaybackModel
    let isActive: Bool

    var body: some View {
        let duration = model.playback?.track.duration ?? 0
        let remaining = max(0, duration - (model.playback?.position() ?? 0))
        TimelineView(ProgressSchedule(until: isActive && model.isPlaying && duration > 0 ? .now + remaining : .now)) { context in
            let position = min(model.playback?.position(at: context.date) ?? 0, duration)
            let fraction = duration > 0 ? min(max(position / duration, 0), 1) : 0
            HStack(spacing: 6) {
                Capsule()
                    .fill(.quaternary)
                    .frame(width: Self.barWidth, height: 3)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(.secondary)
                            .frame(width: Self.barWidth * fraction, height: 3)
                    }
                Text("\(Self.format(position)) / \(Self.format(duration))")
                    .font(.caption2.monospacedDigit())
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
