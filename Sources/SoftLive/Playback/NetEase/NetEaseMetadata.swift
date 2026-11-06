import Foundation

/// Song details used when the local player storage has no metadata.
enum NetEaseMetadata {
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

    private struct SongsResponse: Decodable {
        let songs: [NetEaseSong]?
    }
}
