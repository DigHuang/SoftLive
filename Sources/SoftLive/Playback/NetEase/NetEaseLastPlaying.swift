import CommonCrypto
import Foundation

/// What the client's page says it is playing: `lastPlaying` in its localStorage (a LevelDB in the CEF
/// profile) holds the song and its position in whole seconds. The page updates it about every second and
/// Chromium commits localStorage to disk about every two seconds, so reports are coarse, but they follow
/// seeks, which nothing else the client leaves behind does. The value is AES-encrypted with a key built
/// into the client (documented by CloudLyrics-for-macOS).
@MainActor
final class NetEaseLastPlaying {
    struct Report: Equatable {
        let songID: Int
        /// Whole seconds; the true position at `date` lies in `position ..< position + ProgressCalibration.window`.
        let position: TimeInterval
        let date: Date
    }

    var onReport: ((Report) -> Void)?
    private(set) var latest: Report?

    private static let directory = NetEaseClient.dataDirectory?
        .appending(path: "Documents/storage/CEFCache/Local Storage/leveldb", directoryHint: .isDirectory)
    // LevelDB appends to one `.log` and starts a new one when it compacts.
    private lazy var directoryWatcher = Self.directory.map { url in
        FileWatcher(url: url, debounce: 0) { [weak self] in self?.followNewestLog() }
    }
    private var logWatcher: FileWatcher?
    private var log: (url: URL, offset: UInt64)?

    func startWatching() {
        directoryWatcher?.start()
        followNewestLog()
    }

    func stopWatching() {
        directoryWatcher?.stop()
        logWatcher?.stop()
        logWatcher = nil
        log = nil
        latest = nil
    }

    private func followNewestLog() {
        guard let directory = Self.directory,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil),
              let newest = files.filter({ $0.pathExtension == "log" }).max(by: { Self.modified($0) < Self.modified($1) })
        else { return }
        if log?.url != newest {
            log = (newest, 0)
            logWatcher?.stop()
            logWatcher = FileWatcher(url: newest, debounce: 0) { [weak self] in self?.readNewEntries() }
            logWatcher?.start()
        }
        readNewEntries()
    }

    private func readNewEntries() {
        guard let (url, offset) = log, let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.readToEnd(), !data.isEmpty else { return }
        log = (url, offset + UInt64(data.count))
        guard let (songID, position) = Self.lastValue(in: data) else { return }
        // The newest value is the last thing written to the file.
        let report = Report(songID: songID, position: position, date: Self.modified(url))
        latest = report
        onReport?(report)
    }

    private static func modified(_ url: URL) -> Date {
        // Fresh value every time: URL resource values are cached per URL instance.
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date) ?? .distantPast
    }

    // MARK: Decoding

    nonisolated private static let marker = Array("lastPlaying".utf8)
    nonisolated private static let key = Array(")(13daqP@ssw0rd~".utf8)

    /// The newest readable `lastPlaying` value in a stretch of the LevelDB log. Each write puts the key,
    /// then the value length (varint), a format byte (1: 8-bit string) and the base64 ciphertext.
    nonisolated static func lastValue(in data: Data) -> (songID: Int, position: TimeInterval)? {
        let bytes = [UInt8](data)
        let markers = bytes.ranges(of: marker)
        for range in markers.reversed() {
            var index = range.upperBound
            var length = 0, shift = 0
            while index < bytes.count, shift < 28 {
                let byte = bytes[index]
                index += 1
                length |= Int(byte & 0x7F) << shift
                shift += 7
                if byte & 0x80 == 0 { break }
            }
            guard length > 1, index + length <= bytes.count, bytes[index] == 1,
                  let ciphertext = Data(base64Encoded: Data(bytes[(index + 1)..<(index + length)])),
                  let plaintext = decrypt(ciphertext),
                  let state = try? JSONDecoder().decode(State.self, from: plaintext)
            else { continue }
            return (state.resourceId.value, state.current)
        }
        return nil
    }

    private struct State: Decodable {
        let current: TimeInterval
        let resourceId: NetEaseSong.ID
    }

    nonisolated private static func decrypt(_ ciphertext: Data) -> Data? {
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
    /// A report of `n` seconds means the position is in `n ..< n + window`: the page stores whole seconds
    /// and the disk copy lags up to about a second behind it (measured: 0.66–1.68 s above `n`).
    static let window: TimeInterval = 2

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
