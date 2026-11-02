import Foundation

/// Finds lyrics for a track: exact NetEase ID first, then catalog search (NetEase → LRCLIB).
/// Results are cached in memory and on disk; "not found" is only remembered for the session.
@MainActor
final class LyricsService {
    private var memory: [String: Lyrics?] = [:]
    private let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appending(path: "SoftLive/Lyrics-v2", directoryHint: .isDirectory) // v2: word timing

    func lyrics(for track: Track) async -> Lyrics? {
        let key = "\(track.source.rawValue)-\(track.id)"
        if let cached = memory[key] { return cached }
        let file = directory.appending(path: "\(key).json")
        if let data = try? Data(contentsOf: file), let stored = try? JSONDecoder().decode(Lyrics.self, from: data) {
            memory[key] = stored
            return stored
        }

        let found: Lyrics?
        do {
            found = try await fetch(track)
        } catch {
            return nil // Network failures are not cached, so the next play retries.
        }
        memory[key] = .some(found)
        if let found, let data = try? JSONEncoder().encode(found) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
        return found
    }

    private func fetch(_ track: Track) async throws -> Lyrics? {
        if let songID = track.netEaseSongID {
            return try await NetEaseAPI.lyrics(songID: songID)
        }
        if let lyrics = try await NetEaseAPI.lyrics(matching: track) {
            return lyrics
        }
        return try await LRCLibAPI.lyrics(matching: track)
    }
}
