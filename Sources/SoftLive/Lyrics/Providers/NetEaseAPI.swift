import Foundation

/// NetEase Cloud Music lyric provider: catalog search and lyrics
/// (word-synced YRC when available, else line-synced LRC, plus the Chinese translation).
enum NetEaseAPI {
    private static let headers = ["Referer": "https://music.163.com"]

    static func lyrics(songID: Int) async throws -> Lyrics? {
        let response = try await HTTPClient.get(
            "https://music.163.com/api/song/lyric",
            // -1 = latest version; a positive value returns empty text when the stored version is older.
            query: ["id": String(songID), "lv": "-1", "tv": "-1", "yv": "-1"],
            headers: headers,
            as: LyricResponse.self
        )
        guard let response else { return nil }
        let wordSynced = YRCParser.lines(response.yrc?.lyric ?? "")
        let lines = wordSynced.isEmpty ? LRCParser.lines(response.lrc?.lyric ?? "") : wordSynced
        return Lyrics(lines: lines, translation: response.tlyric?.lyric)
    }

    /// Searches the catalog for `track` and returns the lyrics of the best match.
    static func lyrics(matching track: Track) async throws -> Lyrics? {
        let response = try await HTTPClient.get(
            "https://music.163.com/api/search/get",
            query: ["s": TrackMatcher.searchKeyword(for: track), "type": "1", "limit": "10"],
            headers: headers,
            as: SearchResponse.self
        )
        guard let match = TrackMatcher.best(response?.result?.songs ?? [], for: track, song: \.candidate) else { return nil }
        return try await lyrics(songID: match.id.value)
    }

    private struct SearchResponse: Decodable {
        struct Result: Decodable { let songs: [NetEaseSong]? }
        let result: Result?
    }

    private struct LyricResponse: Decodable {
        struct Body: Decodable { let lyric: String? }
        let lrc: Body?
        let tlyric: Body?
        let yrc: Body?
    }
}

private extension NetEaseSong {
    var candidate: SongCandidate {
        SongCandidate(title: name, artists: artistNames, duration: duration / 1000)
    }
}
