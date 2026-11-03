import AppKit
import Testing
@testable import SoftLive

struct KaraokeLayerViewTests {
    @Test func splitAdvancesAcrossWordsAndHoldsAcrossGaps() {
        let words = [
            LyricWord(start: 10, duration: 1, text: "我的"),
            LyricWord(start: 12, duration: 1, text: "世界"),
        ]
        let view = KaraokeLayerView(frame: NSRect(x: 0, y: 0, width: 300, height: 32))
        view.configure(
            line: LyricLine(time: 10, text: "我的世界", words: words),
            playback: nil,
            offset: 0,
            fontSize: 20,
            weight: .bold,
            color: .white,
            centered: false,
            hasShadow: false
        )
        let before = view.splitX(at: 9.5, words: words)
        let midFirst = view.splitX(at: 10.5, words: words)
        let gapStart = view.splitX(at: 11.0, words: words)
        let gapEnd = view.splitX(at: 11.9, words: words)
        let midSecond = view.splitX(at: 12.5, words: words)
        let after = view.splitX(at: 13.0, words: words)

        #expect(before < midFirst)
        #expect(midFirst < gapStart)
        #expect(gapStart == gapEnd)
        #expect(gapEnd < midSecond)
        #expect(midSecond < after)
        #expect(after == 300)
    }

    @Test func leadingSpaceWordDoesNotShiftSubsequentWordRanges() throws {
        let line = try #require(YRCParser.lines("[1000,2000](1000,200,0) (1200,800,0)我的(2000,1000,0)世界").first)
        let words = try #require(line.words)
        let view = KaraokeLayerView(frame: NSRect(x: 0, y: 0, width: 300, height: 32))
        view.configure(
            line: line,
            playback: nil,
            offset: 0,
            fontSize: 20,
            weight: .bold,
            color: .white,
            centered: false,
            hasShadow: false
        )
        let afterLeadingSpace = view.splitX(at: 1.2, words: words)
        let afterFirstWord = view.splitX(at: 2.0, words: words)
        let midLastWord = view.splitX(at: 2.5, words: words)

        #expect(afterLeadingSpace < afterFirstWord)
        #expect(afterFirstWord < midLastWord)
    }

    @Test func defersRenderingWhileHiddenAndSyncsOnUnhide() {
        let words = [
            LyricWord(start: 10, duration: 1, text: "我的"),
            LyricWord(start: 12, duration: 1, text: "世界"),
        ]
        let view = KaraokeLayerView(frame: NSRect(x: 0, y: 0, width: 300, height: 32))
        view.isHidden = true
        view.configure(
            line: LyricLine(time: 10, text: "我的世界", words: words),
            playback: nil,
            offset: 0,
            fontSize: 20,
            weight: .bold,
            color: .white,
            centered: false,
            hasShadow: false
        )
        // While hidden, no word ranges are rasterized.
        #expect(view.splitX(at: 10.5, words: words) == 300)

        view.isHidden = false
        #expect(view.splitX(at: 10.5, words: words) < view.splitX(at: 12.5, words: words))
    }
}
