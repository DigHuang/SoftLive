import Darwin
import Foundation

struct CPUTicks: Equatable, Sendable {
    var user: UInt32 = 0
    var system: UInt32 = 0
    var idle: UInt32 = 0
    var nice: UInt32 = 0

    var active: UInt32 { user &+ system &+ nice }
    var total: UInt32 { active &+ idle }

    static func usage(from previous: CPUTicks, to current: CPUTicks) -> Double {
        let activeDelta = current.active &- previous.active
        let totalDelta = current.total &- previous.total
        guard totalDelta > 0 else { return 0 }
        return min(max(Double(activeDelta) / Double(totalDelta), 0), 1)
    }

    static func split(from previous: CPUTicks, to current: CPUTicks) -> (user: Double, system: Double, idle: Double) {
        let userDelta = (current.user &+ current.nice) &- (previous.user &+ previous.nice)
        let sysDelta = current.system &- previous.system
        let totalDelta = current.total &- previous.total
        guard totalDelta > 0 else { return (0, 0, 1) }
        let u = min(max(Double(userDelta) / Double(totalDelta), 0), 1)
        let s = min(max(Double(sysDelta) / Double(totalDelta), 0), 1)
        let i = max(0, 1 - u - s)
        return (u, s, i)
    }
}

final class CPUSampler {
    private var previousTotal: CPUTicks?
    private var previousCores: [CPUTicks] = []
    private var lastBaselineTotal: CPUTicks?
    private var lastBaselineCores: [CPUTicks] = []
    private var cachedUsage: Double = 0
    private var cachedDetails = CPUDetails()
    private let gpuSampler = GPUSampler()
    private let chipName: String
    private let efficiencyCoreCount: Int

    init() {
        let brand = Sysctl.string("machdep.cpu.brand_string")
        self.chipName = brand.isEmpty ? "Apple Silicon" : brand
        self.efficiencyCoreCount = Sysctl.int("hw.perflevel1.logicalcpu")
        self.cachedDetails.chipName = self.chipName
    }

    func sample(includeDetails: Bool = false, topProcesses: [ProcessMetric] = []) -> (usage: Double, details: CPUDetails) {
        guard let cores = Self.readCoreTicks(), !cores.isEmpty else {
            return (cachedUsage, cachedDetails)
        }
        var total = CPUTicks()
        for core in cores {
            total.user &+= core.user
            total.system &+= core.system
            total.idle &+= core.idle
            total.nice &+= core.nice
        }
        guard let prevTotal = previousTotal else {
            previousTotal = total
            previousCores = cores
            return (0, cachedDetails)
        }

        let totalDelta = total.total &- prevTotal.total
        if totalDelta >= 32 || (totalDelta > 0 && lastBaselineTotal == nil) {
            lastBaselineTotal = prevTotal
            lastBaselineCores = previousCores
            previousTotal = total
            previousCores = cores
            cachedUsage = CPUTicks.usage(from: prevTotal, to: total)
        }

        let baseTotal = lastBaselineTotal ?? prevTotal
        let baseCores = lastBaselineCores.isEmpty ? previousCores : lastBaselineCores
        let currentTotal = previousTotal ?? total
        let currentCores = previousCores.isEmpty ? cores : previousCores

        if includeDetails, baseCores.count == currentCores.count {
            let split = CPUTicks.split(from: baseTotal, to: currentTotal)
            let perCore = zip(baseCores, currentCores).map { CPUTicks.usage(from: $0, to: $1) }
            let eCount = min(efficiencyCoreCount, perCore.count)
            let eCores = eCount > 0 ? Array(perCore.prefix(eCount)) : []
            let pCores = eCount > 0 ? Array(perCore.dropFirst(eCount)) : perCore
            let eAvg = eCores.isEmpty ? 0 : eCores.reduce(0, +) / Double(eCores.count)
            let pAvg = pCores.isEmpty ? 0 : pCores.reduce(0, +) / Double(pCores.count)

            var loads = [Double](repeating: 0, count: 1)
            getloadavg(&loads, 1)

            cachedDetails = CPUDetails(
                chipName: chipName,
                userUsage: split.user,
                systemUsage: split.system,
                gpuUsage: gpuSampler.sampleUtilization(),
                efficiencyCores: eCores,
                performanceCores: pCores,
                efficiencyUsage: eAvg,
                performanceUsage: pAvg,
                loadAverage1m: loads[0],
                topProcesses: topProcesses
            )
        }
        return (cachedUsage, cachedDetails)
    }

    private static func readCoreTicks() -> [CPUTicks]? {
        var processorCount: natural_t = 0
        var infoArray: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &processorCount,
            &infoArray,
            &infoCount
        )
        guard result == KERN_SUCCESS, let info = infoArray else { return nil }
        defer {
            let byteCount = vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), byteCount)
        }

        var cores: [CPUTicks] = []
        cores.reserveCapacity(Int(processorCount))
        for core in 0..<Int(processorCount) {
            let base = core * Int(CPU_STATE_MAX)
            cores.append(
                CPUTicks(
                    user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                    system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                    idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                    nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])
                )
            )
        }
        return cores
    }
}
