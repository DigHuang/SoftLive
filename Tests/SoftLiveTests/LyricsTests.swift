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
        #expect(lyrics.lines.map(\.translation) == [nil, "你好"])
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
        #expect(lines[0].text == "Hello (big) world")
        let words = try #require(lines[0].words)
        #expect(words.map(\.text) == ["Hello ", "(big) ", "world"])
        #expect(words.map(\.start) == [1, 1.5, 2.2])
        #expect(words.map(\.duration) == [0.5, 0.7, 0.8])
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
