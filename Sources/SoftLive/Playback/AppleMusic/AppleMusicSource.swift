import AppKit
import ScriptingBridge

/// Follows Apple Music through its scripting interface.
///
/// Music posts `com.apple.Music.playerInfo` on track changes and play/pause, so those are event driven.
/// It posts nothing when the user seeks, hence a low-frequency position check while playing.
final class AppleMusicSource: PlayerSource {
    let kind = PlayerKind.appleMusic
    var onChange: (() -> Void)?
    private(set) var state: PlaybackState? {
        didSet { if state != oldValue { onChange?() } }
    }

    private static let bundleID = PlayerKind.appleMusic.bundleID
    /// Drift beyond this between the extrapolated and the reported position is treated as a seek.
    private static let seekThreshold: TimeInterval = 0.4
    private static let seekCheckInterval: TimeInterval = 2

    /// Bound to one Music process: unlike a bundle-ID target, events to a quitting process fail
    /// instead of relaunching Music (it posts `playerInfo` while quitting).
    private var music: (pid: pid_t, app: SBApplication)?
    private var runningObserver: RunningAppObserver?
    private var seekCheckTimer: Timer?

    func start() {
        runningObserver = RunningAppObserver(bundleID: Self.bundleID) { [weak self] _ in self?.refresh() }
        DistributedNotificationCenter.default().addObserver(
            forName: .init("com.apple.Music.playerInfo"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    func play() {
        if let music = runningMusic() {
            music.perform(NSSelectorFromString("play"))
            refresh()
            if state != nil { return }
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { [weak self] app, _ in
            guard let pid = app?.processIdentifier else { return }
            Task { @MainActor [weak self] in
                if let sb = SBApplication(processIdentifier: pid) {
                    sb.timeout = 60
                    sb.perform(NSSelectorFromString("play"))
                }
                self?.refresh()
            }
        }
    }

    func pause() {
        guard let music = runningMusic() else { return }
        music.perform(NSSelectorFromString("pause"))
        if var current = state, current.isPlaying {
            current.setPlaying(false, at: .now)
            state = current
        }
    }

    func close() {
        seekCheckTimer?.invalidate()
        seekCheckTimer = nil
        music = nil
        state = nil
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID) {
            app.terminate()
        }
    }

    func artwork(for track: Track) async -> NSImage? {
        guard let music = runningMusic(), state?.track == track,
              let current = music.value(forKey: "currentTrack") as? SBObject,
              let artworks = current.value(forKey: "artworks") as? SBElementArray,
              let first = artworks.firstObject as? SBObject
        else { return nil }
        return first.value(forKey: "data") as? NSImage
    }

    private func refresh() {
        let latest = runningMusic().flatMap(readState)
        if let latest, let current = state, latest.track == current.track, latest.isPlaying == current.isPlaying,
           abs(latest.position() - current.position()) < Self.seekThreshold {
            // Nothing meaningful changed; keep the existing anchor.
        } else {
            state = latest
        }
        updateSeekCheck()
    }

    private func runningMusic() -> SBApplication? {
        guard let pid = runningObserver?.application?.processIdentifier else {
            music = nil
            return nil
        }
        if music?.pid != pid, let app = SBApplication(processIdentifier: pid) {
            app.timeout = 60 // Ticks (1/60 s): never block the main thread on a busy Music for long.
            music = (pid, app)
        }
        return music?.app
    }

    private func updateSeekCheck() {
        let shouldCheck = state?.isPlaying == true
        guard shouldCheck != (seekCheckTimer != nil) else { return }
        seekCheckTimer?.invalidate()
        seekCheckTimer = shouldCheck ? Timer.onMain(after: Self.seekCheckInterval, repeats: true) { [weak self] in self?.refresh() } : nil
    }

    private func readState(_ music: SBApplication) -> PlaybackState? {
        guard let playerState = (music.value(forKey: "playerState") as? NSNumber)?.uint32Value,
              playerState != PlayerStateCode.stopped,
              let current = music.value(forKey: "currentTrack") as? SBObject,
              let id = current.value(forKey: "persistentID") as? String,
              let title = current.value(forKey: "name") as? String
        else { return nil }

        let track = Track(
            id: id,
            title: title,
            artist: current.value(forKey: "artist") as? String ?? "",
            album: current.value(forKey: "album") as? String ?? "",
            duration: current.value(forKey: "duration") as? Double ?? 0,
            source: .appleMusic
        )
        let position = music.value(forKey: "playerPosition") as? Double ?? 0
        return PlaybackState(track: track, isPlaying: playerState == PlayerStateCode.playing, position: position)
    }
}

/// Four-char codes of Music's `player state` enumeration (see `sdef /System/Applications/Music.app`).
private enum PlayerStateCode {
    static let stopped = code("kPSS")
    static let playing = code("kPSP")

    private static func code(_ string: String) -> UInt32 {
        string.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }
}
