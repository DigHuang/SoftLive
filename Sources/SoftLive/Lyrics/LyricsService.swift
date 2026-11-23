import Foundation

/// Finds lyrics for a track: exact NetEase ID first, then catalog search (NetEase → LRCLIB).
/// Results are cached in memory and on disk; "not found" is only remembered for the session.
final class LyricsService {
    struct Provider {
        var netEaseByID: (Int) async throws -> Lyrics? = NetEaseAPI.lyrics(songID:)
        var netEaseMatch: (Track) async throws -> Lyrics? = NetEaseAPI.lyrics(matching:)
        var lrcLibMatch: (Track) async throws -> Lyrics? = LRCLibAPI.lyrics(matching:)
    }

    static let defaultDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appending(path: "SoftLive/Lyrics-v4", directoryHint: .isDirectory) // v4: non-empty lines + word-based endTime

    private var memory: [String: Lyrics?] = [:]
    private let directory: URL?
    private let provider: Provider

    init(cacheDirectory: URL? = LyricsService.defaultDirectory, provider: Provider = Provider()) {
        self.directory = cacheDirectory
        self.provider = provider
    }

    func lyrics(for track: Track) async -> Lyrics? {
        let key = "\(track.source.rawValue)-\(track.id)"
        if let cached = memory[key] { return cached }
        let file = directory?.appending(path: "\(key).json")
        if let file, let data = try? Data(contentsOf: file), let stored = try? JSONDecoder().decode(Lyrics.self, from: data) {
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
        if let directory, let file, let found, let data = try? JSONEncoder().encode(found) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
        return found
    }

    private func fetch(_ track: Track) async throws -> Lyrics? {
        if let songID = track.netEaseSongID {
            return try await provider.netEaseByID(songID)
        }
        var netEaseError: (any Error)?
        do {
            if let lyrics = try await provider.netEaseMatch(track) {
                return lyrics
            }
        } catch {
            if Task.isCancelled || error.isCancellation { throw error }
            netEaseError = error
        }
        if let lyrics = try await provider.lrcLibMatch(track) {
            return lyrics
        }
        if let netEaseError {
            throw netEaseError
        }
        return nil
    }
}

private extension Error {
    var isCancellation: Bool {
        self is CancellationError || (self as? URLError)?.code == .cancelled
    }
}
