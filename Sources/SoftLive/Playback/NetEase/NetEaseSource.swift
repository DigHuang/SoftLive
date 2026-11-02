import AppKit
import OSLog

/// Follows the NetEase Cloud Music client. It has no scripting interface, and since macOS 15.4
/// MediaRemote no longer answers third-party apps, so SoftLive reads what the client leaves behind:
///
/// - Which song started when: the streaming cache (`NetEasePlayCache`), backed by the play history
///   (`NetEaseHistory`) and the page's own report (`NetEaseLastPlaying`) for songs the cache does not see.
///   Details come from the history row or the web API.
/// - Where in the song: extrapolated from the start, and corrected by the page's coarse progress reports
///   whenever they disagree, which is what makes seeking show up (`ProgressCalibration`).
/// - Playing or paused: whether the client is sending audio to an output (`AudioOutputMonitor`).
///
/// All of it is event driven.
@MainActor
final class NetEaseSource: PlayerSource {
    var onChange: (() -> Void)?
    private(set) var state: PlaybackState? {
        didSet { if state != oldValue { onChange?() } }
    }

    private static let log = Logger(subsystem: "dev.softlive.SoftLive", category: "NetEase")

    private let history = NetEaseHistory()
    private let playCache = NetEasePlayCache()
    private let lastPlaying = NetEaseLastPlaying()
    private var audio: AudioOutputMonitor?
    private var runningObserver: RunningAppObserver?
    /// The play `state` describes, or whose song details are being fetched.
    private var play: NetEasePlay?
    private var lookup: Task<Void, Never>?
    private var calibration = ProgressCalibration()

    func start() {
        let observer = RunningAppObserver(bundleID: NetEaseClient.bundleID) { [weak self] in self?.runningChanged($0) }
        runningObserver = observer
        history.onChange = { [weak self] in self?.reload() }
        playCache.onChange = { [weak self] in self?.reload() }
        lastPlaying.onReport = { [weak self] in self?.reported($0) }
        let audio = AudioOutputMonitor(bundleID: NetEaseClient.bundleID) { [weak self] in self?.audioChanged($0) }
        self.audio = audio
        audio.start()
        runningChanged(observer.isRunning)
    }

    func artwork(for track: Track) async -> NSImage? {
        guard let url = track.artworkURL, let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return NSImage(data: data)
    }

    private func runningChanged(_ isRunning: Bool) {
        guard isRunning else {
            history.stopWatching()
            playCache.stopWatching()
            lastPlaying.stopWatching()
            lookup?.cancel()
            play = nil
            state = nil
            return
        }
        history.startWatching()
        playCache.startWatching()
        lastPlaying.startWatching()
        reload()
    }

    private func reload() {
        let entry = history.latest()
        guard let latest = NetEasePlay.latest(cacheStarts: playCache.starts(), history: entry, report: lastPlaying.latest),
              isNewPlay(latest)
        else { return }
        play = latest
        lookup?.cancel()
        if let entry, entry.track.netEaseSongID == latest.songID {
            publish(entry.track, startedAt: latest.start)
            return
        }
        lookup = Task { [weak self] in
            let track = (try? await NetEaseAPI.track(songID: latest.songID)) ?? nil
            guard let self, !Task.isCancelled, self.play == latest else { return }
            self.publish(track ?? .unknownNetEaseSong(latest.songID), startedAt: latest.start)
        }
    }

    /// A start of the same song within its duration is the current play, re-dated by a coarser source;
    /// its position is left to the calibration.
    private func isNewPlay(_ latest: NetEasePlay) -> Bool {
        guard let play, latest.songID == play.songID else { return true }
        guard latest != play else { return false }
        guard let state, state.track.netEaseSongID == play.songID else { return true }
        return state.track.duration > 0 && latest.start.timeIntervalSince(play.start) >= state.track.duration
    }

    private func publish(_ track: Track, startedAt start: Date) {
        let now = Date.now
        let elapsed = now.timeIntervalSince(start)
        Self.log.info("song \(track.id, privacy: .public) \(track.title, privacy: .public) started \(elapsed, format: .fixed(precision: 1))s ago")
        calibration = ProgressCalibration()
        // A start older than its song is left over from an earlier session: nothing is playing.
        if track.duration > 0, elapsed > track.duration + 5 {
            state = nil
            return
        }
        var newState = PlaybackState(track: track, isPlaying: true, position: 0, at: start)
        newState.setPlaying(audio?.isRunning ?? true, at: now)
        state = newState
        if let report = lastPlaying.latest { calibrate(with: report) }
    }

    private func reported(_ report: NetEaseLastPlaying.Report) {
        Self.log.debug("page reports song \(report.songID, privacy: .public) at \(report.position, format: .fixed(precision: 0))s")
        reload()
        calibrate(with: report)
    }

    private func calibrate(with report: NetEaseLastPlaying.Report) {
        guard var current = state, current.track.netEaseSongID == report.songID else { return }
        let extrapolated = current.position(at: report.date)
        guard let shift = calibration.correction(extrapolated: extrapolated, reported: report.position) else { return }
        Self.log.info("position corrected by \(shift, format: .fixed(precision: 1))s to \(extrapolated + shift, format: .fixed(precision: 1))s")
        current.seek(to: extrapolated + shift, at: report.date)
        state = current
    }

    private func audioChanged(_ isRunning: Bool) {
        Self.log.info("audio output \(isRunning ? "started" : "stopped", privacy: .public)")
        guard var current = state else { return }
        current.setPlaying(isRunning)
        state = current
    }
}

/// A song start found in the client's local data.
struct NetEasePlay: Equatable {
    let songID: Int
    let start: Date

    /// Reports lag up to this much behind song changes.
    static let reportLag: TimeInterval = 3

    /// The play in progress: the newest of the streaming-cache starts and the latest history row, or the
    /// page's report when it names a song neither of them saw start.
    ///
    /// A history row may be written long after its song started, stamped with the write time. When the
    /// cache saw that song start no longer than its duration before the row, the cache has the real start.
    static func latest(cacheStarts: [Int: Date], history: NetEaseHistory.Entry?, report: NetEaseLastPlaying.Report? = nil) -> NetEasePlay? {
        let local = latest(cacheStarts: cacheStarts, history: history)
        guard let report else { return local }
        let reported = NetEasePlay(songID: report.songID, start: report.date.addingTimeInterval(-report.position))
        guard let local else { return reported }
        // After a song change the page keeps reporting the previous song for a moment: only a report
        // of another song that started after `local` names a play the cache and history missed.
        return reported.songID != local.songID && reported.start > local.start + reportLag ? reported : local
    }

    private static func latest(cacheStarts: [Int: Date], history: NetEaseHistory.Entry?) -> NetEasePlay? {
        let streamed = cacheStarts.max { $0.value < $1.value }.map { NetEasePlay(songID: $0.key, start: $0.value) }
        guard let history, let songID = history.track.netEaseSongID else { return streamed }

        var start = history.date
        if let cacheStart = cacheStarts[songID], cacheStart <= start,
           start.timeIntervalSince(cacheStart) < history.track.duration + 5 {
            start = cacheStart
        }
        let listed = NetEasePlay(songID: songID, start: start)
        guard let streamed else { return listed }
        return listed.start > streamed.start ? listed : streamed
    }
}

/// Where the NetEase client keeps its data.
enum NetEaseClient {
    static let bundleID = "com.netease.163music"

    /// Current builds are not sandboxed; older App Store builds lived in the container.
    static let dataDirectory: URL? = {
        let library = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library")
        return [
            library.appending(path: "Application Support/com.netease.163music"),
            library.appending(path: "Containers/com.netease.163music/Data"),
        ].first { FileManager.default.fileExists(atPath: $0.appending(path: "Documents/storage").path) }
    }()
}

private extension Track {
    /// Stand-in when the song details cannot be fetched (offline); lyrics are still looked up by ID.
    static func unknownNetEaseSong(_ songID: Int) -> Track {
        Track(id: String(songID), title: "网易云音乐", artist: "", album: "", duration: 0, source: .netEase)
    }
}
