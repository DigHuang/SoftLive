import Darwin
import Foundation
import IOKit

// MARK: - CPU Sampler

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
    private var cachedDetails = CPUDetails()
    private let chipName: String
    private let performanceCoreCount: Int
    private let efficiencyCoreCount: Int

    init() {
        let brand = Self.sysctlString("machdep.cpu.brand_string")
        self.chipName = brand.isEmpty ? "Apple Silicon" : brand
        self.performanceCoreCount = Self.sysctlInt("hw.perflevel0.logicalcpu")
        self.efficiencyCoreCount = Self.sysctlInt("hw.perflevel1.logicalcpu")
        self.cachedDetails.chipName = self.chipName
    }

    func sample(includeDetails: Bool = false, topProcesses: [ProcessMetric] = []) -> (usage: Double, details: CPUDetails) {
        guard let cores = Self.readCoreTicks(), !cores.isEmpty else {
            return (0, cachedDetails)
        }
        var total = CPUTicks()
        for core in cores {
            total.user &+= core.user
            total.system &+= core.system
            total.idle &+= core.idle
            total.nice &+= core.nice
        }
        defer {
            previousTotal = total
            previousCores = cores
        }
        guard let previousTotal else { return (0, cachedDetails) }
        let usage = CPUTicks.usage(from: previousTotal, to: total)

        if includeDetails, previousCores.count == cores.count {
            let split = CPUTicks.split(from: previousTotal, to: total)
            let perCore = zip(previousCores, cores).map { CPUTicks.usage(from: $0, to: $1) }
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
                gpuUsage: GPUSampler.sampleUtilization(),
                efficiencyCores: eCores,
                performanceCores: pCores,
                efficiencyUsage: eAvg,
                performanceUsage: pAvg,
                loadAverage1m: loads[0],
                topProcesses: topProcesses
            )
        }
        return (usage, cachedDetails)
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

    fileprivate static func sysctlInt(_ name: String) -> Int {
        var value = 0
        var size = MemoryLayout<Int>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return 0 }
        return value
    }

    fileprivate static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

// MARK: - GPU Sampler (IOAccelerator)

enum GPUSampler {
    static func sampleUtilization() -> Double {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOAccelerator"),
            &iterator
        ) == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(iterator) }

        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            defer {
                IOObjectRelease(entry)
                entry = IOIteratorNext(iterator)
            }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any],
                  let perf = dict["PerformanceStatistics"] as? [String: Any],
                  let util = perf["Device Utilization %"] as? Int
            else { continue }
            return min(max(Double(util) / 100.0, 0), 1)
        }
        return 0
    }
}

// MARK: - Process Sampler (proc_pid_rusage)

final class ProcessSampler {
    private struct ProcessMeta {
        let name: String
        let bundlePath: String?
    }

    private var previousCPUTicks: [pid_t: UInt64] = [:]
    private var previousInstant: ContinuousClock.Instant?
    private var metaCache: [pid_t: ProcessMeta] = [:]
    private let timebaseNumer: Double
    private let timebaseDenom: Double

    init() {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        timebaseNumer = Double(max(tb.numer, 1))
        timebaseDenom = Double(max(tb.denom, 1))
    }

    func sample(
        now: ContinuousClock.Instant = .now,
        totalMemoryBytes: UInt64,
        limit: Int = 10,
        excludingPIDs: Set<pid_t> = []
    ) -> (topCPU: [ProcessMetric], topMemory: [ProcessMetric]) {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return ([], []) }
        var pids = [pid_t](repeating: 0, count: Int(count * 2))
        let byteSize = Int32(pids.count * MemoryLayout<pid_t>.stride)
        let actual = Int(proc_listallpids(&pids, byteSize))
        guard actual > 0 else { return ([], []) }

        let elapsedSeconds: Double
        if let previousInstant {
            let d = previousInstant.duration(to: now)
            elapsedSeconds = Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
        } else {
            elapsedSeconds = 0
        }

        var nextCPUTicks: [pid_t: UInt64] = [:]
        nextCPUTicks.reserveCapacity(actual)
        var cpuCandidates: [(pid: pid_t, percent: Double, totalTicks: UInt64)] = []
        var memCandidates: [(pid: pid_t, bytes: UInt64)] = []

        for idx in 0..<actual {
            let pid = pids[idx]
            guard pid > 0, !excludingPIDs.contains(pid) else { continue }
            var usage = rusage_info_v4()
            let res = withUnsafeMutablePointer(to: &usage) { ptr in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rPtr in
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, rPtr)
                }
            }
            guard res == 0 else { continue }

            let totalTicks = usage.ri_user_time &+ usage.ri_system_time
            nextCPUTicks[pid] = totalTicks

            let pct: Double
            if elapsedSeconds > 0.05, let prevTicks = previousCPUTicks[pid], totalTicks >= prevTicks {
                let deltaNs = Double(totalTicks - prevTicks) * timebaseNumer / timebaseDenom
                pct = (deltaNs / (elapsedSeconds * 1_000_000_000.0)) * 100.0
            } else {
                pct = 0
            }
            if totalTicks > 0 {
                cpuCandidates.append((pid, pct, totalTicks))
            }

            let footprint = usage.ri_phys_footprint
            if footprint > 1_048_576 {
                memCandidates.append((pid, footprint))
            }
        }

        previousCPUTicks = nextCPUTicks
        previousInstant = now

        cpuCandidates.sort {
            if abs($0.percent - $1.percent) > 0.05 {
                return $0.percent > $1.percent
            }
            return $0.totalTicks > $1.totalTicks
        }
        memCandidates.sort { $0.bytes > $1.bytes }

        let topCPU = cpuCandidates.prefix(limit).map { item -> ProcessMetric in
            let meta = resolveMeta(for: item.pid)
            return ProcessMetric(
                pid: item.pid,
                name: meta.name,
                bundlePath: meta.bundlePath,
                valueText: String(format: "%.1f%%", item.percent),
                fraction: min(max(item.percent / 100.0, 0), 1)
            )
        }

        let safeTotalMem = Double(max(totalMemoryBytes, 1))
        let topMem = memCandidates.prefix(limit).map { item -> ProcessMetric in
            let meta = resolveMeta(for: item.pid)
            return ProcessMetric(
                pid: item.pid,
                name: meta.name,
                bundlePath: meta.bundlePath,
                valueText: SystemMetrics.formatBytes(item.bytes),
                fraction: min(max(Double(item.bytes) / (safeTotalMem * 0.4), 0), 1)
            )
        }

        return (topCPU, topMem)
    }

    static func terminate(pid: pid_t, force: Bool = false) -> Bool {
        guard pid > 1, pid != getpid() else { return false }
        let signal = force ? SIGKILL : SIGTERM
        if kill(pid, signal) == 0 || errno == ESRCH {
            return true
        }
        return false
    }

    private static let genericCLIBinaries: Set<String> = [
        "node", "bun", "deno", "python", "python3", "ruby", "java", "php", "perl", "sh", "bash", "zsh",
    ]

    private func resolveMeta(for pid: pid_t) -> ProcessMeta {
        if let cached = metaCache[pid], !Self.genericCLIBinaries.contains(cached.name) {
            return cached
        }
        var pathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let pathLen = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
        let fullPath = pathLen > 0
            ? String(decoding: pathBuf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            : ""

        var nameBuf = [CChar](repeating: 0, count: 256)
        proc_name(pid, &nameBuf, UInt32(nameBuf.count))
        var name = String(decoding: nameBuf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        if name.isEmpty, !fullPath.isEmpty {
            name = (fullPath as NSString).lastPathComponent
        }

        // Enrich CLI / Node / Python / Electron processes using KERN_PROCARGS2 and working directory
        if Self.genericCLIBinaries.contains(name.lowercased()) || name.hasPrefix("language_server") {
            name = Self.enrichCLIName(pid: pid, fallbackName: name)
        } else {
            name = Self.cleanHelperName(name)
        }

        if name.isEmpty {
            name = "PID \(pid)"
        }

        var bundlePath: String?
        if let range = fullPath.range(of: ".app/") {
            bundlePath = String(fullPath[..<range.upperBound].dropLast())
        } else if !fullPath.isEmpty {
            bundlePath = fullPath
        }

        let meta = ProcessMeta(name: name, bundlePath: bundlePath)
        if !Self.genericCLIBinaries.contains(name.lowercased()) {
            if metaCache.count > 256 {
                metaCache.removeAll(keepingCapacity: true)
            }
            metaCache[pid] = meta
        }
        return meta
    }

    private static func enrichCLIName(pid: pid_t, fallbackName: String) -> String {
        if fallbackName.hasPrefix("language_server") {
            return "language_server"
        }
        let args = readProcessArgs(pid: pid)
        let cwdName = readWorkingDirectoryName(pid: pid)

        var baseTitle = fallbackName
        if let arg0 = args.first {
            let trimmed0 = arg0.trimmingCharacters(in: .whitespacesAndNewlines)
            let last0 = (trimmed0 as NSString).lastPathComponent
            // Detect custom process.title (e.g. "next-server (v16.3.6)")
            if !genericCLIBinaries.contains(last0.lowercased()), !trimmed0.hasPrefix("/") {
                if let paren = trimmed0.range(of: " (v") {
                    baseTitle = String(trimmed0[..<paren.lowerBound])
                } else {
                    baseTitle = trimmed0
                }
            } else if let scriptArg = args.dropFirst().first(where: { !$0.hasPrefix("-") }) {
                if let scriptHint = extractScriptHint(from: scriptArg) {
                    baseTitle = "\(fallbackName) · \(scriptHint)"
                }
            }
        }

        if let cwdName, !baseTitle.contains(cwdName) {
            return "\(baseTitle) (\(cwdName))"
        }
        return baseTitle
    }

    private static func extractScriptHint(from arg: String) -> String? {
        if arg.contains("/next/dist/bin/next") || arg.hasSuffix("/.bin/next") {
            return "next"
        }
        if arg.contains("/turbo/") || arg.hasSuffix("/turbo") {
            return "turbo"
        }
        if arg.contains("/vite/") || arg.hasSuffix("/vite.js") {
            return "vite"
        }
        if arg.contains("/webpack/") {
            return "webpack"
        }
        if arg.contains("/ts-node") || arg.contains("/tsx") {
            return "tsx"
        }
        let last = (arg as NSString).lastPathComponent
        guard !last.isEmpty, last != "index.js", last != "cli.js", last.count <= 24 else {
            return nil
        }
        return (last as NSString).deletingPathExtension
    }

    private static func cleanHelperName(_ raw: String) -> String {
        var result = raw
        result = result.replacingOccurrences(of: " Helper (Renderer)", with: " (Renderer)")
        result = result.replacingOccurrences(of: " Helper (GPU)", with: " (GPU)")
        result = result.replacingOccurrences(of: " Helper (Plugin)", with: " (Plugin)")
        return result
    }

    private static func readProcessArgs(pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: Int = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4, size <= 65536 else {
            return []
        }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else {
            return []
        }
        var argc: Int32 = 0
        _ = withUnsafeMutableBytes(of: &argc) { dst in
            buffer.prefix(4).copyBytes(to: dst)
        }
        guard argc > 0 else { return [] }

        var offset = 4
        while offset < size && buffer[offset] != 0 { offset += 1 }
        while offset < size && buffer[offset] == 0 { offset += 1 }

        var args: [String] = []
        let maxArgs = Int(min(argc, 6))
        args.reserveCapacity(maxArgs)
        while offset < size && args.count < maxArgs {
            let start = offset
            while offset < size && buffer[offset] != 0 { offset += 1 }
            if offset > start {
                let str = String(decoding: buffer[start..<offset], as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !str.isEmpty {
                    args.append(str)
                }
            }
            offset += 1
        }
        return args
    }

    private static func readWorkingDirectoryName(pid: pid_t) -> String? {
        var vnodeInfo = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        let ret = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnodeInfo, size)
        guard ret == size else { return nil }
        let path = withUnsafePointer(to: &vnodeInfo.pvi_cdir.vip_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { cPtr in
                String(cString: cPtr)
            }
        }
        guard !path.isEmpty, path != "/" else { return nil }
        let last = (path as NSString).lastPathComponent
        let ignored: Set<String> = ["/", "Users", NSUserName(), "Documents", "Desktop", "Downloads"]
        guard !last.isEmpty, !ignored.contains(last) else { return nil }
        return last
    }
}

// MARK: - Memory Sampler

enum MemorySampler {
    static func sample(
        includeDetails: Bool = false,
        topProcesses: [ProcessMetric] = []
    ) -> (usage: Double, pressure: MemoryPressureLevel, details: MemoryDetails) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPointer in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, .normal, MemoryDetails()) }
        let total = ProcessInfo.processInfo.physicalMemory
        guard total > 0 else { return (0, .normal, MemoryDetails()) }
        let pageSize = UInt64(getpagesize())
        let used = usedBytes(stats: stats, pageSize: pageSize)
        let usage = min(max(Double(used) / Double(total), 0), 1)
        let rawPressure = CPUSampler.sysctlInt("kern.memorystatus_vm_pressure_level")
        let pressure = MemoryPressureLevel(rawValue: rawPressure) ?? .normal

        guard includeDetails else {
            return (usage, pressure, MemoryDetails(totalBytes: total, usedBytes: used, pressure: pressure))
        }

        let appPages = stats.internal_page_count > stats.purgeable_count
            ? UInt64(stats.internal_page_count - stats.purgeable_count)
            : 0
        let appBytes = appPages * pageSize
        let wiredBytes = UInt64(stats.wire_count) * pageSize
        let compressedBytes = UInt64(stats.compressor_page_count) * pageSize
        let freeBytes = total > used ? (total - used) : 0

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        _ = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)

        let details = MemoryDetails(
            totalBytes: total,
            usedBytes: used,
            appBytes: appBytes,
            wiredBytes: wiredBytes,
            compressedBytes: compressedBytes,
            freeBytes: freeBytes,
            swapUsedBytes: swap.xsu_used,
            pressure: pressure,
            topProcesses: topProcesses
        )
        return (usage, pressure, details)
    }

    /// Matches macOS Activity Monitor "Memory Used": App Memory + Wired + Compressed.
    static func usedBytes(stats: vm_statistics64, pageSize: UInt64) -> UInt64 {
        let appPages = stats.internal_page_count > stats.purgeable_count
            ? UInt64(stats.internal_page_count - stats.purgeable_count)
            : 0
        let usedPages = appPages + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        return usedPages * pageSize
    }
}

// MARK: - AppleSMC Power & Fan Sampler

final class SMCSampler {
    private struct SMCKeyData {
        var key: UInt32 = 0
        var vers: (UInt8, UInt8, UInt8, UInt8, UInt16) = (0, 0, 0, 0, 0)
        var pLimitData: (UInt16, UInt16, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0)
        var keyInfoDataSize: UInt32 = 0
        var keyInfoDataType: UInt32 = 0
        var keyInfoDataAttributes: UInt8 = 0
        var keyInfoPad: (UInt8, UInt8, UInt8) = (0, 0, 0)
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var pad2: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
        ) = (
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0
        )
    }

    private var connection: io_connect_t = 0
    private var fanMaxRPM: Int?

    init() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        if service != 0 {
            _ = IOServiceOpen(service, mach_task_self_, 0, &connection)
            IOObjectRelease(service)
        }
        fanMaxRPM = readFloat("F0Mx").map { Int($0.rounded()) }
    }

    isolated deinit {
        if connection != 0 {
            IOServiceClose(connection)
        }
    }

    func sample() -> (systemWatts: Double?, fanRPM: Int?, fanMax: Int?) {
        guard connection != 0 else { return (nil, nil, nil) }
        let sysW = readFloat("PSTR").map { Double($0) }
        let rpm = readFloat("F0Ac").map { max(0, Int($0.rounded())) }
        return (sysW, rpm, fanMaxRPM)
    }

    private func readFloat(_ key: String) -> Float? {
        guard connection != 0 else { return nil }
        var input = SMCKeyData()
        var output = SMCKeyData()
        input.key = key.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
        input.data8 = 9 // kSMCGetKeyInfo
        var outSize = MemoryLayout<SMCKeyData>.size
        guard IOConnectCallStructMethod(
            connection, 2, &input, MemoryLayout<SMCKeyData>.size, &output, &outSize
        ) == KERN_SUCCESS, output.keyInfoDataSize == 4 else {
            return nil
        }
        input.keyInfoDataSize = 4
        input.data8 = 5 // kSMCReadKey
        guard IOConnectCallStructMethod(
            connection, 2, &input, MemoryLayout<SMCKeyData>.size, &output, &outSize
        ) == KERN_SUCCESS else {
            return nil
        }
        return withUnsafeBytes(of: &output.bytes) { $0.load(as: Float.self) }
    }
}

// MARK: - Thermal Sampler (Apple Silicon IOHIDEventSystemClient)

final class ThermalSampler {
    private typealias CreateClientFn = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias SetMatchingFn = @convention(c) (CFTypeRef, CFDictionary) -> Void
    private typealias CopyServicesFn = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias CopyPropertyFn = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEventFn = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias GetFloatValueFn = @convention(c) (CFTypeRef, Int32) -> Double

    private static let temperatureEventType: Int64 = 15
    private static let temperatureLevelField: Int32 = 15 << 16
    private static let sampleStride = 3

    private struct NamedSensor {
        let name: String
        let label: String
        let order: Int
        let service: CFTypeRef
    }

    private let client: CFTypeRef?
    private let copyEvent: CopyEventFn?
    private let getFloatValue: GetFloatValueFn?
    private let smcSampler = SMCSampler()
    private var primarySensor: CFTypeRef?
    private var dieSensors: [NamedSensor] = []
    private var nandSensor: CFTypeRef?
    private var batterySensor: CFTypeRef?
    private var boardSensors: [CFTypeRef] = []
    private var cachedTemperature: Double?
    private var cachedDetails = ThermalDetails()
    private var tickCount = 0

    init() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
              let createSym = dlsym(handle, "IOHIDEventSystemClientCreate"),
              let matchSym = dlsym(handle, "IOHIDEventSystemClientSetMatching"),
              let servicesSym = dlsym(handle, "IOHIDEventSystemClientCopyServices"),
              let propSym = dlsym(handle, "IOHIDServiceClientCopyProperty"),
              let eventSym = dlsym(handle, "IOHIDServiceClientCopyEvent"),
              let floatSym = dlsym(handle, "IOHIDEventGetFloatValue")
        else {
            client = nil
            copyEvent = nil
            getFloatValue = nil
            return
        }

        let create = unsafeBitCast(createSym, to: CreateClientFn.self)
        let setMatching = unsafeBitCast(matchSym, to: SetMatchingFn.self)
        let copyServices = unsafeBitCast(servicesSym, to: CopyServicesFn.self)
        let copyProperty = unsafeBitCast(propSym, to: CopyPropertyFn.self)
        let copyEventFn = unsafeBitCast(eventSym, to: CopyEventFn.self)
        let getFloatFn = unsafeBitCast(floatSym, to: GetFloatValueFn.self)

        self.copyEvent = copyEventFn
        self.getFloatValue = getFloatFn

        guard let created = create(kCFAllocatorDefault)?.takeRetainedValue() else {
            client = nil
            return
        }
        client = created

        let matching: [String: Int] = [
            "PrimaryUsagePage": 0xFF00,
            "PrimaryUsage": 0x0005,
        ]
        setMatching(created, matching as CFDictionary)

        guard let services = copyServices(created)?.takeRetainedValue() as? [AnyObject] else { return }
        var seenDieNames = Set<String>()
        for service in services {
            let serviceRef = service as CFTypeRef
            guard let nameRef = copyProperty(serviceRef, "Product" as CFString)?.takeRetainedValue(),
                  let name = nameRef as? String,
                  !name.contains("tcal"),
                  readCelsius(from: serviceRef) != nil
            else { continue }

            if Self.isCoreSensorName(name) {
                if primarySensor == nil {
                    primarySensor = serviceRef
                }
                if name.hasPrefix("PMU tdie"), seenDieNames.insert(name).inserted {
                    let digits = Int(name.dropFirst("PMU tdie".count)) ?? 99
                    dieSensors.append(
                        NamedSensor(
                            name: name,
                            label: "核心 #\(digits)",
                            order: digits,
                            service: serviceRef
                        )
                    )
                }
            } else if name.hasPrefix("NAND") && nandSensor == nil {
                nandSensor = serviceRef
            } else if name == "gas gauge battery" && batterySensor == nil {
                batterySensor = serviceRef
            } else if name.contains("tdev") {
                boardSensors.append(serviceRef)
            }
        }
        dieSensors.sort { $0.order < $1.order }
        if let firstDie = dieSensors.first?.service {
            primarySensor = firstDie
        }
    }

    func sample(includeDetails: Bool = false) -> (celsius: Double?, details: ThermalDetails) {
        if includeDetails {
            return sampleDetailed()
        }
        guard let primarySensor else { return (nil, cachedDetails) }
        if cachedTemperature == nil || tickCount.isMultiple(of: Self.sampleStride) {
            cachedTemperature = readCelsius(from: primarySensor)
        }
        tickCount &+= 1
        return (cachedTemperature, cachedDetails)
    }

    private func sampleDetailed() -> (celsius: Double?, details: ThermalDetails) {
        let dieValues = dieSensors.compactMap { readCelsius(from: $0.service) }
        let avgDie = dieValues.isEmpty
            ? primarySensor.flatMap(readCelsius(from:))
            : dieValues.reduce(0, +) / Double(dieValues.count)
        let maxDie = dieValues.max() ?? avgDie
        let minDie = dieValues.min() ?? avgDie

        let nand = nandSensor.flatMap(readCelsius(from:))
        let battery = batterySensor.flatMap(readCelsius(from:))
        let boardValues = boardSensors.compactMap(readCelsius(from:))
        let boardAvg = boardValues.isEmpty ? nil : boardValues.reduce(0, +) / Double(boardValues.count)
        let smc = smcSampler.sample()

        cachedTemperature = avgDie
        cachedDetails = ThermalDetails(
            maxDieCelsius: maxDie,
            minDieCelsius: minDie,
            nandCelsius: nand,
            batteryCelsius: battery,
            boardAverageCelsius: boardAvg,
            systemPowerWatts: smc.systemWatts,
            fanRPM: smc.fanRPM,
            fanMaxRPM: smc.fanMax
        )
        return (avgDie, cachedDetails)
    }

    private func readCelsius(from service: CFTypeRef) -> Double? {
        guard let copyEvent, let getFloatValue,
              let event = copyEvent(service, Self.temperatureEventType, 0, 0)?.takeRetainedValue()
        else { return nil }
        let celsius = getFloatValue(event, Self.temperatureLevelField)
        guard celsius >= 10, celsius <= 130 else { return nil }
        return celsius
    }

    static func isCoreSensorName(_ name: String) -> Bool {
        if name.contains("tcal") { return false }
        return name.hasPrefix("PMU tdie")
            || name.hasPrefix("PMU2 tdie")
            || name.hasPrefix("eACC MTR Temp Sensor")
            || name.hasPrefix("pACC MTR Temp Sensor")
    }
}

// MARK: - Network Sampler

struct NetworkCounters: Equatable, Sendable {
    var receivedBytes: UInt64 = 0
    var sentBytes: UInt64 = 0

    static func rates(
        from previous: NetworkCounters,
        to current: NetworkCounters,
        elapsedSeconds: Double
    ) -> (uploadBytesPerSec: UInt64, downloadBytesPerSec: UInt64) {
        guard elapsedSeconds > 0,
              current.receivedBytes >= previous.receivedBytes,
              current.sentBytes >= previous.sentBytes
        else { return (0, 0) }
        let downDelta = current.receivedBytes - previous.receivedBytes
        let upDelta = current.sentBytes - previous.sentBytes
        return (
            uploadBytesPerSec: UInt64((Double(upDelta) / elapsedSeconds).rounded()),
            downloadBytesPerSec: UInt64((Double(downDelta) / elapsedSeconds).rounded())
        )
    }
}

final class NetworkSampler {
    private var previousCounters: NetworkCounters?
    private var previousInstant: ContinuousClock.Instant?

    func sample(now: ContinuousClock.Instant = .now) -> (uploadBytesPerSec: UInt64, downloadBytesPerSec: UInt64) {
        let current = Self.readCounters()
        defer {
            previousCounters = current
            previousInstant = now
        }
        guard let previousCounters, let previousInstant else { return (0, 0) }
        let elapsed = previousInstant.duration(to: now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
        return NetworkCounters.rates(from: previousCounters, to: current, elapsedSeconds: seconds)
    }

    static func isPhysicalInterfaceName(_ name: String) -> Bool {
        name.hasPrefix("en") || name.hasPrefix("pdp_ip") || name.hasPrefix("bridge")
    }

    private static func readCounters() -> NetworkCounters {
        var firstAddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddr) == 0, let head = firstAddr else {
            return NetworkCounters()
        }
        defer { freeifaddrs(head) }

        var total = NetworkCounters()
        var seenInterfaces = Set<String>()
        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let addr = cursor {
            defer { cursor = addr.pointee.ifa_next }
            let flags = Int32(addr.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0,
                  (flags & IFF_RUNNING) != 0,
                  (flags & IFF_LOOPBACK) == 0,
                  let sa = addr.pointee.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_LINK),
                  let data = addr.pointee.ifa_data
            else { continue }

            let name = String(cString: addr.pointee.ifa_name)
            guard isPhysicalInterfaceName(name), seenInterfaces.insert(name).inserted else { continue }

            let networkData = data.assumingMemoryBound(to: if_data.self).pointee
            total.receivedBytes &+= UInt64(networkData.ifi_ibytes)
            total.sentBytes &+= UInt64(networkData.ifi_obytes)
        }
        return total
    }
}
