import Foundation
import Observation

/// Periodically samples CPU, memory, thermal, and network metrics while enabled in `Preferences`.
@Observable
final class SystemMonitor {
    private static let interval: TimeInterval = 2.0
    private static let historyCapacity = 30

    private(set) var metrics: SystemMetrics = .zero

    private let cpuSampler = CPUSampler()
    private let thermalSampler = ThermalSampler()
    private let networkSampler = NetworkSampler()
    private let processSampler = ProcessSampler()
    private var cpuHistory: [Double] = []
    private var memoryHistory: [Double] = []
    private var thermalHistory: [Double] = []
    private var excludedPIDs: Set<pid_t> = []
    private var timer: Timer?
    private var observeTask: Task<Void, Never>?
    private var isDetailActive = false

    init(preferences: Preferences) {
        observeTask = Task { [weak self] in
            for await enabled in Observations({ preferences.showsSystemMonitor }) {
                self?.setEnabled(enabled)
            }
        }
    }

    func setDetailActive(_ active: Bool) {
        guard isDetailActive != active else { return }
        isDetailActive = active
        if active {
            poll(recordHistory: false)
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(320))
                guard let self, self.isDetailActive else { return }
                self.poll(recordHistory: false)
            }
        }
    }

    @discardableResult
    func terminateProcess(pid: pid_t, force: Bool = false) -> Bool {
        let ok = ProcessSampler.terminate(pid: pid, force: force)
        excludedPIDs.insert(pid)
        poll(recordHistory: false)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            if !force, kill(pid, 0) == 0 {
                _ = ProcessSampler.terminate(pid: pid, force: true)
            }
            try? await Task.sleep(for: .milliseconds(250))
            guard let self else { return }
            self.excludedPIDs.remove(pid)
            if self.isDetailActive {
                self.poll(recordHistory: false)
            }
        }
        return ok
    }

    private func setEnabled(_ enabled: Bool) {
        timer?.invalidate()
        timer = nil
        guard enabled else {
            cpuHistory.removeAll(keepingCapacity: true)
            memoryHistory.removeAll(keepingCapacity: true)
            thermalHistory.removeAll(keepingCapacity: true)
            excludedPIDs.removeAll()
            metrics = .zero
            return
        }
        poll(recordHistory: true)
        let scheduled = Timer.onMain(after: Self.interval, repeats: true) { [weak self] in
            self?.poll(recordHistory: true)
        }
        scheduled.tolerance = 0.25
        timer = scheduled
    }

    private func poll(recordHistory: Bool) {
        let processes = isDetailActive
            ? processSampler.sample(
                totalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
                limit: 10,
                excludingPIDs: excludedPIDs
            )
            : (topCPU: [], topMemory: [])
        let cpu = cpuSampler.sample(includeDetails: isDetailActive, topProcesses: processes.topCPU)
        let memory = MemorySampler.sample(includeDetails: isDetailActive, topProcesses: processes.topMemory)
        let thermal = thermalSampler.sample(includeDetails: isDetailActive)
        let network = networkSampler.sample()

        if recordHistory || cpuHistory.isEmpty {
            appendHistory(&cpuHistory, value: cpu.usage)
            appendHistory(&memoryHistory, value: memory.usage)
            appendHistory(&thermalHistory, value: SystemMetrics.thermalProgress(thermal.celsius))
        }

        let next = SystemMetrics(
            cpuUsage: cpu.usage,
            memoryUsage: memory.usage,
            temperatureCelsius: thermal.celsius,
            uploadBytesPerSec: network.uploadBytesPerSec,
            downloadBytesPerSec: network.downloadBytesPerSec,
            memoryPressure: memory.pressure,
            cpuHistory: cpuHistory,
            memoryHistory: memoryHistory,
            thermalHistory: thermalHistory,
            cpuDetails: cpu.details,
            memoryDetails: memory.details,
            thermalDetails: thermal.details
        )
        if metrics != next {
            metrics = next
        }
    }

    private func appendHistory(_ buffer: inout [Double], value: Double) {
        if buffer.count >= Self.historyCapacity {
            buffer.removeFirst(buffer.count - Self.historyCapacity + 1)
        }
        buffer.append(min(max(value, 0), 1))
    }
}
