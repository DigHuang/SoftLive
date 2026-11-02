import Foundation

struct LyricWord: Hashable, Sendable, Codable {
    let start: TimeInterval
    let duration: TimeInterval
    let text: String

    /// How much of the word has been sung at `time`, from 0 to 1.
    func progress(at time: TimeInterval) -> Double {
        guard duration > 0 else { return time >= start ? 1 : 0 }
        return min(max((time - start) / duration, 0), 1)
    }
}

struct LyricLine: Equatable, Sendable, Codable {
    let time: TimeInterval
    let text: String
    var translation: String?
    /// Word-level timing, when the source provides it.
    var words: [LyricWord]?
}

struct Lyrics: Equatable, Sendable, Codable {
    /// Sorted by `time`.
    let lines: [LyricLine]

    /// Translations are LRC; each goes to the line nearest in time. Word-timed lines start a little
    /// off the LRC timestamps the translations were written against, hence the tolerance.
    /// Returns `nil` when no line has text.
    init?(lines: [LyricLine], translation: String? = nil, tolerance: TimeInterval = 0.75) {
        guard lines.contains(where: { !$0.text.isEmpty }) else { return nil }
        var lines = lines.sorted { $0.time < $1.time }
        for entry in LRCParser.timedLines(translation ?? "") where !entry.text.isEmpty {
            guard let nearest = lines.indices.min(by: { abs(lines[$0].time - entry.time) < abs(lines[$1].time - entry.time) }),
                  abs(lines[nearest].time - entry.time) <= tolerance,
                  lines[nearest].translation == nil
            else { continue }
            lines[nearest].translation = entry.text
        }
        self.lines = lines
    }

    /// Index of the line being sung at `time`; `nil` before the first line.
    func lineIndex(at time: TimeInterval) -> Int? {
        var low = 0, high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if lines[mid].time <= time { low = mid + 1 } else { high = mid }
        }
        return low == 0 ? nil : low - 1
    }
}
