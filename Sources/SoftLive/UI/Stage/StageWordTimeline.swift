import Foundation

/// Pure segmentation and timing for the stage's word and character units.
enum StageWordTimeline {
    struct WordUnit: Equatable {
        let text: String
        let start: TimeInterval
        let end: TimeInterval
    }

    static func effectiveWords(for line: LyricLine, nextLineTime: TimeInterval?, perCharacter: Bool = false) -> [WordUnit] {
        if let yrcWords = line.words, !yrcWords.isEmpty {
            guard perCharacter else {
                return yrcWords.map { w in
                    let d = max(0.12, w.duration)
                    return WordUnit(text: w.text, start: w.start, end: w.start + d)
                }
            }
            var units: [WordUnit] = []
            for w in yrcWords {
                let d = max(0.12, w.duration)
                let subTokens = segmentText(w.text)
                if subTokens.count <= 1 {
                    units.append(WordUnit(text: w.text, start: w.start, end: w.start + d))
                } else {
                    let step = d / Double(subTokens.count)
                    for (idx, tok) in subTokens.enumerated() {
                        let st = w.start + Double(idx) * step
                        units.append(WordUnit(text: tok, start: st, end: st + max(0.10, step)))
                    }
                }
            }
            return units
        }
        let tokens = segmentText(line.text)
        guard !tokens.isEmpty else { return [] }
        let span: TimeInterval
        if let next = nextLineTime, next > line.time {
            span = min(max((next - line.time) * 0.82, 1.6), 4.5)
        } else {
            span = 3.2
        }
        let totalChars = max(1, tokens.reduce(0) { $0 + max(1, $1.trimmingCharacters(in: .whitespaces).count) })
        var cursor = line.time
        return tokens.map { token in
            let weight = Double(max(1, token.trimmingCharacters(in: .whitespaces).count))
            let d = max(0.14, span * weight / Double(totalChars))
            let unit = WordUnit(text: token, start: cursor, end: cursor + d)
            cursor += d
            return unit
        }
    }

    static func segmentText(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty {
                out.append(current)
                current = ""
            }
        }
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespaces.contains(scalar) {
                if !current.isEmpty {
                    current.append(" ")
                    flush()
                }
            } else if isCJKScalar(scalar) {
                flush()
                out.append(String(scalar))
            } else {
                current.append(Character(scalar))
            }
        }
        flush()
        return out
    }

    private static func isCJKScalar(_ s: UnicodeScalar) -> Bool {
        switch s.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x3040...0x30FF, 0xAC00...0xD7AF, 0xFF00...0xFFEF, 0x3000...0x303F:
            return true
        default:
            return false
        }
    }
}
