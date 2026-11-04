import AppKit
import SwiftUI

/// A single lyric line that fills in word by word as it is sung (when the lyrics carry word timing);
/// other lines render at full strength.
///
/// Rendering lives in `KaraokeLayerView`. It stays mounted at a fixed height across lines, so line
/// changes never rebuild or re-measure the SwiftUI tree.
struct KaraokeText: View {
    let line: LyricLine
    let model: PlaybackModel
    var fontSize: CGFloat = 19
    var weight: NSFont.Weight = .bold
    var color: NSColor = .labelColor
    var centered = false
    var hasShadow = false

    var body: some View {
        let height = KaraokeLayerView.lineHeight(for: fontSize)
        KaraokeLayerRepresentable(
            line: line,
            playback: model.playback,
            offset: model.offset,
            fontSize: fontSize,
            weight: weight,
            color: color,
            centered: centered,
            hasShadow: hasShadow
        )
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
    }
}

private struct KaraokeLayerRepresentable: NSViewRepresentable {
    let line: LyricLine
    let playback: PlaybackState?
    let offset: TimeInterval
    let fontSize: CGFloat
    let weight: NSFont.Weight
    let color: NSColor
    let centered: Bool
    let hasShadow: Bool

    func makeNSView(context: Context) -> KaraokeLayerView {
        KaraokeLayerView()
    }

    func updateNSView(_ nsView: KaraokeLayerView, context: Context) {
        nsView.configure(
            line: line,
            playback: playback,
            offset: offset,
            fontSize: fontSize,
            weight: weight,
            color: color,
            centered: centered,
            hasShadow: hasShadow
        )
    }
}
