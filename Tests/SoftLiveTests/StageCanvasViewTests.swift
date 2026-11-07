import AppKit
import QuartzCore
import Testing
@testable import SoftLive

struct StageCanvasViewTests {
    @Test func preservesSourceWordTimingAndMinimumDurations() {
        let line = LyricLine(time: 10, text: "我的天", words: [
            LyricWord(start: 10, duration: 0.6, text: "我的"),
            LyricWord(start: 11, duration: 0.01, text: "天"),
        ])

        let sourceWords = StageWordTimeline.effectiveWords(for: line, nextLineTime: 20)
        #expect(sourceWords.count == 2)
        #expect(sourceWords[0].text == "我的")
        #expect(sourceWords[0].start == 10)
        #expect(abs(sourceWords[0].end - 10.6) < 0.000_001)
        #expect(sourceWords[1].start == 11)
        #expect(abs(sourceWords[1].end - 11.12) < 0.000_001)

        let characters = StageWordTimeline.effectiveWords(for: line, nextLineTime: 20, perCharacter: true)
        #expect(characters.map(\.text) == ["我", "的", "天"])
        #expect(characters[0].start == 10)
        #expect(abs(characters[0].end - 10.3) < 0.000_001)
        #expect(abs(characters[1].start - 10.3) < 0.000_001)
        #expect(abs(characters[1].end - 10.6) < 0.000_001)
        #expect(characters[2] == sourceWords[1])
    }

    @Test func keepsMinimumCharacterDurationWhenSplittingShortSourceWords() {
        let line = LyricLine(time: 10, text: "我的天", words: [
            LyricWord(start: 10, duration: 0.12, text: "我的天"),
        ])
        let words = StageWordTimeline.effectiveWords(for: line, nextLineTime: nil, perCharacter: true)

        #expect(words.count == 3)
        #expect(abs(words[1].start - 10.04) < 0.000_001)
        #expect(abs(words[2].start - 10.08) < 0.000_001)
        #expect(abs(words[2].end - 10.18) < 0.000_001)
        #expect(words[0].end > words[1].start)
    }

    @Test func boundsFallbackTimingAndRetainsMixedTextTokens() throws {
        let line = LyricLine(time: 10, text: "晴天")
        let longGap = StageWordTimeline.effectiveWords(for: line, nextLineTime: 30)
        let shortGap = StageWordTimeline.effectiveWords(for: line, nextLineTime: 11)
        let noNextLine = StageWordTimeline.effectiveWords(for: line, nextLineTime: nil)
        let precedingLine = StageWordTimeline.effectiveWords(for: line, nextLineTime: 9)

        #expect(longGap.map(\.text) == ["晴", "天"])
        #expect(try #require(longGap.last).end == 14.5)
        #expect(abs(try #require(shortGap.last).end - 11.6) < 0.000_001)
        #expect(abs(try #require(noNextLine.last).end - 13.2) < 0.000_001)
        #expect(precedingLine == noNextLine)
        #expect(StageWordTimeline.segmentText("Hello 晴天 world") == ["Hello ", "晴", "天", "world"])
        #expect(StageWordTimeline.segmentText("   ").isEmpty)
    }

    @Test func poseTimelineUsesCurrentPoseWhenPausedAndFinalModelWhenPlaying() throws {
        let word = StageWordTimeline.WordUnit(text: "光", start: 10, end: 11)
        let wordLayer = CALayer()
        let glowLayer = CALayer()
        let stateAt: (TimeInterval) -> StageWordAnimation.Pose = { time in
            StageWordAnimation.Pose(
                pos: CGPoint(x: time, y: 20),
                scaleX: 1,
                scaleY: 1,
                rotZ: 0,
                rotX: 0,
                rotY: 0,
                opacity: Float((time - 10) / 2),
                glow: Float((time - 10) / 4)
            )
        }

        StageWordAnimation.applyWordPoseTimeline(
            wordLayer: wordLayer,
            glowLayer: glowLayer,
            word: word,
            nowTime: 10,
            remaining: 2,
            isPlaying: false,
            stateAt: stateAt
        )
        #expect(wordLayer.position == CGPoint(x: 10, y: 20))
        #expect(wordLayer.opacity == 0)
        #expect(glowLayer.opacity == 0)
        #expect(wordLayer.animation(forKey: StageWordAnimation.key) == nil)

        StageWordAnimation.applyWordPoseTimeline(
            wordLayer: wordLayer,
            glowLayer: glowLayer,
            word: word,
            nowTime: 10,
            remaining: 2,
            isPlaying: true,
            stateAt: stateAt
        )
        #expect(wordLayer.position == CGPoint(x: 12, y: 20))
        #expect(wordLayer.opacity == 1)
        #expect(glowLayer.opacity == 0.5)
        let group = try #require(wordLayer.animation(forKey: StageWordAnimation.key) as? CAAnimationGroup)
        let position = try #require(group.animations?.first as? CAKeyframeAnimation)
        #expect(group.duration == 2)
        #expect(position.keyTimes?.first == NSNumber(value: 0))
        #expect(position.keyTimes?.last == NSNumber(value: 1))
        #expect((position.values?.first as? NSValue)?.pointValue == CGPoint(x: 10, y: 20))
        #expect((position.values?.last as? NSValue)?.pointValue == CGPoint(x: 12, y: 20))
        #expect(glowLayer.animation(forKey: StageWordAnimation.key) != nil)
    }

    @Test func extractsPaletteFromArtworkAndCachesByIdentity() {
        #expect(StagePalette.cached(for: nil) == .fallback)

        let image = NSImage(size: NSSize(width: 24, height: 24))
        image.lockFocus()
        NSColor(deviceRed: 0.92, green: 0.28, blue: 0.42, alpha: 1).setFill()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: 24, height: 24))
        image.unlockFocus()

        let palette = StagePalette.extract(from: image)
        #expect(palette != StagePalette.fallback)

        let state = StageWindowState()
        let first = state.palette(for: image)
        let second = StagePalette.cached(for: image)
        #expect(first == palette)
        #expect(first == second)
    }

    @Test func segmentsMixedTextAndExtractsGlyphPathsAcrossAllStyles() {
        let segmented = StageWordTimeline.segmentText("Hello 晴天 world")
        #expect(segmented == ["Hello ", "晴", "天", "world"])

        let font = NSFont.systemFont(ofSize: 40, weight: .bold)
        let path = StageTextRenderer.glyphPath(for: "流光", font: font, in: CGSize(width: 160, height: 64))
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
