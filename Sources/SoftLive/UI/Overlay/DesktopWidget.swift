import AppKit
import SwiftUI

/// A Liquid Glass card pinned to the desktop, beneath every window like a desktop widget:
/// cover, track, the current line filling in word by word, the next line and progress.
///
/// WidgetKit cannot do this: widget timelines are refreshed on the system's schedule, far too
/// rarely for lyrics. A desktop-level panel renders live instead.
enum DesktopWidget {
    @MainActor
    static func makePanel(model: AppModel, preferences: Preferences, menu: NSMenu) -> OverlayPanel {
        OverlayPanel(
            frameName: "SoftLiveDesktopWidget",
            size: DesktopWidgetView.panelSize,
            level: .desktopWidget,
            menu: menu,
            content: DesktopWidgetView(model: model)
        ) { screen, size in
            NSPoint(x: screen.maxX - size.width - 24, y: screen.maxY - size.height - 24)
        }
        .bind { (preferences.showsDesktopWidget, false) }
    }
}

private struct DesktopWidgetView: View {
    static let cardSize = CGSize(width: 360, height: 196)
    static let innerPadding: CGFloat = 18
    static let contentWidth = cardSize.width - 2 * innerPadding
    /// Room around the card for the glass rim and shadow.
    static let margin: CGFloat = 14
    static let panelSize = NSSize(width: cardSize.width + 2 * margin, height: cardSize.height + 2 * margin)

    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            lyrics
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            PlaybackProgress(model: model, barWidth: Self.contentWidth)
        }
        .padding(Self.innerPadding)
        .frame(width: Self.cardSize.width, height: Self.cardSize.height)
        .background {
            Color.clear.glassEffect(.regular, in: .rect(cornerRadius: 28))
        }
        .padding(Self.margin)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Artwork(image: model.artwork)
                .frame(width: 46, height: 46)
                .clipShape(.rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(model.playback?.track.title ?? "SoftLive")
                    .font(.headline)
                Text(model.playback.map { "\($0.track.artist) · \($0.track.source.displayName)" } ?? "未在播放")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            // Static on purpose: a continuously animated symbol costs more CPU than the karaoke itself.
            Image(systemName: model.isPlaying ? "waveform" : "pause.fill")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var lyrics: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let line = model.currentLine, !line.text.isEmpty {
                KaraokeText(line: line, model: model)
                if let translation = line.translation {
                    Text(translation).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            } else if model.lyricsStatus != .loaded, let status = model.subline {
                Text(status).font(.callout).foregroundStyle(.secondary)
            }
            if let next = model.line(1), !next.text.isEmpty {
                Text(next.text).font(.callout).foregroundStyle(.tertiary).lineLimit(1)
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
    let model: AppModel
    let barWidth: CGFloat

    var body: some View {
        let duration = model.playback?.track.duration ?? 0
        let remaining = max(0, duration - (model.playback?.position() ?? 0))
        TimelineView(ProgressSchedule(until: model.isPlaying && duration > 0 ? .now + remaining : .now)) { context in
            let position = min(model.playback?.position(at: context.date) ?? 0, duration)
            let fraction = duration > 0 ? min(max(position / duration, 0), 1) : 0
            VStack(spacing: 4) {
                Capsule()
                    .fill(.quaternary)
                    .frame(width: barWidth, height: 4)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(.secondary)
                            .frame(width: barWidth * fraction, height: 4)
                    }
                HStack {
                    Text(Self.format(position))
                    Spacer()
                    Text(Self.format(duration))
                }
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
