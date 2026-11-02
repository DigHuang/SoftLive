import Foundation

/// Line-synced LRC: multiple time tags per line, `[offset:±ms]`; metadata tags and untagged lines are ignored.
enum LRCParser {
    static func lines(_ lrc: String) -> [LyricLine] {
        timedLines(lrc).map { LyricLine(time: $0.time, text: $0.text) }
    }

    static func timedLines(_ lrc: String) -> [(time: TimeInterval, text: String)] {
        var offset: TimeInterval = 0
        var lines: [(time: TimeInterval, text: String)] = []

        for rawLine in lrc.split(whereSeparator: \.isNewline) {
            var rest = rawLine[...]
            var times: [TimeInterval] = []
            while rest.first == "[", let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                if let time = parseTime(tag) {
                    times.append(time)
                } else if tag.hasPrefix("offset:"), let milliseconds = Double(tag.dropFirst(7).trimmingCharacters(in: .whitespaces)) {
                    offset = milliseconds / 1000
                }
                rest = rest[rest.index(after: close)...]
            }
            let text = rest.trimmingCharacters(in: .whitespaces)
            lines += times.map { ($0, text) }
        }
        // A positive LRC offset shows lyrics earlier.
        return lines.map { (max(0, $0.time - offset), $0.text) }.sorted { $0.time < $1.time }
    }

    /// `mm:ss`, `mm:ss.xx` or `mm:ss:xx`.
    private static func parseTime(_ tag: Substring) -> TimeInterval? {
        let parts = tag.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count),
              let minutes = Double(parts[0]), let seconds = Double(parts[1]), minutes >= 0, seconds >= 0
        else { return nil }
        let fraction = parts.count == 3 ? Double("0.\(parts[2])") : 0
        guard let fraction else { return nil }
        return minutes * 60 + seconds + fraction
    }
}
