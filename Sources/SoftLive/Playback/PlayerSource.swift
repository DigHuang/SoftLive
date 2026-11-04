import AppKit

/// A music player SoftLive can follow.
protocol PlayerSource: AnyObject {
    var kind: PlayerKind { get }
    /// `nil` while the player is not running or has nothing loaded.
    var state: PlaybackState? { get }
    /// Most recently known track even when `state` is `nil`, if available locally.
    var recentTrack: Track? { get }
    /// Called whenever `state` or `recentTrack` changes.
    var onChange: (() -> Void)? { get set }
    func start()
    func play()
    func pause()
    func close()
    func artwork(for track: Track) async -> NSImage?
}

extension PlayerSource {
    var recentTrack: Track? { state?.track }
    func play() {}
    func pause() {}
    func close() {}
}
