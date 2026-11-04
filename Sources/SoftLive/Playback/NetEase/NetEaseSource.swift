import AppKit
import OSLog

/// Follows the NetEase Cloud Music client. It has no scripting interface, and since macOS 15.4
/// MediaRemote no longer answers third-party apps, so SoftLive reads what the client leaves behind:
///
/// - Which song started when: the streaming cache (`NetEasePlayCache`), backed by the play history
///   (`NetEaseHistory`) and the page's own localStorage (`NetEaseLastPlaying`) for songs the cache
///   does not see. Details come from the history row, `playingInfo` or the web API.
/// - Where in the song: extrapolated from the start, and corrected by the page's coarse progress reports
///   whenever they disagree, which is what makes seeking show up (`ProgressCalibration`).
/// - Playing or paused: `playingState` in `playingInfo` (flushed on pause and resume), backed by a
///   liveness timeout on `lastPlaying` (which only writes while playing).
///
/// All of it is event driven.
final class NetEaseSource: PlayerSource {
    let kind = PlayerKind.netEase
    var onChange: (() -> Void)?
    private(set) var state: PlaybackState? {
        didSet { if state != oldValue { onChange?() } }
    }
    private(set) var recentTrack: Track? {
        didSet { if recentTrack != oldValue { onChange?() } }
    }

    private static let log = Logger(subsystem: "dev.softlive.SoftLive", category: "NetEase")

    private let history = NetEaseHistory()
    private let playCache = NetEasePlayCache()
    private let lastPlaying = NetEaseLastPlaying()
    private var runningObserver: RunningAppObserver?
    /// The play `state` describes, or whose song details are being fetched.
    private var currentPlay: NetEasePlay?
    private var lookup: Task<Void, Never>?
    private var launchPlay: Task<Void, Never>?
    private var calibration = ProgressCalibration()

    func start() {
        recentTrack = history.latest()?.track
        let observer = RunningAppObserver(bundleID: NetEaseClient.bundleID) { [weak self] in self?.runningChanged($0) }
        runningObserver = observer
        history.onChange = { [weak self] in self?.reload() }
        playCache.onChange = { [weak self] in self?.reload() }
        lastPlaying.onReport = { [weak self] in self?.reported($0) }
        lastPlaying.onPlayingChanged = { [weak self] in self?.playingChanged($0, at: $1) }
        runningChanged(observer.isRunning)
    }

    func play() {
        let isRunning = runningObserver?.isRunning == true
        launchPlay?.cancel()

        // When the client is already running with a loaded track, `resume` continues from the paused position.
        if isRunning, var current = state {
            Self.log.info("resume requested")
            sendOrpheus(#"{"cmd":"resume"}"#)
            lastPlaying.noteSongStarted()
            if !current.isPlaying {
                current.setPlaying(true, at: .now)
                state = current
            }
            return
        }

        if let track = recentTrack ?? history.latest()?.track ?? lastPlaying.latestTrack {
            let resumePos = lastPlaying.latest?.songID == track.netEaseSongID ? (lastPlaying.latest?.position ?? 0) : 0
            lastPlaying.noteSongStarted()
            state = PlaybackState(track: track, isPlaying: true, position: resumePos, at: .now)
        }
        Self.log.info("play requested (running: \(isRunning, privacy: .public))")

        let resumeCmd = #"{"cmd":"resume"}"#
        guard sendOrpheus(resumeCmd) else { return }
        // On cold start, the initial URL event arrives before the client's CEF page registers
        // its message handler; re-send `resume` (which is idempotent) as the page finishes loading.
        launchPlay = Task { [weak self] in
            for delay in [1.8, 1.4, 1.5] {
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled else { return }
                self.sendOrpheus(resumeCmd)
            }
            self?.launchPlay = nil
            if let self, self.state?.isPlaying == true, !self.lastPlaying.isPlaying {
                self.lastPlaying.noteSongStarted()
            }
        }
    }

    func pause() {
        launchPlay?.cancel()
        launchPlay = nil
        guard runningObserver?.isRunning == true else { return }
        Self.log.info("pause requested")
        sendOrpheus(#"{"cmd":"pause"}"#)
        if var current = state, current.isPlaying {
            current.setPlaying(false, at: .now)
            state = current
        }
    }

    func nextTrack() {
        guard runningObserver?.isRunning == true else { return }
        Self.log.info("next track requested")
        sendOrpheus(#"{"cmd":"next"}"#)
    }

    func close() {
        Self.log.info("close requested")
        runningChanged(false)
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: NetEaseClient.bundleID) {
            if !app.terminate() {
                app.forceTerminate()
            }
        }
    }

    @discardableResult
    private func sendOrpheus(_ json: String) -> Bool {
        let payload = Data(json.utf8).base64EncodedString()
        guard let url = URL(string: "orpheus://\(payload)"),
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: NetEaseClient.bundleID)
        else { return false }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config)
        return true
    }

    func artwork(for track: Track) async -> NSImage? {
        guard let url = track.artworkURL, let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return NSImage(data: data)
    }

    private func runningChanged(_ isRunning: Bool) {
        guard isRunning else {
            launchPlay?.cancel()
            launchPlay = nil
            history.stopWatching()
            playCache.stopWatching()
            lastPlaying.stopWatching()
            lookup?.cancel()
            currentPlay = nil
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
        currentPlay = latest
        lookup?.cancel()
        if let track = [entry?.track, lastPlaying.latestTrack].compactMap({ $0 }).first(where: { $0.netEaseSongID == latest.songID }) {
            publish(track, startedAt: latest.start)
            return
        }
        lookup = Task { [weak self] in
            let track = (try? await NetEaseAPI.track(songID: latest.songID)) ?? nil
            guard let self, !Task.isCancelled, self.currentPlay == latest else { return }
            self.publish(track ?? .unknownNetEaseSong(latest.songID), startedAt: latest.start)
        }
    }

    /// A start of the same song before the current play has reached its end is the same play
    /// (re-dated by a late history row or a report after a pause); its position is left to calibration.
    private func isNewPlay(_ latest: NetEasePlay) -> Bool {
        guard let currentPlay, latest.songID == currentPlay.songID else { return true }
        guard let state, state.track.netEaseSongID == currentPlay.songID else {
            return lookup == nil && (latest != currentPlay || lastPlaying.isPlaying)
        }
        guard latest != currentPlay, state.track.duration > 0 else { return false }
        return state.position(at: latest.start) >= state.track.duration
    }

    private func publish(_ track: Track, startedAt start: Date) {
        if track.title != "网易云音乐" { recentTrack = track }
        let now = Date.now
        let elapsed = now.timeIntervalSince(start)
        Self.log.info("song \(track.id, privacy: .public) \(track.title, privacy: .public) started \(elapsed, format: .fixed(precision: 1))s ago")
        calibration = ProgressCalibration()

        let report = lastPlaying.latest?.songID == track.netEaseSongID ? lastPlaying.latest : nil
        let isPlaying = launchPlay != nil || (report != nil ? lastPlaying.isPlaying : elapsed < NetEaseLastPlaying.pauseTimeout)
        let staleStart = track.duration > 0 && elapsed > track.duration + 5 || launchPlay != nil
        // A start older than its song that is no longer playing is left over from an earlier session.
        if !isPlaying, staleStart {
            state = nil
            return
        }
        if isPlaying { lastPlaying.noteSongStarted() }

        let effectiveStart: Date = if staleStart {
            if let report {
                now.timeIntervalSince(report.date) > NetEaseLastPlaying.pauseTimeout
                    ? now.addingTimeInterval(-report.position)
                    : report.date.addingTimeInterval(-report.position)
            } else {
                now
            }
        } else {
            start
        }
        var newState = PlaybackState(track: track, isPlaying: true, position: 0, at: effectiveStart)
        if !staleStart, let report {
            let extrapolated = newState.position(at: report.date)
            if let shift = calibration.correction(extrapolated: extrapolated, reported: report.position) {
                newState.seek(to: extrapolated + shift, at: report.date)
            }
        }
        if !isPlaying {
            newState.setPlaying(false, at: report?.date ?? now)
        }
        state = newState
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

    private func playingChanged(_ isPlaying: Bool, at date: Date) {
        if !isPlaying, launchPlay != nil { return }
        Self.log.info("playback \(isPlaying ? "resumed" : "paused", privacy: .public)")
        reload()
        guard var current = state, current.isPlaying != isPlaying else { return }
        calibration = ProgressCalibration()
        current.setPlaying(isPlaying, at: date)
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
