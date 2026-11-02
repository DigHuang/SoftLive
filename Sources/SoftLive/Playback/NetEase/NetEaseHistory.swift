import Foundation
import SQLite3

/// The client's "recently played" table: `historyTracks` holds the song JSON and a time in ms.
///
/// The page script writes it, reliably only while the window is in front: in the background rows arrive
/// minutes late (stamped with the write time) or never. It is still the only record of songs the streaming
/// cache does not see (downloads, songs replayed from the cache), and it carries their details.
@MainActor
final class NetEaseHistory {
    struct Entry: Equatable {
        let track: Track
        let date: Date
    }

    /// Called after the database was written.
    var onChange: (() -> Void)?

    private static let databaseURL = NetEaseClient.dataDirectory?.appending(path: "Documents/storage/sqlite_storage.sqlite3")
    // The database uses a rollback journal, so writes land in the main file.
    private lazy var watcher = Self.databaseURL.map { url in FileWatcher(url: url) { [weak self] in self?.onChange?() } }

    func startWatching() { watcher?.start() }
    func stopWatching() { watcher?.stop() }

    /// The most recent row.
    func latest() -> Entry? {
        guard let url = Self.databaseURL else { return nil }
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        sqlite3_busy_timeout(db, 200)

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "SELECT playtime, jsonStr FROM historyTracks ORDER BY playtime DESC LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW,
              let json = sqlite3_column_text(statement, 1),
              let song = try? JSONDecoder().decode(NetEaseSong.self, from: Data(String(cString: json).utf8))
        else { return nil }

        let date = Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 0)) / 1000)
        return Entry(track: song.track, date: date)
    }
}
