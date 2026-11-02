import AppKit
import Observation

/// Picks the player to follow, loads its lyrics and keeps the current line in sync.
@MainActor
@Observable
final class AppModel {
    enum LyricsStatus { case idle, loading, loaded, notFound }

    private(set) var playback: PlaybackState?
    private(set) var lyrics: Lyrics?
    private(set) var lyricsStatus = LyricsStatus.idle
    private(set) var currentIndex: Int?
    private(set) var artwork: NSImage?
    /// Manual correction for the current track, in seconds; positive shows lyrics earlier.
    var offset: TimeInterval = 0 {
        didSet { syncCurrentLine() }
    }

    @ObservationIgnored private let sources: [any PlayerSource] = [AppleMusicSource(), NetEaseSource()]
    @ObservationIgnored private var activeSource: (any PlayerSource)?
    @ObservationIgnored private let lyricsService = LyricsService()
    @ObservationIgnored private var lyricsTask: Task<Void, Never>?
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    @ObservationIgnored private var lineTimer: Timer?

    func start() {
        for source in sources {
            source.onChange = { [weak self, unowned source] in self?.sourceDidChange(source) }
            source.start()
        }
    }

    // MARK: Display

    var isPlaying: Bool { playback?.isPlaying == true }

    /// Position in the lyrics' timeline at `date`, offset included. Drives word-level progress.
    func lyricsTime(at date: Date) -> TimeInterval {
        (playback?.position(at: date) ?? 0) + offset
    }

    /// The line `distance` lines away from the current one (before the first line, 1 is the first line).
    func line(_ distance: Int) -> LyricLine? {
        guard let lyrics else { return nil }
        let index = (currentIndex ?? -1) + distance
        guard lyrics.lines.indices.contains(index) else { return nil }
        return lyrics.lines[index]
    }

    var currentLine: LyricLine? { line(0) }

    /// Main text: the current lyric line, or the track while there is none.
    var headline: String {
        if let text = currentLine?.text, !text.isEmpty { return text }
        guard let track = playback?.track else { return "" }
        return track.artist.isEmpty ? track.title : "\(track.title) - \(track.artist)"
    }

    /// Secondary text: translation, else the next line, else the lyrics status.
    var subline: String? {
        if let translation = currentLine?.translation { return translation }
        switch lyricsStatus {
        case .loading: return "正在搜索歌词…"
        case .notFound: return "暂无歌词"
        case .idle: return nil
        case .loaded: return line(1)?.text
        }
    }

    // MARK: Sync

    private func sourceDidChange(_ source: any PlayerSource) {
        // A player that starts playing takes over; otherwise stay with the current one while it has a track.
        if source.state?.isPlaying == true {
            activeSource = source
        } else if activeSource?.state == nil {
            activeSource = sources.first { $0.state?.isPlaying == true } ?? sources.first { $0.state != nil }
        }

        let newPlayback = activeSource?.state
        let trackChanged = newPlayback?.track != playback?.track
        playback = newPlayback
        if trackChanged {
            loadLyrics(for: newPlayback?.track)
            loadArtwork(for: newPlayback?.track)
            offset = 0 // Also re-syncs the current line.
        } else {
            syncCurrentLine()
        }
    }

    private func loadLyrics(for track: Track?) {
        lyricsTask?.cancel()
        lyrics = nil
        guard let track else {
            lyricsStatus = .idle
            return
        }
        lyricsStatus = .loading
        lyricsTask = Task { [weak self, lyricsService] in
            let result = await lyricsService.lyrics(for: track)
            guard let self, !Task.isCancelled, self.playback?.track == track else { return }
            self.lyrics = result
            self.lyricsStatus = result == nil ? .notFound : .loaded
            self.syncCurrentLine()
        }
    }

    private func loadArtwork(for track: Track?) {
        artworkTask?.cancel()
        artwork = nil
        guard let track, let source = activeSource else { return }
        artworkTask = Task { [weak self] in
            let image = await source.artwork(for: track)
            guard let self, !Task.isCancelled, self.playback?.track == track else { return }
            self.artwork = image
        }
    }

    /// Updates the current line and arms a one-shot timer for the next change — no per-frame polling.
    private func syncCurrentLine() {
        lineTimer?.invalidate()
        lineTimer = nil
        guard let playback, let lyrics else {
            currentIndex = nil
            return
        }

        let position = playback.position() + offset
        let index = lyrics.lineIndex(at: position)
        if index != currentIndex { currentIndex = index }

        let next = (index ?? -1) + 1
        guard playback.isPlaying, lyrics.lines.indices.contains(next) else { return }
        let delay = max(0.01, lyrics.lines[next].time - position)
        lineTimer = Timer.onMain(after: delay) { [weak self] in self?.syncCurrentLine() }
    }
}
