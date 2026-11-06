import Foundation

/// Shared song format for the web API, local history, and LevelDB playing info.
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
        let cover: String?
        let blurPicUrl: String?

        var imageURL: String? {
            [picUrl, cover, blurPicUrl].compactMap { $0 }.first { !$0.isEmpty }
        }
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
            artworkURL: album?.imageURL.flatMap(Self.artworkURL)
        )
    }

    /// Covers are listed as `http://`; ask the CDN for a small HTTPS rendition.
    private static func artworkURL(_ picUrl: String) -> URL? {
        guard var components = URLComponents(string: picUrl) else { return nil }
        components.scheme = "https"
        components.queryItems = [URLQueryItem(name: "param", value: "300y300")]
        return components.url
    }
}
