import Foundation

/// NetEase word-synced lyrics:
///
///     [lineStartMs,lineDurationMs](wordStartMs,wordDurationMs,0)word(wordStartMs,wordDurationMs,0)word…
///
/// Lines in JSON form (`{"t":…,"c":[…]}`) are credits and are skipped, as are lines without words.
enum YRCParser {
    private static let headerPattern = /^\[(\d+),(\d+)\]/
    // A timing tag and the word up to the next tag (words may contain parentheses themselves).
    private static let wordPattern = /\((\d+),(\d+),\d+\)((?:(?!\(\d+,\d+,\d+\)).)*)/

    static func lines(_ yrc: String) -> [LyricLine] {
        yrc.split(whereSeparator: \.isNewline).compactMap { line(String($0)) }
    }

    private static func line(_ raw: String) -> LyricLine? {
        guard let header = raw.firstMatch(of: headerPattern),
              let startMs = Double(header.1),
              let durationMs = Double(header.2)
        else { return nil }

        var words: [LyricWord] = []
        var pendingSpace = ""
        for match in raw[header.range.upperBound...].matches(of: wordPattern) {
            guard let wordStartMs = Double(match.1),
                  let wordDurationMs = Double(match.2),
                  !match.3.isEmpty
            else { continue }
            let fragment = String(match.3)
            if fragment.trimmingCharacters(in: .whitespaces).isEmpty {
                // Inter-word spaces belong to the preceding word; leading and trailing spaces are dropped.
                if !words.isEmpty {
                    pendingSpace += fragment
                }
                continue
            }
            if !pendingSpace.isEmpty {
                words[words.count - 1].text += pendingSpace
                pendingSpace = ""
            }
            words.append(LyricWord(
                start: wordStartMs / 1000,
                duration: wordDurationMs / 1000,
                text: fragment
            ))
        }
        guard !words.isEmpty else { return nil }
        let start = startMs / 1000
        // NetEase YRC line headers `[startMs, durationMs]` often span all the way to the next line's
        // start across an interlude; the actual singing ends when the last word finishes.
        let lastWordEnd = words.last.map { $0.start + max($0.duration, 0.5) } ?? (start + max(durationMs, 0) / 1000)
        let endTime = max(start + 1.5, lastWordEnd)
        let text = words.map(\.text).joined()
        return LyricLine(time: start, endTime: endTime, text: text, words: words)
    }
}
