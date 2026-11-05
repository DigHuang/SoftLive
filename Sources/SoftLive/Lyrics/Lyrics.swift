import Foundation

struct LyricWord: Hashable, Sendable, Codable {
    let start: TimeInterval
    let duration: TimeInterval
    var text: String

    /// How much of the word has been sung at `time`, from 0 to 1.
    func progress(at time: TimeInterval) -> Double {
        guard duration > 0 else { return time >= start ? 1 : 0 }
        return min(max((time - start) / duration, 0), 1)
    }
}

/// An instrumental stretch (intro or interlude) long enough to show a breathing indicator instead of a stale line.
struct Interlude: Equatable, Sendable {
    let start: TimeInterval
    let end: TimeInterval
}

struct LyricLine: Equatable, Sendable, Codable {
    private static let exactCreditHeads: Set<String> = ["词", "曲", "唱"]
    private static let prefixCreditHeads = [
        "作词", "作曲", "编曲", "制作", "监制", "混音", "母带", "录音",
        "和声", "合声", "和音", "吉他", "贝斯", "鼓", "弦乐", "管乐", "键盘",
        "统筹", "策划", "企划", "出品", "发行", "原唱", "演唱", "翻唱",
        "封面", "设计", "鸣谢", "特别鸣谢", "执行", "配唱", "编写", "乐队",
        "推广", "宣传", "版权", "指导", "总监", "词lyricist", "曲composer",
        "op", "sp", "a&r", "lyrics", "music", "composer", "arranger", "producer", "vocal", "mixed", "mastered", "design"
    ]

    let time: TimeInterval
    var endTime: TimeInterval?
    let text: String
    var translation: String?
    /// Word-level timing, when the source provides it.
    var words: [LyricWord]?

    /// Whether the line lists song credits (such as `作词 : 林夕`) rather than sung lyrics.
    var isCredit: Bool {
        guard let colon = text.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return false }
        let head = text[..<colon].trimmingCharacters(in: .whitespaces)
        guard !head.isEmpty, head.count <= 16 else { return false }
        if Self.exactCreditHeads.contains(head) { return true }
        let lower = head.lowercased()
        return Self.prefixCreditHeads.contains { lower.hasPrefix($0) }
    }
}

struct Lyrics: Equatable, Sendable, Codable {
    static let minIntroDuration: TimeInterval = 5.0
    static let minMidSongInterludeDuration: TimeInterval = 7.0
    private static let postLineHold: TimeInterval = 1.5
    private static let creditDisplayDuration: TimeInterval = 2.5
    private static let defaultLRCLineDuration: TimeInterval = 8.0

    /// Non-empty lines sorted by `time`.
    let lines: [LyricLine]

    /// Translations are LRC; each goes to the line nearest in time. Word-timed lines start a little
    /// off the LRC timestamps the translations were written against, hence the tolerance.
    /// Empty LRC stanza-break lines are discarded so they never cut off a sung line early.
    /// Returns `nil` when no line has text.
    init?(lines: [LyricLine], translation: String? = nil, tolerance: TimeInterval = 0.75) {
        var lines = lines
            .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { $0.time < $1.time }
        guard !lines.isEmpty else { return nil }
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

    /// Index of the first non-empty line after `index` (skipping credit lines when `skipCredits` is `true`).
    func nextSungIndex(after index: Int?, skipCredits: Bool = false) -> Int? {
        let start = (index ?? -1) + 1
        guard start < lines.count else { return nil }
        if skipCredits, let nonCredit = lines[start...].firstIndex(where: { !$0.text.isEmpty && !$0.isCredit }) {
            return nonCredit
        }
        return lines[start...].firstIndex { !$0.text.isEmpty }
    }

    /// Returns the active intro or interlude window when `time` falls inside a long instrumental break.
    func interlude(at time: TimeInterval) -> Interlude? {
        guard let window = upcomingInterlude(at: time), time >= window.start, time < window.end else {
            return nil
        }
        return window
    }

    /// Next timestamp after `time` where either the active line changes or an interlude starts/ends.
    func nextEventTime(after time: TimeInterval) -> TimeInterval? {
        let nextLineIndex = (lineIndex(at: time) ?? -1) + 1
        let nextLineTime = lines.indices.contains(nextLineIndex) ? lines[nextLineIndex].time : nil
        if let window = upcomingInterlude(at: time) {
            let interludeEvent = time < window.start ? window.start : window.end
            if let nextLineTime {
                return min(interludeEvent, nextLineTime)
            }
            return interludeEvent
        }
        return nextLineTime
    }

    private func upcomingInterlude(at time: TimeInterval) -> Interlude? {
        let rawIndex = lineIndex(at: time)
        guard let nextSung = nextSungIndex(after: rawIndex) else { return nil }
        let nextLine = lines[nextSung]
        let nextTime = nextLine.time

        let activeIndex = rawIndex.flatMap { idx in
            lines[...idx].lastIndex { !$0.text.isEmpty }
        }
        guard let active = activeIndex else {
            // Before the first line: only enter an intro interlude when the first line is a real sung line
            // starting at least `minIntroDuration` into the track.
            guard !nextLine.isCredit, nextTime >= Self.minIntroDuration else { return nil }
            return Interlude(start: 0, end: nextTime)
        }

        let line = lines[active]
        if line.isCredit {
            // Stepping through opening credit lines: keep showing each credit until the last credit finishes.
            if nextLine.isCredit, nextTime - line.time < 6.0 {
                return nil
            }
            let gapStart = min(line.time + Self.creditDisplayDuration, nextTime)
            guard nextTime - gapStart >= Self.minIntroDuration else { return nil }
            return Interlude(start: gapStart, end: nextTime)
        }

        let gapStart: TimeInterval
        if let lastWord = line.words?.last {
            let wordEnd = max(line.time + 1.5, lastWord.start + max(lastWord.duration, 0.5))
            gapStart = wordEnd + Self.postLineHold
        } else if let endTime = line.endTime {
            gapStart = max(line.time + 1.5, endTime) + Self.postLineHold
        } else {
            // Plain LRC lines carry no word or line duration; slow ballad lines commonly last 6–8 seconds.
            gapStart = line.time + Self.defaultLRCLineDuration
        }

        let start = min(gapStart, nextTime)
        guard nextTime - start >= Self.minMidSongInterludeDuration else { return nil }
        return Interlude(start: start, end: nextTime)
    }
}
