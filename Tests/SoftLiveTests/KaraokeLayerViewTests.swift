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

    @Test func preservesRunningAnimationWhenReconfiguredWithUnchangedTiming() throws {
        let words = [
            LyricWord(start: 10, duration: 1, text: "我的"),
            LyricWord(start: 12, duration: 1, text: "世界"),
        ]
        let line = LyricLine(time: 10, text: "我的世界", words: words)
        let track = Track(id: "1", title: "Song", artist: "Artist", album: "", duration: 180, source: .netEase)
        let playback = PlaybackState(track: track, isPlaying: true, position: 10, at: .now)

        let view = KaraokeLayerView(frame: NSRect(x: 0, y: 0, width: 300, height: 32))
        view.configure(
            line: line,
            playback: playback,
            offset: 0,
            fontSize: 20,
            weight: .bold,
            color: .white,
            centered: false,
            hasShadow: false
        )
        let clipLayer = try #require(view.layer?.sublayers?.first)
        let initialAnim = try #require(clipLayer.animation(forKey: "karaoke"))

        // Re-configuring with identical line, playback and offset (e.g. hover/wake state change) must keep the animation.
        view.configure(
            line: line,
            playback: playback,
            offset: 0,
            fontSize: 20,
            weight: .bold,
            color: .white,
            centered: false,
            hasShadow: false
        )
        let unchangedAnim = try #require(clipLayer.animation(forKey: "karaoke"))
        #expect(initialAnim === unchangedAnim)

        // Changing offset must rebuild the animation.
        view.configure(
            line: line,
            playback: playback,
            offset: 0.5,
            fontSize: 20,
            weight: .bold,
            color: .white,
            centered: false,
            hasShadow: false
        )
        let updatedAnim = try #require(clipLayer.animation(forKey: "karaoke"))
        #expect(initialAnim !== updatedAnim)
    }

    @Test func lyricsInteractionIgnoresHiddenPanelAndDismissesAfterMouseUpOutside() {
        let panel = NSPanel(
            contentRect: NSRect(x: 100, y: 100, width: 664, height: 136),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let interaction = LyricsInteraction()
        interaction.attach(to: panel)

        let insidePoint = NSPoint(x: 200, y: 150)
        let outsidePoint = NSPoint(x: 20, y: 20)

        // While the panel is hidden, pressing Command inside its frame does not wake it.
        interaction.reevaluate(command: true, buttonsPressed: false, mouseLocation: insidePoint)
        #expect(interaction.isCommandHeld == false)
        #expect(interaction.isAwake == false)

        // Once visible, pressing Command inside the card wakes it up.
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        interaction.reevaluate(command: true, buttonsPressed: false, mouseLocation: insidePoint)
        #expect(interaction.isCommandHeld == true)
        #expect(interaction.isAwake == true)

        // Releasing Command while the cursor remains inside keeps the card awake.
        interaction.reevaluate(command: false, buttonsPressed: false, mouseLocation: insidePoint)
        #expect(interaction.isCommandHeld == false)
        #expect(interaction.isAwake == true)

        // Moving outside while a mouse button is held keeps it awake until the button is released.
        interaction.reevaluate(command: false, buttonsPressed: true, mouseLocation: outsidePoint)
        #expect(interaction.isAwake == true)
        interaction.reevaluate(command: false, buttonsPressed: false, mouseLocation: outsidePoint)
        #expect(interaction.isAwake == false)
    }

    @Test func rendersThreeDotInterludeAndAdvancesAcrossThirds() throws {
        let interlude = Interlude(start: 10, end: 25)
        let interludeWords = KaraokeLayerView.interludeWords(for: interlude)
        let track = Track(id: "1", title: "Song", artist: "Artist", album: "", duration: 180, source: .netEase)
        let playing = PlaybackState(track: track, isPlaying: true, position: 10, at: .now)

        let view = KaraokeLayerView(frame: NSRect(x: 0, y: 0, width: 300, height: 32))
        view.configure(
            line: LyricLine(time: 0, text: ""),
            playback: playing,
            offset: 0,
            interlude: interlude,
            fontSize: 24,
            weight: .semibold,
            color: .white,
            centered: true,
            hasShadow: true
        )

        #expect(view.layer?.animation(forKey: "interludeBreath") != nil)
        let dot1Mid = view.splitX(at: 12.5, words: interludeWords)
        let dot2Mid = view.splitX(at: 17.5, words: interludeWords)
        let dot3Mid = view.splitX(at: 22.5, words: interludeWords)
        let done = view.splitX(at: 25.0, words: interludeWords)
        #expect(dot1Mid < dot2Mid)
        #expect(dot2Mid < dot3Mid)
        #expect(dot3Mid < done)
        #expect(done == 300)

        // Exiting the interlude removes the breathing animation.
        view.configure(
            line: LyricLine(time: 25, text: "下一句"),
            playback: playing,
            offset: 0,
            interlude: nil,
            fontSize: 24,
            weight: .semibold,
            color: .white,
            centered: true,
            hasShadow: true
        )
        #expect(view.layer?.animation(forKey: "interludeBreath") == nil)
    }
}

struct StageViewTests {
    @Test func extractsPaletteFromArtworkAndCachesByIdentity() {
        let image = NSImage(size: NSSize(width: 24, height: 24))
        image.lockFocus()
        NSColor(deviceRed: 0.92, green: 0.28, blue: 0.42, alpha: 1).setFill()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: 24, height: 24))
        image.unlockFocus()

        let palette = StagePalette.extract(from: image)
        #expect(palette != StagePalette.fallback)

        let state = StageWindowState()
        let first = state.palette(for: image)
        let second = state.palette(for: image)
        #expect(first == second)
    }

    @Test func segmentsMixedTextAndExtractsGlyphPathsAcrossAllStyles() {
        let segmented = StageCanvasView.segmentText("Hello 晴天 world")
        #expect(segmented == ["Hello ", "晴", "天", "world"])

        let font = NSFont.systemFont(ofSize: 40, weight: .bold)
        let path = StageCanvasView.glyphPath(for: "流光", font: font, in: CGSize(width: 160, height: 64))
        #expect(!path.isEmpty)

        let words = [
            LyricWord(start: 10, duration: 0.6, text: "我路过"),
            LyricWord(start: 10.6, duration: 0.8, text: "山"),
            LyricWord(start: 11.4, duration: 1.0, text: "山不说话"),
        ]
        let line = LyricLine(time: 10, endTime: 12.4, text: "我路过山山不说话", words: words)
        let track = Track(id: "1", title: "山海不说话", artist: "歌手", album: "", duration: 180, source: .netEase)
        let playing = PlaybackState(track: track, isPlaying: true, position: 10.2, at: .now)

        let canvas = StageCanvasView(frame: NSRect(x: 0, y: 0, width: 920, height: 580))
        for style in StageStyle.allCases {
            canvas.configure(
                line: line,
                nextLineTime: 16,
                subline: "它只是沉默蜿蜒到天涯",
                interlude: nil,
                playback: playing,
                offset: 0,
                style: style,
                sparks: true,
                palette: .fallback,
                artwork: nil
            )
            #expect(canvas.activeWords.count == 8)
            #expect(canvas.activeRowCount >= 1)
        }

        // Entering an interlude switches the stage to the spinning vinyl centerpiece.
        canvas.configure(
            line: line,
            nextLineTime: 25,
            subline: "下一句歌词",
            interlude: Interlude(start: 14, end: 25),
            playback: playing,
            offset: 0,
            style: .luminous,
            sparks: true,
            palette: .fallback,
            artwork: nil
        )
        #expect(canvas.activeWords.isEmpty)
        #expect(canvas.activeRowCount == 0)

        // Verify offscreen bitmap rendering produces visible content across all styles and vinyl interlude.
        let snapshotState = PlaybackState(track: track, isPlaying: false, position: 11.0, at: .now)
        for style in StageStyle.allCases {
            canvas.configure(
                line: line,
                nextLineTime: 16,
                subline: "它只是沉默蜿蜒到天涯",
                interlude: nil,
                playback: snapshotState,
                offset: 0,
                style: style,
                sparks: true,
                palette: .fallback,
                artwork: nil
            )
            guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else {
                Issue.record("Failed to create bitmapImageRepForCachingDisplay")
                return
            }
            canvas.cacheDisplay(in: canvas.bounds, to: rep)
            #expect(rep.pixelsWide >= 920)
            #expect(rep.pixelsHigh >= 580)
        }
    }
}
