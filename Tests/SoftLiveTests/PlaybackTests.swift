import AppKit
import CommonCrypto
import Foundation
import Testing
@testable import SoftLive

struct PlaybackModelTests {
    private final class MockSource: PlayerSource {
        let kind: PlayerKind
        var state: PlaybackState? { didSet { onChange?() } }
        var recentTrack: Track? { didSet { onChange?() } }
        var onChange: (() -> Void)?
        var playCallCount = 0
        var pauseCallCount = 0
        var nextCallCount = 0
        var closeCallCount = 0
        var artworks: [String: NSImage] = [:]

        init(kind: PlayerKind) { self.kind = kind }
        func start() { onChange?() }
        func play() {
            playCallCount += 1
            if var current = state, !current.isPlaying {
                current.setPlaying(true)
                state = current
            } else if state == nil, let recent = recentTrack {
                state = PlaybackState(track: recent, isPlaying: true, position: 0)
            }
        }
        func pause() {
            pauseCallCount += 1
            if var current = state, current.isPlaying {
                current.setPlaying(false)
                state = current
            }
        }
        func nextTrack() {
            nextCallCount += 1
        }
        func close() {
            closeCallCount += 1
            state = nil
        }
        func artwork(for track: Track) async -> NSImage? { artworks[track.id] }
    }

    @Test func switchesToPlayingSourceAndResetsOffsetOnTrackChange() {
        let first = MockSource(kind: .appleMusic)
        let second = MockSource(kind: .netEase)
        let model = PlaybackModel(sources: [first, second])
        model.start()

        let trackA = Track(id: "a", title: "Song A", artist: "Artist", album: "", duration: 180, source: .appleMusic)
        let trackB = Track(id: "b", title: "Song B", artist: "Artist", album: "", duration: 180, source: .netEase)
        second.recentTrack = trackB
        #expect(model.recentTracks[.netEase] == trackB)

        model.play(.netEase)
        #expect(second.playCallCount == 1)

        first.state = PlaybackState(track: trackA, isPlaying: true, position: 0)
        #expect(model.playback?.track == trackA)
        model.offset = 1.5

        // Second source starts playing and takes over; offset resets on track change.
        second.state = PlaybackState(track: trackB, isPlaying: true, position: 0)
        #expect(model.playback?.track == trackB)
        #expect(model.offset == 0)

        // Second source pauses while first is still playing: falls back to the playing source.
        second.state = PlaybackState(track: trackB, isPlaying: false, position: 10)
        #expect(model.playback?.track == trackA)

        // First source also pauses: stays with the current source while it still has a track.
        first.state = PlaybackState(track: trackA, isPlaying: false, position: 20)
        #expect(model.playback?.track == trackA)

        // Resume and pause via togglePlayPause.
        model.togglePlayPause()
        #expect(first.playCallCount == 1)
        #expect(model.isPlaying == true)
        model.togglePlayPause()
        #expect(first.pauseCallCount == 1)
        #expect(model.isPlaying == false)

        // Next track forwards to the active source.
        model.nextTrack()
        #expect(first.nextCallCount == 1)

        // Close playback terminates the source, collapses to nil, and re-opens when playing resumes.
        first.recentTrack = trackA
        model.closePlayback()
        #expect(first.closeCallCount == 1)
        #expect(model.playback == nil)
        model.play(.appleMusic)
        #expect(model.playback?.track == trackA)
    }

    @Test func updatesArtworkOnTrackChangeWithoutLaggingBehind() async {
        let source = MockSource(kind: .netEase)
        let imageA = NSImage(size: NSSize(width: 10, height: 10))
        let imageB = NSImage(size: NSSize(width: 20, height: 20))
        source.artworks = ["a": imageA, "b": imageB]

        let model = PlaybackModel(sources: [source])
        model.start()

        let trackA = Track(id: "a", title: "Song A", artist: "Artist", album: "", duration: 180, source: .netEase)
        let trackB = Track(id: "b", title: "Song B", artist: "Artist", album: "", duration: 180, source: .netEase)

        source.recentTrack = trackA
        source.state = PlaybackState(track: trackA, isPlaying: true, position: 0)
        await Task.yield()
        #expect(model.artwork === imageA)

        // Switching to trackB must not reuse trackA's cached recentArtworks entry.
        source.recentTrack = trackB
        source.state = PlaybackState(track: trackB, isPlaying: true, position: 0)
        #expect(model.artwork == nil)
        await Task.yield()
        #expect(model.artwork === imageB)
    }

    @Test func retriesArtworkOnPlaybackWhenInitialRecentArtworkReturnedNil() async {
        let source = MockSource(kind: .appleMusic)
        let image = NSImage(size: NSSize(width: 16, height: 16))
        let track = Track(id: "a", title: "Song A", artist: "Artist", album: "", duration: 180, source: .appleMusic)

        let model = PlaybackModel(sources: [source])
        model.start()

        // First attempt while only recentTrack is known returns nil.
        source.recentTrack = track
        await Task.yield()
        #expect(model.recentArtworks[.appleMusic] == nil)

        // Once playback starts and artwork becomes available, loadArtwork must retry instead of being blocked.
        source.artworks["a"] = image
        source.state = PlaybackState(track: track, isPlaying: true, position: 0)
        await Task.yield()
        #expect(model.artwork === image)
        #expect(model.recentArtworks[.appleMusic] === image)
    }
}

struct PlaybackStateTests {
    private let track = Track(id: "1", title: "t", artist: "a", album: "", duration: 100, source: .netEase)

    @Test func extrapolatesWhilePlayingAndFreezesWhenPaused() {
        let start = Date(timeIntervalSince1970: 0)
        var state = PlaybackState(track: track, isPlaying: true, position: 10, at: start)
        #expect(state.position(at: start.addingTimeInterval(5)) == 15)

        state.setPlaying(false, at: start.addingTimeInterval(5))
        #expect(state.position(at: start.addingTimeInterval(60)) == 15)

        state.setPlaying(true, at: start.addingTimeInterval(60))
        #expect(state.position(at: start.addingTimeInterval(62)) == 17)
    }
}

/// Cases taken from a real background listening session, where history rows went missing or came late.
struct NetEasePlayTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func row(_ songID: Int, at offset: TimeInterval, duration: TimeInterval) -> NetEaseHistory.Entry {
        let track = Track(id: String(songID), title: "", artist: "", album: "", duration: duration, source: .netEase)
        return NetEaseHistory.Entry(track: track, date: t0.addingTimeInterval(offset))
    }

    @Test func followsTheCacheWhenTheHistoryRowIsMissing() {
        let play = NetEasePlay.latest(cacheStarts: [1: t0, 2: t0 + 204], history: row(1, at: 0, duration: 203))
        #expect(play == NetEasePlay(songID: 2, start: t0 + 204))
    }

    @Test func keepsTheCacheStartWhenTheHistoryRowIsLate() {
        let play = NetEasePlay.latest(cacheStarts: [1: t0], history: row(1, at: 287, duration: 309))
        #expect(play == NetEasePlay(songID: 1, start: t0))
    }

    @Test func ignoresALateRowOfASongThatAlreadyEnded() {
        let play = NetEasePlay.latest(cacheStarts: [1: t0, 2: t0 + 110], history: row(1, at: 112, duration: 110))
        #expect(play == NetEasePlay(songID: 2, start: t0 + 110))
    }

    @Test func trustsTheHistoryForSongsTheCacheDoesNotSee() {
        // Song 3 is a download; song 1 replays from a cache file made by an earlier play.
        #expect(NetEasePlay.latest(cacheStarts: [1: t0], history: row(3, at: 50, duration: 200))
            == NetEasePlay(songID: 3, start: t0 + 50))
        #expect(NetEasePlay.latest(cacheStarts: [1: t0], history: row(1, at: 3600, duration: 200))
            == NetEasePlay(songID: 1, start: t0 + 3600))
    }

    private func report(_ songID: Int, position: TimeInterval, at offset: TimeInterval) -> NetEaseLastPlaying.Report {
        NetEaseLastPlaying.Report(songID: songID, position: position, date: t0 + offset)
    }

    @Test func ignoresTheReportOfThePreviousSongRightAfterAChange() {
        let play = NetEasePlay.latest(cacheStarts: [1: t0, 2: t0 + 204], history: nil, report: report(1, position: 203, at: 205))
        #expect(play == NetEasePlay(songID: 2, start: t0 + 204))
    }

    @Test func followsTheReportForASongNothingElseSawStart() {
        // Song 1 replays from the cache while the window is in the background: no file, no history row.
        let play = NetEasePlay.latest(cacheStarts: [1: t0, 2: t0 + 204], history: nil, report: report(1, position: 10, at: 500))
        #expect(play == NetEasePlay(songID: 1, start: t0 + 490))
    }

    @Test func prefersTheCacheStartForTheSameSong() {
        let play = NetEasePlay.latest(cacheStarts: [2: t0], history: nil, report: report(2, position: 80, at: 30))
        #expect(play == NetEasePlay(songID: 2, start: t0))
    }
}

/// Reports modelled on measurements: whole seconds, flushed to disk 0.10–1.12 s after the position passed them.
struct ProgressCalibrationTests {
    /// Feeds reports every 2 s (with the observed jitter) while playing from a wrongly anchored
    /// extrapolation; returns the remaining error after each report.
    private func errors(trueOffset: TimeInterval, reports: Int) -> [TimeInterval] {
        var calibration = ProgressCalibration()
        var anchorError = -trueOffset // extrapolated − true
        // Measured gaps between the true position and the reported whole second.
        let gaps = [0.12, 1.10, 0.14, 0.15, 1.08, 0.11]
        var result: [TimeInterval] = []
        for index in 0..<reports {
            let reported = 30 + Double(index) * 2
            let truePosition = reported + gaps[index % gaps.count]
            if let shift = calibration.correction(extrapolated: truePosition + anchorError, reported: reported) {
                anchorError += shift
            }
            result.append(anchorError)
        }
        return result
    }

    @Test func leavesAConsistentExtrapolationAlone() {
        var calibration = ProgressCalibration()
        #expect(calibration.correction(extrapolated: 30.2, reported: 30) == nil)
        #expect(calibration.correction(extrapolated: 32.1, reported: 31) == nil)
    }

    @Test func followsASeekWithinASecond() {
        for jump in [-45.0, -0.7, 12.0, 90.0] {
            let remaining = errors(trueOffset: jump, reports: 8)
            #expect(abs(remaining[0]) <= 1, "first report after a \(jump)s seek")
            #expect(abs(remaining.last!) <= 0.2)
        }
    }
}

struct NetEaseLastPlayingTests {
    private static let key = Array(")(13daqP@ssw0rd~".utf8)

    private func logEntry(key name: String = "lastPlaying", _ json: String) -> Data {
        let plaintext = Array(json.utf8)
        var ciphertext = [UInt8](repeating: 0, count: plaintext.count + kCCBlockSizeAES128)
        var length = 0
        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
                Self.key, Self.key.count, nil, plaintext, plaintext.count, &ciphertext, ciphertext.count, &length)
        let value = [1] + Array(Data(ciphertext.prefix(length)).base64EncodedString().utf8)
        var varint: [UInt8] = []
        var remaining = value.count
        repeat {
            varint.append(UInt8(remaining & 0x7F) | (remaining > 0x7F ? 0x80 : 0))
            remaining >>= 7
        } while remaining > 0
        return Data(Array("\u{1}\u{1f}_orpheus://orpheus\u{0}\u{1}\(name)".utf8) + varint + value + [0x9A, 0x02])
    }

    @Test func readsTheNewestValueInALogChunk() {
        var chunk = logEntry(#"{"current":18,"resourceDuration":278,"resourceId":"1940334604","trackId":"1940334604"}"#)
        chunk.append(Data("META:orpheus://orpheus".utf8))
        chunk.append(logEntry(#"{"current":20,"resourceDuration":278,"resourceId":"1940334604","trackId":"1940334604"}"#))
        let progress = NetEaseLastPlaying.parse(chunk).progress
        #expect(progress?.songID == 1_940_334_604)
        #expect(progress?.position == 20)
    }

    @Test func skipsTruncatedEntries() {
        let complete = logEntry(#"{"current":18,"resourceId":"1"}"#)
        let second = logEntry(#"{"current":20,"resourceId":"1"}"#)
        let truncated = second.prefix(60)
        let firstRead = NetEaseLastPlaying.parse(complete + truncated)
        #expect(firstRead.progress?.position == 18)
        #expect(firstRead.consumed < complete.count + truncated.count)

        let tail = (complete + second).dropFirst(firstRead.consumed)
        #expect(NetEaseLastPlaying.parse(Data(tail)).progress?.position == 20)
    }

    @Test func decodesPlayingStateAndTrackFromPlayingInfo() {
        let paused = logEntry(
            key: "playingInfo",
            #"{"playingState":1,"resourceTrackId":"1853884220","curTrack":{"id":"1853884220","name":"限定涂鸦","duration":184000,"artists":[{"name":"A"}]}}"#
        )
        let parsed = NetEaseLastPlaying.parse(paused)
        #expect(parsed.isPlaying == false)
        #expect(parsed.track?.netEaseSongID == 1_853_884_220)
        #expect(parsed.track?.title == "限定涂鸦")
        #expect(parsed.track?.artist == "A")
    }

    @Test func reassemblesRecordsCrossing32KiBBlockBoundary() {
        let record = logEntry(
            key: "playingInfo",
            #"{"playingState":2,"resourceTrackId":"2118992","curTrack":{"id":"2118992","name":"Always Getting Over You","duration":252000}}"#
        )
        let fileOffset = 32_768 - 40
        var splitRecord = Data(record.prefix(40))
        splitRecord.append(contentsOf: [0x08, 0x2A, 0x0C, 0xA5, 0x4A, 0x23, 0x04]) // 7-byte LevelDB block header at 32 KiB
        splitRecord.append(record.dropFirst(40))

        let parsed = NetEaseLastPlaying.parse(splitRecord, fileOffset: fileOffset)
        #expect(parsed.isPlaying == true)
        #expect(parsed.track?.netEaseSongID == 2_118_992)
    }

    @Test func tracksPauseAndResumeTransitions() {
        let tracker = NetEaseLastPlaying()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var events: [(Bool, Date)] = []
        tracker.onPlayingChanged = { events.append(($0, $1)) }

        // Start playing at 86s.
        let playChunk = logEntry(#"{"current":86,"resourceId":"1853884220"}"#)
        tracker.apply(NetEaseLastPlaying.parse(playChunk), at: t0, now: t0.addingTimeInterval(0.5))
        #expect(tracker.isPlaying == true)
        #expect(tracker.latest?.position == 86)
        #expect(events.count == 1 && events.last?.0 == true)

        // Pause via playingInfo: keeps position at 86s and transitions to paused.
        let pauseChunk = logEntry(key: "playingInfo", #"{"playingState":1,"resourceTrackId":"1853884220"}"#)
        let tPause = t0.addingTimeInterval(1)
        tracker.apply(NetEaseLastPlaying.parse(pauseChunk), at: tPause, now: tPause.addingTimeInterval(0.2))
        #expect(tracker.isPlaying == false)
        #expect(tracker.latest?.position == 86)
        #expect(events.count == 2 && events.last?.0 == false)

        // Seeking while paused updates the reported position without falsely resuming playback.
        let seekWhilePaused = logEntry(#"{"current":40,"resourceId":"1853884220"}"#)
        let tSeek = t0.addingTimeInterval(5)
        tracker.apply(NetEaseLastPlaying.parse(seekWhilePaused), at: tSeek, now: tSeek.addingTimeInterval(0.2))
        #expect(tracker.isPlaying == false)
        #expect(tracker.latest?.position == 40)
        #expect(events.count == 2)

        // User-initiated resume (noteSongStarted) clears explicit pause so subsequent lastPlaying keeps playing.
        tracker.noteSongStarted()
        #expect(tracker.isPlaying == true)
        let progressAfterResume = logEntry(#"{"current":41,"resourceId":"1853884220"}"#)
        let tProgress = t0.addingTimeInterval(6)
        tracker.apply(NetEaseLastPlaying.parse(progressAfterResume), at: tProgress, now: tProgress.addingTimeInterval(0.2))
        #expect(tracker.isPlaying == true)
        #expect(tracker.latest?.position == 41)

        // Pause again, then resume via playingInfo + lastPlaying.
        tracker.apply(NetEaseLastPlaying.parse(pauseChunk), at: t0.addingTimeInterval(10), now: t0.addingTimeInterval(10.2))
        #expect(tracker.isPlaying == false)

        var resumeChunk = logEntry(#"{"current":42,"resourceId":"1853884220"}"#)
        resumeChunk.append(logEntry(key: "playingInfo", #"{"playingState":2,"resourceTrackId":"1853884220"}"#))
        let tResume = t0.addingTimeInterval(15)
        tracker.apply(NetEaseLastPlaying.parse(resumeChunk), at: tResume, now: tResume.addingTimeInterval(0.2))
        #expect(tracker.isPlaying == true)
        #expect(tracker.latest?.position == 42)
        #expect(events.last?.0 == true)
    }

    @Test func readsTailOfOldLogBeforeSwitchingToNewestLog() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "SoftLiveLogRotation-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let oldLog = tempDir.appending(path: "000001.log")
        let newLog = tempDir.appending(path: "000002.log")

        let initialChunk = logEntry(#"{"current":10,"resourceId":"1853884220"}"#)
        try initialChunk.write(to: oldLog)

        let tracker = NetEaseLastPlaying(directory: tempDir)
        defer { tracker.stopWatching() }
        tracker.followNewestLog()
        #expect(tracker.latest?.songID == 1_853_884_220)
        #expect(tracker.latest?.position == 10)
        #expect(tracker.latestTrack == nil)

        // Append a `playingInfo` record to the tail of `000001.log`, then rotate to `000002.log` with a newer mtime.
        let tailInfo = logEntry(
            key: "playingInfo",
            #"{"playingState":1,"resourceTrackId":"1853884220","curTrack":{"id":"1853884220","name":"旧文件末尾曲目","duration":184000,"artists":[{"name":"A"}]}}"#
        )
        let handle = try FileHandle(forWritingTo: oldLog)
        try handle.seekToEnd()
        try handle.write(contentsOf: tailInfo)
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-1)], ofItemAtPath: oldLog.path)

        let rotatedChunk = logEntry(#"{"current":25,"resourceId":"1853884220"}"#)
        try rotatedChunk.write(to: newLog)
        try FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: newLog.path)

        tracker.followNewestLog()
        #expect(tracker.latestTrack?.title == "旧文件末尾曲目")
        #expect(tracker.isPlaying == false)
        #expect(tracker.latest?.position == 25)
    }
}

struct NetEaseSongTests {
    @Test func decodesHistoryAndWebAPIShapes() throws {
        let history = #"{"id":"2099747804","name":"让风替我对你说","duration":202941,"artists":[{"name":"A"},{"name":"B"}],"album":{"name":"X","picUrl":"http://p2.music.126.net/c.jpg"}}"#
        let playingInfo = #"{"id":"2099747804","name":"让风替我对你说","duration":202941,"artists":[{"name":"A"}],"album":{"name":"X","cover":"http://p1.music.126.net/d.jpg"}}"#

        let fromHistory = try JSONDecoder().decode(NetEaseSong.self, from: Data(history.utf8)).track
        #expect(fromHistory.netEaseSongID == 2_099_747_804)
        #expect(fromHistory.artist == "A / B")
        #expect(fromHistory.duration == 202.941)
        #expect(fromHistory.artworkURL?.absoluteString == "https://p2.music.126.net/c.jpg?param=300y300")

        let fromPlayingInfo = try JSONDecoder().decode(NetEaseSong.self, from: Data(playingInfo.utf8)).track
        #expect(fromPlayingInfo.id == fromHistory.id)
        #expect(fromPlayingInfo.artworkURL?.absoluteString == "https://p1.music.126.net/d.jpg?param=300y300")
    }
}
