import Foundation

/// NetEase Cloud Music public web API: song details, catalog search and lyrics
/// (word-synced YRC when available, else line-synced LRC, plus the Chinese translation).
enum NetEaseAPI {
    private static let headers = ["Referer": "https://music.163.com"]

    static func track(songID: Int) async throws -> Track? {
        let response = try await HTTPClient.get(
            "https://music.163.com/api/song/detail/",
            query: ["ids": "[\(songID)]"],
            headers: headers,
            as: SongsResponse.self
        )
        return response?.songs?.first?.track
    }

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

    private struct SongsResponse: Decodable {
        let songs: [NetEaseSong]?
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

/// A song as described by both the web API and the client's local history table.
struct NetEaseSong: Decodable {
    /// The web API sends song IDs as numbers, the history table as strings.
    struct ID: Decodable {
        let value: Int

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Int.self) {
                value = number
            } else if let number = Int(try container.decode(String.self)) {
                value = number
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a song ID")
            }
        }
    }

    struct Named: Decodable { let name: String }
    struct Album: Decodable {
        let name: String
        let picUrl: String?
    }

    let id: ID
    let name: String
    /// Milliseconds.
    let duration: Double
    let artists: [Named]?
    let album: Album?

    var artistNames: [String] { (artists ?? []).map(\.name) }

    var track: Track {
        Track(
            id: String(id.value),
            title: name,
            artist: artistNames.joined(separator: " / "),
            album: album?.name ?? "",
            duration: duration / 1000,
            source: .netEase,
            artworkURL: album?.picUrl.flatMap(Self.artworkURL)
        )
    }

    var candidate: SongCandidate {
        SongCandidate(title: name, artists: artistNames, duration: duration / 1000)
    }

    /// Covers are listed as `http://`; ask the CDN for a small HTTPS rendition.
    private static func artworkURL(_ picUrl: String) -> URL? {
        guard var components = URLComponents(string: picUrl) else { return nil }
        components.scheme = "https"
        components.queryItems = [URLQueryItem(name: "param", value: "300y300")]
        return components.url
    }
}
