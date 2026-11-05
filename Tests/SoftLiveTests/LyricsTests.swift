import Foundation
import Testing
@testable import SoftLive

private func parseLRC(_ lrc: String, translation: String? = nil) -> Lyrics? {
    Lyrics(lines: LRCParser.lines(lrc), translation: translation)
}

struct LRCParserTests {
    @Test func parsesTimesAndSkipsMetadata() throws {
        let lyrics = try #require(parseLRC("""
        [ti:Song]
        [ar:Artist]
        [00:01.50]first
        [01:02.345]second
        [02:03]third
        """))
        #expect(lyrics.lines.map(\.time) == [1.5, 62.345, 123])
        #expect(lyrics.lines.map(\.text) == ["first", "second", "third"])
    }

    @Test func expandsRepeatedTagsInOrder() throws {
        let lyrics = try #require(parseLRC("[00:20.00][00:05.00]chorus\n[00:10.00]verse"))
        #expect(lyrics.lines.map(\.text) == ["chorus", "verse", "chorus"])
    }

    @Test func appliesOffsetTag() throws {
        let lyrics = try #require(parseLRC("[offset:500]\n[00:10.00]line"))
        #expect(lyrics.lines.first?.time == 9.5)
    }

    @Test func mergesTranslationByTimestamp() throws {
        let lyrics = try #require(parseLRC(
            "[00:01.00]hello\n[00:02.00]world",
            translation: "[00:01.00]你好\n[00:03.00]orphan"
        ))
        #expect(lyrics.lines.map(\.translation) == ["你好", nil])
    }

    @Test func skipsEmptyInterludeLinesWhenAttachingTranslations() throws {
        let lyrics = try #require(parseLRC(
            "[00:10.00]\n[00:10.20]hello",
            translation: "[00:10.00]你好"
        ))
        #expect(lyrics.lines.map(\.text) == ["hello"])
        #expect(lyrics.lines.map(\.translation) == ["你好"])
    }

    @Test func rejectsTextWithoutTimedLines() {
        #expect(parseLRC("plain lyrics\nwithout tags") == nil)
        #expect(parseLRC("[00:01.00]") == nil)
    }

    @Test func findsLineIndex() throws {
        let lyrics = try #require(parseLRC("[00:01.00]a\n[00:02.00]b\n[00:03.00]c"))
        #expect(lyrics.lineIndex(at: 0.5) == nil)
        #expect(lyrics.lineIndex(at: 1) == 0)
        #expect(lyrics.lineIndex(at: 2.9) == 1)
        #expect(lyrics.lineIndex(at: 99) == 2)
    }
}

struct YRCParserTests {
    private let yrc = """
    {"t":0,"c":[{"tx":"作词: "},{"tx":"某人"}]}
    [1000,2000](1000,500,0)Hello (1500,700,0)(big) (2200,800,0)world
    [4000,1000](4000,1000,0)晴天
    [5000,0]
    """

    @Test func parsesWordTimingAndSkipsCredits() throws {
        let lines = YRCParser.lines(yrc)
        #expect(lines.map(\.time) == [1, 4])
        #expect(lines.map(\.endTime) == [3, 5.5])
        #expect(lines[0].text == "Hello (big) world")
        let words = try #require(lines[0].words)
        #expect(words.map(\.text) == ["Hello ", "(big) ", "world"])
        #expect(words.map(\.start) == [1, 1.5, 2.2])
        #expect(words.map(\.duration) == [0.5, 0.7, 0.8])
    }

    @Test func mergesStandaloneSpaceTokensIntoPrecedingWordAndDropsEdgeSpaces() throws {
        let raw = "[1000,2000](1000,100,0) (1100,400,0)Hello(1500,100,0) (1600,600,0)world(2200,100,0) "
        let line = try #require(YRCParser.lines(raw).first)
        let words = try #require(line.words)
        #expect(words.map(\.text) == ["Hello ", "world"])
        #expect(words.map(\.start) == [1.1, 1.6])
        #expect(words.map(\.duration) == [0.4, 0.6])
        #expect(line.text == "Hello world")
        #expect(line.text == words.map(\.text).joined())
    }

    @Test func identifiesCreditsAndComputesIntroAndMidSongInterludes() throws {
        // Mirrors real NetEase YRC (`netEase-29812789.json`) where the line header `[15000, 15000]`
        // spans all the way to the next line at 30.0s, while the last word finishes at 18.0s.
        let raw = """
        [0,1000](0,1000,0)作词 : 林夕
        [1500,1000](1500,1000,0)作曲：泽野弘之
        [3000,1000](3000,1000,0)策划 : 思潮
        [15000,15000](15000,1500,0)第一句(16500,1500,0)歌词
        [30000,2000](30000,2000,0)第二句歌词
        """
        let lyrics = try #require(Lyrics(lines: YRCParser.lines(raw)))
        #expect(lyrics.lines.map(\.isCredit) == [true, true, true, false, false])

        // While credits are showing, never enters an interlude; after the last credit at 3.0s (+ 2.5s = 5.5s), enters [5.5, 15.0].
        #expect(lyrics.interlude(at: 0.5) == nil)
        #expect(lyrics.interlude(at: 2.0) == nil)
        #expect(lyrics.interlude(at: 4.0) == nil)
        #expect(lyrics.nextEventTime(after: 4.0) == 5.5)
        #expect(lyrics.interlude(at: 5.5) == Interlude(start: 5.5, end: 15.0))
        #expect(lyrics.nextEventTime(after: 5.5) == 15.0)

        // Singing the first real line [15.0, 18.0] + 1.5s hold -> interlude starts at 19.5s (10.5s remaining >= 7.0s).
        #expect(lyrics.interlude(at: 16.0) == nil)
        #expect(lyrics.interlude(at: 18.5) == nil)
        #expect(lyrics.nextEventTime(after: 16.0) == 19.5)
        #expect(lyrics.interlude(at: 19.5) == Interlude(start: 19.5, end: 30.0))
        #expect(lyrics.nextEventTime(after: 19.5) == 30.0)
    }

    @Test func ignoresShortLRCStanzaBreaksAndOnlyEntersRealLongInterlude() throws {
        // Real pattern from `netEase-3445957923.json` (《山海不说话》): empty stanza-break tags stamped
        // 0.30s–0.74s after a slow ballad line starts must never cut off the sung line or trigger `•••`.
        let lrc = """
        [00:33.83]总去执着未免太傻
        [00:34.21]
        [00:39.80]人生有多长呢
        [00:50.56]还是自己呢
        [00:50.86]
        [00:55.36]我路过山 山不说话
        [01:13.10]却让我看见浪里的灯塔
        [01:13.84]
        [01:19.86]我路过风 风没停下
        [01:37.91]但也许我应该出发
        [01:39.06]
        [02:08.79]下一段主歌
        """
        let lyrics = try #require(parseLRC(lrc))
        // Empty stanza-break lines are discarded so `lineIndex` stays on the sung line.
        #expect(lyrics.lines.allSatisfy { !$0.text.isEmpty })
        #expect(lyrics.lines[lyrics.lineIndex(at: 35.0)!].text == "总去执着未免太傻")
        #expect(lyrics.lines[lyrics.lineIndex(at: 52.0)!].text == "还是自己呢")
        #expect(lyrics.lines[lyrics.lineIndex(at: 75.0)!].text == "却让我看见浪里的灯塔")

        // None of the 5–7s slow ballad lines enter an interlude.
        #expect(lyrics.interlude(at: 35.0) == nil)
        #expect(lyrics.interlude(at: 52.0) == nil)
        #expect(lyrics.interlude(at: 75.0) == nil)

        // During the 30.88s solo after 97.91s, the line holds for 8.0s (until 105.91s) and then enters the interlude.
        #expect(lyrics.interlude(at: 100.0) == nil)
        #expect(lyrics.nextEventTime(after: 100.0) == 105.91)
        #expect(lyrics.interlude(at: 106.0) == Interlude(start: 105.91, end: 128.79))
        #expect(lyrics.nextEventTime(after: 106.0) == 128.79)
    }

    @Test func wordProgressIsClamped() {
        let word = LyricWord(start: 10, duration: 2, text: "a")
        #expect(word.progress(at: 9) == 0)
        #expect(word.progress(at: 11) == 0.5)
        #expect(word.progress(at: 20) == 1)
    }

    @Test func attachesTranslationsToNearbyWordTimedLines() throws {
        let lyrics = try #require(Lyrics(
            lines: YRCParser.lines(yrc),
            translation: "[00:00.80]你好世界\n[00:02.50]too far from any line"
        ))
        #expect(lyrics.lines.map(\.translation) == ["你好世界", nil])
    }
}
