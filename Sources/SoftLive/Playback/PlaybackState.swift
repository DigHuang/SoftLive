import AppKit

enum PlayerKind: String, CaseIterable, Sendable {
    case netEase
    case appleMusic

    var displayName: String {
        switch self {
        case .appleMusic: "Apple Music"
        case .netEase: "网易云音乐"
        }
    }

    var bundleID: String {
        switch self {
        case .appleMusic: "com.apple.Music"
        case .netEase: "com.netease.163music"
        }
    }

    private static var iconCache: [PlayerKind: NSImage] = [:]

    var icon: NSImage? {
        if let cached = Self.iconCache[self] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        Self.iconCache[self] = image
        return image
    }
}

struct Track: Equatable, Sendable {
    /// Identifier unique within `source` (Apple Music persistent ID / NetEase song ID).
    let id: String
    let title: String
    let artist: String
    let album: String
    /// Seconds; 0 when unknown.
    let duration: TimeInterval
    let source: PlayerKind
    /// Remote cover image, when the player exposes one as a URL.
    var artworkURL: URL? = nil

    /// Tracks coming from the NetEase client carry their song ID, so lyrics can be fetched exactly.
    var netEaseSongID: Int? { source == .netEase ? Int(id) : nil }
}

/// The playback position is never polled continuously: it is extrapolated from an anchor
/// that sources only update when something actually happens (track change, play/pause, seek).
struct PlaybackState: Equatable, Sendable {
    var track: Track
    private(set) var isPlaying: Bool
    private(set) var anchorPosition: TimeInterval
    private(set) var anchorDate: Date

    init(track: Track, isPlaying: Bool, position: TimeInterval, at date: Date = .now) {
        self.track = track
        self.isPlaying = isPlaying
        self.anchorPosition = position
        self.anchorDate = date
    }

    func position(at date: Date = .now) -> TimeInterval {
        isPlaying ? anchorPosition + date.timeIntervalSince(anchorDate) : anchorPosition
    }

    mutating func setPlaying(_ playing: Bool, at date: Date = .now) {
        guard playing != isPlaying else { return }
        anchorPosition = position(at: date)
        anchorDate = date
        isPlaying = playing
    }

    mutating func seek(to position: TimeInterval, at date: Date = .now) {
        anchorPosition = position
        anchorDate = date
    }
}
