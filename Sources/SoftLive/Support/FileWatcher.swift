import Foundation

/// Calls `onChange` once a burst of writes to a file (or of entry changes in a directory) settles.
/// Follows the path when the item is replaced.
final class FileWatcher {
    private let url: URL
    private let debounce: TimeInterval
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var pendingNotify: DispatchWorkItem?

    init(url: URL, debounce: TimeInterval = 0.15, onChange: @escaping () -> Void) {
        self.url = url
        self.debounce = debounce
        self.onChange = onChange
    }

    func start() {
        guard source == nil else { return }
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .delete, .rename], queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.changed() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
        pendingNotify?.cancel()
    }

    private func changed() {
        if let events = source?.data, !events.isDisjoint(with: [.delete, .rename]) {
            // Replaced: watch the new item at the same path.
            stop()
            start()
        }
        pendingNotify?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.onChange() }
        }
        pendingNotify = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}
