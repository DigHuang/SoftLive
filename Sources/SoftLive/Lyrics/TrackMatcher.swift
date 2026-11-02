import Foundation

/// A song returned by a lyrics provider's search, to be compared with the playing track.
struct SongCandidate: Sendable {
    let title: String
    let artists: [String]
    /// Seconds; 0 when unknown.
    let duration: TimeInterval
}

/// Picks the search result that really is the playing track.
enum TrackMatcher {
    /// Results whose duration differs more than this are different recordings.
    static let maxDurationDifference: TimeInterval = 8

    /// Keyword for provider searches: the cleaned title plus the artist.
    static func searchKeyword(for track: Track) -> String {
        "\(stripDecorations(track.title)) \(track.artist)".trimmingCharacters(in: .whitespaces)
    }

    static func best<C>(_ candidates: [C], for track: Track, song: (C) -> SongCandidate) -> C? {
        candidates
            .compactMap { candidate in score(song(candidate), for: track).map { (candidate, $0) } }
            .max { $0.1 < $1.1 }?
            .0
    }

    /// `nil` when the candidate cannot be the track; otherwise higher is better.
    static func score(_ song: SongCandidate, for track: Track) -> Double? {
        var durationScore = 0.5
        if track.duration > 0, song.duration > 0 {
            let difference = abs(track.duration - song.duration)
            guard difference <= maxDurationDifference else { return nil }
            durationScore = 1 - difference / maxDurationDifference
        }

        let title = normalize(track.title), candidateTitle = normalize(song.title)
        let titleScore: Double
        if title == candidateTitle {
            titleScore = 2
        } else if !title.isEmpty, !candidateTitle.isEmpty, title.contains(candidateTitle) || candidateTitle.contains(title) {
            titleScore = 1
        } else {
            return nil
        }

        let artist = normalize(track.artist)
        let artistMatches = song.artists.map(normalize).contains { !$0.isEmpty && (artist.contains($0) || $0.contains(artist)) }
        return titleScore + (artistMatches ? 1 : 0) + durationScore
    }

    /// Lowercased, width/diacritic folded, without decorations, spaces or punctuation.
    static func normalize(_ string: String) -> String {
        stripDecorations(string)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
    }

    /// Removes "(Live)", "[Remastered]", "- 2011 Remaster", "feat. X" and the like.
    private static func stripDecorations(_ string: String) -> String {
        string
            .replacingOccurrences(of: #"\s*[\(\[（【][^\)\]）】]*[\)\]）】]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+-\s+.*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+(feat\.?|ft\.)\s+.*$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
    }
}
