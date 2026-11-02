import CommonCrypto
import Foundation
import Testing
@testable import SoftLive

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
        let play = NetEasePlay.latest(cacheStarts: [1: t0, 2: t0 + 110], history: row(1, at: 108, duration: 110))
        #expect(play == NetEasePlay(songID: 2, start: t0 + 110))
    }

    @Test func trustsTheHistoryForSongsTheCacheDoesNotSee() {
        // Song 3 is a download; song 1 replays from a cache file made by an earlier play.
        #expect(NetEasePlay.latest(cacheStarts: [1: t0], history: row(3, at: 50, duration: 200))
            == NetEasePlay(songID: 3, start: t0 + 50))
        #expect(NetEasePlay.latest(cacheStarts: [1: t0], history: row(1, at: 3600, duration: 200))
            == NetEasePlay(songID: 1, start: t0 + 3600))
    }

    @Test func isEmptyWithoutData() {
        #expect(NetEasePlay.latest(cacheStarts: [:], history: nil) == nil)
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

/// Reports modelled on measurements: whole seconds, readable 0.66–1.68 s after the position passed them.
struct ProgressCalibrationTests {
    /// Feeds reports every 2 s (with the observed jitter) while playing from a wrongly anchored
    /// extrapolation; returns the remaining error after each report.
    private func errors(trueOffset: TimeInterval, reports: Int) -> [TimeInterval] {
        var calibration = ProgressCalibration()
        var anchorError = -trueOffset // extrapolated − true
        // Measured gaps between the true position and the reported whole second.
        let gaps = [0.67, 1.66, 0.69, 0.70, 1.63, 0.66]
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
        #expect(calibration.correction(extrapolated: 30.7, reported: 30) == nil)
        #expect(calibration.correction(extrapolated: 32.7, reported: 31) == nil)
    }

    @Test func followsASeekWithinASecond() {
        for jump in [-45.0, 12.0, 90.0] {
            let remaining = errors(trueOffset: jump, reports: 8)
            #expect(abs(remaining[0]) <= 1, "first report after a \(jump)s seek")
            #expect(abs(remaining.last!) <= 1)
        }
    }
}

struct NetEaseLastPlayingTests {
    private static let key = Array(")(13daqP@ssw0rd~".utf8)

    private func logEntry(_ json: String) -> Data {
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
        return Data(Array("\u{1}\u{1f}_orpheus://orpheus\u{0}\u{1}lastPlaying".utf8) + varint + value + [0x9A, 0x02])
    }

    @Test func readsTheNewestValueInALogChunk() {
        var chunk = logEntry(#"{"current":18,"resourceDuration":278,"resourceId":"1940334604","trackId":"1940334604"}"#)
        chunk.append(Data("META:orpheus://orpheus".utf8))
        chunk.append(logEntry(#"{"current":20,"resourceDuration":278,"resourceId":"1940334604","trackId":"1940334604"}"#))
        let value = NetEaseLastPlaying.lastValue(in: chunk)
        #expect(value?.songID == 1_940_334_604)
        #expect(value?.position == 20)
    }

    @Test func skipsTruncatedEntries() {
        let complete = logEntry(#"{"current":18,"resourceId":"1"}"#)
        let truncated = logEntry(#"{"current":20,"resourceId":"1"}"#).prefix(60)
        #expect(NetEaseLastPlaying.lastValue(in: complete + truncated)?.position == 18)
    }
}

struct NetEaseSongTests {
    @Test func decodesHistoryAndWebAPIShapes() throws {
        let history = #"{"id":"2099747804","name":"让风替我对你说","duration":202941,"artists":[{"name":"A"},{"name":"B"}],"album":{"name":"X","picUrl":"http://p2.music.126.net/c.jpg"}}"#
        let web = #"{"id":2099747804,"name":"让风替我对你说","duration":202941,"artists":[{"name":"A"}]}"#

        let fromHistory = try JSONDecoder().decode(NetEaseSong.self, from: Data(history.utf8)).track
        #expect(fromHistory.netEaseSongID == 2_099_747_804)
        #expect(fromHistory.artist == "A / B")
        #expect(fromHistory.duration == 202.941)
        #expect(fromHistory.artworkURL?.absoluteString == "https://p2.music.126.net/c.jpg?param=300y300")

        let fromWeb = try JSONDecoder().decode(NetEaseSong.self, from: Data(web.utf8)).track
        #expect(fromWeb.id == fromHistory.id)
        #expect(fromWeb.artworkURL == nil)
    }
}
