import AppKit

/// A music player SoftLive can follow.
@MainActor
protocol PlayerSource: AnyObject {
    /// `nil` while the player is not running or has nothing loaded.
    var state: PlaybackState? { get }
    /// Called whenever `state` changes.
    var onChange: (() -> Void)? { get set }
    func start()
    func artwork(for track: Track) async -> NSImage?
}
