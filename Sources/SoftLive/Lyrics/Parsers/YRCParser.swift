import Foundation

/// NetEase word-synced lyrics:
///
///     [lineStartMs,lineDurationMs](wordStartMs,wordDurationMs,0)word(wordStartMs,wordDurationMs,0)word…
///
/// Lines in JSON form (`{"t":…,"c":[…]}`) are credits and are skipped, as are lines without words.
enum YRCParser {
    static func lines(_ yrc: String) -> [LyricLine] {
        yrc.split(whereSeparator: \.isNewline).compactMap { line(String($0)) }
    }

    private static func line(_ raw: String) -> LyricLine? {
        guard let header = raw.firstMatch(of: /^\[(\d+),\d+\]/),
              let start = Double(header.1)
        else { return nil }

        // A timing tag and the word up to the next tag (words may contain parentheses themselves).
        let wordPattern = /\((\d+),(\d+),\d+\)((?:(?!\(\d+,\d+,\d+\)).)*)/
        let words = raw[header.range.upperBound...].matches(of: wordPattern).compactMap { match -> LyricWord? in
            guard let start = Double(match.1), let duration = Double(match.2), !match.3.isEmpty else { return nil }
            return LyricWord(start: start / 1000, duration: duration / 1000, text: String(match.3))
        }
        guard !words.isEmpty else { return nil }
        let text = words.map(\.text).joined().trimmingCharacters(in: .whitespaces)
        return LyricLine(time: start / 1000, text: text, words: words)
    }
}
