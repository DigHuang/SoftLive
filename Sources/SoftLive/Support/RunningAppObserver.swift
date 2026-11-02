import AppKit

/// Tracks whether an app with a given bundle identifier is running.
@MainActor
final class RunningAppObserver {
    let bundleID: String
    private var tokens: [NSObjectProtocol] = []

    init(bundleID: String, onChange: @escaping @MainActor (_ isRunning: Bool) -> Void) {
        self.bundleID = bundleID
        let center = NSWorkspace.shared.notificationCenter
        let events = [
            (NSWorkspace.didLaunchApplicationNotification, true),
            (NSWorkspace.didTerminateApplicationNotification, false),
        ]
        for (name, isRunning) in events {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == bundleID else { return }
                MainActor.assumeIsolated { onChange(isRunning) }
            })
        }
    }

    var application: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first { !$0.isTerminated }
    }

    var isRunning: Bool { application != nil }
}
