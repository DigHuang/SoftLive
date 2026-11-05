import CommonCrypto
import Foundation

/// What the client's page says it is doing, read from its localStorage (a LevelDB in the CEF profile):
///
/// - `lastPlaying` holds the song ID and its position in whole seconds. The page updates it about every
///   second while playing and Chromium commits localStorage to disk about every two seconds, so reports
///   are coarse, but they follow seeks, which nothing else the client leaves behind does.
/// - `playingInfo` holds `playingState` (`2` while playing, `1` when paused) and `curTrack` (full song
///   metadata), flushed whenever playback pauses, resumes or changes songs.
///
/// Both values are AES-encrypted with a key built into the client (documented by CloudLyrics-for-macOS).
final class NetEaseLastPlaying {
    /// While playing, the page flushes `lastPlaying` every ~1.8 s; silence beyond this means playback stopped.
    static let pauseTimeout: TimeInterval = 4

    struct Report: Equatable {
        let songID: Int
        /// Whole seconds; the true position at `date` lies in `position ..< position + ProgressCalibration.window`.
        let position: TimeInterval
        let date: Date
    }

    struct Parsed: Equatable {
        struct Progress: Equatable {
            let songID: Int
            let position: TimeInterval
        }

        var progress: Progress?
        var isPlaying: Bool?
        var track: Track?
        var consumed: Int
    }

    var onReport: ((Report) -> Void)?
    var onPlayingChanged: ((Bool, Date) -> Void)?
    private(set) var latest: Report?
    private(set) var latestTrack: Track?
    private(set) var isPlaying = false

    private static let defaultDirectory = NetEaseClient.dataDirectory?
        .appending(path: "Documents/storage/CEFCache/Local Storage/leveldb", directoryHint: .isDirectory)
    private let directory: URL?
    // LevelDB appends to one `.log` and starts a new one when it compacts.
    private lazy var directoryWatcher = directory.map { url in
        FileWatcher(url: url, debounce: 0.2) { [weak self] in self?.followNewestLog() }
    }
    private var logWatcher: FileWatcher?
    private var log: (url: URL, offset: UInt64)?
    private var pauseTimer: Timer?
    private var explicitPlaying: Bool?

    init(directory: URL? = NetEaseLastPlaying.defaultDirectory) {
        self.directory = directory
    }

    func startWatching() {
        directoryWatcher?.start()
        followNewestLog()
    }

    func stopWatching() {
        directoryWatcher?.stop()
        logWatcher?.stop()
        logWatcher = nil
        pauseTimer?.invalidate()
        pauseTimer = nil
        log = nil
        latest = nil
        latestTrack = nil
        isPlaying = false
        explicitPlaying = nil
    }

    /// Marks playback as active when another source (such as a newly created streaming-cache `.info` file)
    /// sees a song start before the page has flushed its first `localStorage` entry.
    func noteSongStarted() {
        explicitPlaying = nil
        isPlaying = true
        schedulePauseTimer()
    }

    func apply(_ parsed: Parsed, at date: Date, now: Date = .now) {
        if let track = parsed.track { latestTrack = track }
        let previous = latest
        let newReport: Report? = if let progress = parsed.progress {
            Report(songID: progress.songID, position: progress.position, date: date)
        } else if parsed.isPlaying == true, let songID = parsed.track?.netEaseSongID, songID != previous?.songID {
            Report(songID: songID, position: 0, date: date)
        } else {
            nil
        }
        if let newReport {
            if newReport.songID != previous?.songID { explicitPlaying = nil }
            latest = newReport
        }
        if let explicit = parsed.isPlaying {
            explicitPlaying = explicit
        }

        let fresh = now.timeIntervalSince(date) < Self.pauseTimeout
        let newPlaying: Bool = if let explicit = parsed.isPlaying {
            explicit && fresh
        } else if explicitPlaying == false {
            false
        } else if let newReport {
            fresh && (isPlaying || previous == nil || newReport.songID != previous?.songID || newReport.position != previous?.position)
        } else {
            isPlaying
        }

        if newPlaying {
            schedulePauseTimer()
        } else {
            pauseTimer?.invalidate()
            pauseTimer = nil
        }

        let playingChanged = newPlaying != isPlaying
        isPlaying = newPlaying

        if playingChanged, newPlaying {
            onPlayingChanged?(true, date)
        }
        if let newReport {
            onReport?(newReport)
        }
        if playingChanged, !newPlaying {
            onPlayingChanged?(false, date)
        }
    }

    private func schedulePauseTimer() {
        pauseTimer?.invalidate()
        pauseTimer = Timer.onMain(after: Self.pauseTimeout, tolerance: 0.4) { [weak self] in
            guard let self, self.isPlaying else { return }
            self.explicitPlaying = nil
            self.isPlaying = false
            self.onPlayingChanged?(false, self.latest?.date ?? .now)
        }
    }

    func followNewestLog() {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil),
              let newest = files.filter({ $0.pathExtension == "log" }).max(by: { Self.modified($0) < Self.modified($1) })
        else { return }
        if log?.url != newest {
            readNewEntries()
            log = (newest, 0)
            logWatcher?.stop()
            logWatcher = FileWatcher(url: newest, debounce: 0.05) { [weak self] in self?.readNewEntries() }
            logWatcher?.start()
        }
        readNewEntries()
    }

    private func readNewEntries() {
        guard let (url, offset) = log, let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.readToEnd(), !data.isEmpty else { return }
        let parsed = Self.parse(data, fileOffset: Int(offset))
        log = (url, offset + UInt64(parsed.consumed))
        guard parsed.progress != nil || parsed.isPlaying != nil || parsed.track != nil else { return }
        apply(parsed, at: Self.modified(url))
    }

    private static func modified(_ url: URL) -> Date {
        // Fresh value every time: URL resource values are cached per URL instance.
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date) ?? .distantPast
    }

    // MARK: Decoding

    private static let lastPlayingMarker = Array("\0\u{01}lastPlaying".utf8)
    private static let playingInfoMarker = Array("\0\u{01}playingInfo".utf8)
    private static let key = Array(")(13daqP@ssw0rd~".utf8)
    private static let blockSize = 32_768
    private static let blockHeaderSize = 7

    /// Reads the newest `lastPlaying` and `playingInfo` records in a stretch of the LevelDB log.
    /// Each write puts the key, then the value length (varint), a format byte (1: 8-bit string)
    /// and the base64 ciphertext. Records crossing a 32 KiB LevelDB block boundary carry a 7-byte
    /// continuation header at the boundary.
    static func parse(_ data: Data, fileOffset: Int = 0) -> Parsed {
        let bytes = [UInt8](data)
        var consumed = bytes.count
        let progress = decodeNewest(LastPlayingState.self, after: lastPlayingMarker, in: bytes, fileOffset: fileOffset, consumed: &consumed)
        let info = decodeNewest(PlayingInfoState.self, after: playingInfoMarker, in: bytes, fileOffset: fileOffset, consumed: &consumed)

        let track = info?.value.curTrack?.track
        let infoSongID = track?.netEaseSongID ?? info?.value.resourceTrackId?.value
        let resolvedProgress: Parsed.Progress? = if let info, let progress, let infoSongID,
            info.offset > progress.offset, progress.value.resourceId.value != infoSongID, info.value.isPlaying {
            Parsed.Progress(songID: infoSongID, position: 0)
        } else if let progress {
            Parsed.Progress(songID: progress.value.resourceId.value, position: progress.value.current)
        } else {
            nil
        }

        return Parsed(progress: resolvedProgress, isPlaying: info?.value.isPlaying, track: track, consumed: consumed)
    }

    private static func decodeNewest<T: Decodable>(
        _ type: T.Type,
        after marker: [UInt8],
        in bytes: [UInt8],
        fileOffset: Int,
        consumed: inout Int
    ) -> (value: T, offset: Int)? {
        for (index, range) in bytes.ranges(of: marker).reversed().enumerated() {
            switch readRecord(in: bytes, from: range, fileOffset: fileOffset) {
            case .valid(let plaintext):
                if let decoded = try? JSONDecoder().decode(T.self, from: plaintext) {
                    return (decoded, range.lowerBound)
                }
            case .truncated where index == 0:
                // Cut off at EOF: leave the trailing marker so the next read sees the completed record.
                consumed = min(consumed, range.lowerBound)
            case .truncated, .invalid:
                break
            }
        }
        return nil
    }

    private enum RecordStatus {
        case valid(Data)
        case truncated
        case invalid
    }

    private static func readRecord(in bytes: [UInt8], from markerRange: Range<Int>, fileOffset: Int) -> RecordStatus {
        var cursor = LogCursor(bytes: bytes, fileOffset: fileOffset, recordStart: markerRange.lowerBound, index: markerRange.upperBound)
        var length = 0, shift = 0, completeVarint = false
        while shift < 28 {
            guard let byte = cursor.nextByte() else { return .truncated }
            length |= Int(byte & 0x7F) << shift
            shift += 7
            if byte & 0x80 == 0 {
                completeVarint = true
                break
            }
        }
        guard completeVarint, length > 1 else { return .invalid }
        guard let format = cursor.nextByte() else { return .truncated }
        guard format == 1 else { return .invalid }
        guard let base64 = cursor.read(count: length - 1) else { return .truncated }
        guard let ciphertext = Data(base64Encoded: base64),
              let plaintext = decrypt(ciphertext)
        else { return .invalid }
        return .valid(plaintext)
    }

    private struct LogCursor {
        let bytes: [UInt8]
        let fileOffset: Int
        let recordStart: Int
        var index: Int

        mutating func nextByte() -> UInt8? {
            if index > recordStart, (fileOffset + index).isMultiple(of: NetEaseLastPlaying.blockSize) {
                index += NetEaseLastPlaying.blockHeaderSize
            }
            guard index < bytes.count else { return nil }
            defer { index += 1 }
            return bytes[index]
        }

        mutating func read(count: Int) -> Data? {
            var data = Data()
            data.reserveCapacity(count)
            while data.count < count {
                if index > recordStart, (fileOffset + index).isMultiple(of: NetEaseLastPlaying.blockSize) {
                    index += NetEaseLastPlaying.blockHeaderSize
                }
                guard index < bytes.count else { return nil }
                let room = NetEaseLastPlaying.blockSize - ((fileOffset + index) % NetEaseLastPlaying.blockSize)
                let step = min(count - data.count, room)
                guard index + step <= bytes.count else { return nil }
                data.append(contentsOf: bytes[index..<(index + step)])
                index += step
            }
            return data
        }
    }

    private struct LastPlayingState: Decodable {
        let current: TimeInterval
        let resourceId: NetEaseSong.ID
    }

    private struct PlayingInfoState: Decodable {
        let playingState: Int
        let resourceTrackId: NetEaseSong.ID?
        let curTrack: NetEaseSong?

        var isPlaying: Bool { playingState == 2 }
    }

    private static func decrypt(_ ciphertext: Data) -> Data? {
        guard !ciphertext.isEmpty, ciphertext.count.isMultiple(of: kCCBlockSizeAES128) else { return nil }
        var output = Data(count: ciphertext.count + kCCBlockSizeAES128)
        let capacity = output.count
        var length = 0
        let status = output.withUnsafeMutableBytes { out in
            ciphertext.withUnsafeBytes { input in
                CCCrypt(
                    CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
                    key, key.count, nil,
                    input.baseAddress, ciphertext.count,
                    out.baseAddress, capacity, &length
                )
            }
        }
        guard status == kCCSuccess else { return nil }
        return output.prefix(length)
    }
}

/// Keeps an extrapolated position consistent with coarse progress reports.
///
/// Each report bounds the true position, so it bounds the error of the extrapolation. The bounds of
/// successive reports are intersected; only when the extrapolation falls outside them (after a seek, or
/// when a start time was off) is it corrected, to the middle of the bounds. Reports that disagree with
/// everything seen before (a seek) start over.
struct ProgressCalibration {
    /// A report of `n` seconds means the position is in `n ..< n + window`: the page writes `floor(position)`
    /// every second and Chromium flushes localStorage within ~0.1–0.2 s (measured: 0.10–1.12 s above `n`;
    /// earlier `0.66–1.68 s` numbers had included the 0.5–0.8 s buffering lead of `.info` file creation).
    static let window: TimeInterval = 1.2

    /// Possible values of (true position − extrapolated position).
    private var error: ClosedRange<TimeInterval>?

    /// The amount to move the extrapolated position by, or `nil` when it is consistent with the reports.
    mutating func correction(extrapolated: TimeInterval, reported: TimeInterval) -> TimeInterval? {
        let bounds = (reported - extrapolated)...(reported + Self.window - extrapolated)
        let narrowed = error.flatMap { $0.overlaps(bounds) ? max($0.lowerBound, bounds.lowerBound)...min($0.upperBound, bounds.upperBound) : nil }
        let band = narrowed ?? bounds
        guard !band.contains(0) else {
            error = band
            return nil
        }
        let shift = (band.lowerBound + band.upperBound) / 2
        error = (band.lowerBound - shift)...(band.upperBound - shift)
        return shift
    }
}
