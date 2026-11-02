import Foundation

/// LRCLIB (https://lrclib.net): free, keyless, strong on western catalogs.
enum LRCLibAPI {
    static func lyrics(matching track: Track) async throws -> Lyrics? {
        var query = ["track_name": track.title]
        if !track.artist.isEmpty { query["artist_name"] = track.artist }
        let results = try await HTTPClient.get("https://lrclib.net/api/search", query: query, as: [Record].self) ?? []
        let synced = results.filter { !($0.syncedLyrics ?? "").isEmpty }
        guard let match = TrackMatcher.best(synced, for: track, song: \.candidate) else { return nil }
        return Lyrics(lines: LRCParser.lines(match.syncedLyrics ?? ""))
    }

    private struct Record: Decodable {
        let trackName: String
        let artistName: String
        /// Seconds.
        let duration: Double?
        let syncedLyrics: String?

        var candidate: SongCandidate {
            SongCandidate(title: trackName, artists: [artistName], duration: duration ?? 0)
        }
    }
}
