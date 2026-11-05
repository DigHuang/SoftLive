import Foundation
import Observation

/// Periodically samples CPU, memory, thermal, and network metrics while enabled in `Preferences`.
@Observable
final class SystemMonitor {
    private static let interval: TimeInterval = 2.0
    private static let historyCapacity = 30

    private(set) var metrics: SystemMetrics = .zero
    private(set) var detailMetrics: SystemMetrics = .zero
    private(set) var activeTab: MonitorTab = .cpu

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
    private var openRefreshTask: Task<Void, Never>?
    private(set) var isDetailActive = false

    init(preferences: Preferences) {
        observeTask = Task { [weak self] in
            for await enabled in Observations({ preferences.showsSystemMonitor }) {
                self?.setEnabled(enabled)
            }
        }
    }

    func setActiveTab(_ tab: MonitorTab) {
        guard activeTab != tab else { return }
        activeTab = tab
        if isDetailActive {
            poll(recordHistory: false)
        }
    }

    func setDetailActive(_ active: Bool) {
        guard isDetailActive != active else { return }
        isDetailActive = active
        openRefreshTask?.cancel()
        openRefreshTask = nil
        if active {
            poll(recordHistory: false)
            openRefreshTask = Task { [weak self] in
                // Wait for the popover window's initial presentation and CoreAnimation
                // commit to finish, then reset the process tick baseline so one-time
                // window-opening work is never counted into SoftLive's CPU percentage.
                try? await Task.sleep(for: .milliseconds(60))
                guard let self, !Task.isCancelled, self.isDetailActive else { return }
                self.processSampler.captureBaseline()
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, self.isDetailActive, self.activeTab == .cpu else { return }
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
        openRefreshTask?.cancel()
        openRefreshTask = nil
        guard enabled else {
            cpuHistory.removeAll(keepingCapacity: true)
            memoryHistory.removeAll(keepingCapacity: true)
            thermalHistory.removeAll(keepingCapacity: true)
            excludedPIDs.removeAll()
            metrics = .zero
            detailMetrics = .zero
            return
        }
        processSampler.captureBaseline()
        poll(recordHistory: true)
        let scheduled = Timer.onMain(after: Self.interval, repeats: true) { [weak self] in
            self?.poll(recordHistory: true)
        }
        scheduled.tolerance = 0.25
        timer = scheduled
    }

    private func poll(recordHistory: Bool) {
        let needCPUDetails = isDetailActive && activeTab == .cpu
        let needRAMDetails = isDetailActive && activeTab == .ram
        let needTMPDetails = isDetailActive && activeTab == .tmp

        let processes = isDetailActive
            ? processSampler.sample(
                totalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
                limit: 10,
                excludingPIDs: excludedPIDs,
                needCPU: needCPUDetails,
                needMemory: needRAMDetails
            )
            : (topCPU: [], topMemory: [])
        let cpu = cpuSampler.sample(includeDetails: needCPUDetails, topProcesses: processes.topCPU)
        let memory = MemorySampler.sample(includeDetails: needRAMDetails, topProcesses: processes.topMemory)
        let thermal = thermalSampler.sample(includeDetails: needTMPDetails)
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
        if isDetailActive, detailMetrics != next {
            detailMetrics = next
        }
    }

    private func appendHistory(_ buffer: inout [Double], value: Double) {
        if buffer.count >= Self.historyCapacity {
            buffer.removeFirst(buffer.count - Self.historyCapacity + 1)
        }
        buffer.append(min(max(value, 0), 1))
    }
}
