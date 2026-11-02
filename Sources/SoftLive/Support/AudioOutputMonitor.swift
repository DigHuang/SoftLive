import CoreAudio
import Foundation

/// Whether an app is sending audio to an output device right now, read from Core Audio's
/// per-process objects (public since macOS 14.2, no permission needed). Listener driven: nothing is polled.
@MainActor
final class AudioOutputMonitor {
    private(set) var isRunning = false

    private let bundleID: String
    private let onChange: @MainActor (_ isRunning: Bool) -> Void
    private var processListListener: AudioObjectPropertyListenerBlock?
    /// Matching processes (an app and its helpers) and their output listeners.
    private var outputListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]

    init(bundleID: String, onChange: @escaping @MainActor (_ isRunning: Bool) -> Void) {
        self.bundleID = bundleID
        self.onChange = onChange
    }

    func start() {
        guard processListListener == nil else { return }
        // Processes appear in the list once they connect to Core Audio.
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.processesChanged() }
        }
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        guard AudioObjectAddPropertyListenerBlock(Self.system, &address, .main, listener) == noErr else { return }
        processListListener = listener
        processesChanged()
    }

    private func processesChanged() {
        let processes = Set(Self.processObjects().filter { Self.bundleID(of: $0)?.hasPrefix(bundleID) == true })
        var address = Self.address(kAudioProcessPropertyIsRunningOutput)
        for (process, listener) in outputListeners where !processes.contains(process) {
            AudioObjectRemovePropertyListenerBlock(process, &address, .main, listener)
            outputListeners[process] = nil
        }
        for process in processes where outputListeners[process] == nil {
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.update() }
            }
            if AudioObjectAddPropertyListenerBlock(process, &address, .main, listener) == noErr {
                outputListeners[process] = listener
            }
        }
        update()
    }

    private func update() {
        let running = outputListeners.keys.contains(where: Self.isRunningOutput)
        guard running != isRunning else { return }
        isRunning = running
        onChange(running)
    }

    // MARK: Core Audio properties

    private static let system = AudioObjectID(kAudioObjectSystemObject)

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func processObjects() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects
    }

    private static func bundleID(of process: AudioObjectID) -> String? {
        var address = address(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func isRunningOutput(_ process: AudioObjectID) -> Bool {
        var address = address(kAudioProcessPropertyIsRunningOutput)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr && value != 0
    }
}
