import Foundation

/// The client's streaming cache. The native player creates `<songID>-_-_<bitrate>-_-_<hash>.info` the
/// moment a song starts streaming, whether or not the window is in front, so the file's creation date is
/// the song's start time. Songs replayed from this cache or from downloads create no file.
final class NetEasePlayCache {
    /// Called after files were added to or removed from the cache.
    var onChange: (() -> Void)?

    private static let directory = NetEaseClient.dataDirectory?.appending(path: "Caches/online_play_cache", directoryHint: .isDirectory)
    private var cachedStarts: [Int: Date]?
    private var lastDirectoryModDate: Date?
    private lazy var watcher = Self.directory.map { url in
        FileWatcher(url: url) { [weak self] in
            self?.cachedStarts = nil
            self?.lastDirectoryModDate = nil
            self?.onChange?()
        }
    }

    func startWatching() { watcher?.start() }
    func stopWatching() {
        watcher?.stop()
        cachedStarts = nil
        lastDirectoryModDate = nil
    }

    /// When each song in the cache last started streaming.
    func starts() -> [Int: Date] {
        guard let directory = Self.directory else { return [:] }
        let currentModDate = (try? directory.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let cached = cachedStarts, let currentModDate, let lastDirectoryModDate, currentModDate <= lastDirectoryModDate {
            return cached
        }
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])
        else { return [:] }
        var starts: [Int: Date] = [:]
        // Only `.info`: the `.idx!` of a song is created when it ends, i.e. when the next one starts.
        for file in files where file.pathExtension == "info" {
            guard let songID = Int(file.lastPathComponent.prefix { $0.isNumber }),
                  let created = try? file.resourceValues(forKeys: [.creationDateKey]).creationDate
            else { continue }
            starts[songID] = max(starts[songID] ?? created, created)
        }
        cachedStarts = starts
        lastDirectoryModDate = currentModDate
        return starts
    }
}
