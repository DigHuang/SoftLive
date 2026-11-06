import Darwin
import Foundation

final class ProcessSampler {
    private struct ProcessMeta {
        let name: String
        let bundlePath: String?
    }

    private var previousCPUTicks: [pid_t: UInt64] = [:]
    private var previousInstant: ContinuousClock.Instant?
    private var cachedTopCPU: [ProcessMetric] = []
    private var cachedTopMemory: [ProcessMetric] = []
    private var metaCache: [pid_t: ProcessMeta] = [:]
    private let timebaseNumer: Double
    private let timebaseDenom: Double

    init() {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        timebaseNumer = Double(max(tb.numer, 1))
        timebaseDenom = Double(max(tb.denom, 1))
    }

    /// Snapshots per-process CPU ticks without sorting or resolving metadata.
    /// Called right after popover presentation finishes so one-time window-opening
    /// rendering ticks are not attributed to SoftLive's ongoing CPU percentage.
    func captureBaseline(now: ContinuousClock.Instant = .now) {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return }
        var pids = [pid_t](repeating: 0, count: Int(count * 2))
        let byteSize = Int32(pids.count * MemoryLayout<pid_t>.stride)
        let actual = Int(proc_listallpids(&pids, byteSize))
        guard actual > 0 else { return }

        var nextCPUTicks: [pid_t: UInt64] = [:]
        nextCPUTicks.reserveCapacity(actual)
        for idx in 0..<actual {
            let pid = pids[idx]
            guard pid > 0 else { continue }
            var usage = rusage_info_v4()
            let res = withUnsafeMutablePointer(to: &usage) { ptr in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rPtr in
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, rPtr)
                }
            }
            guard res == 0 else { continue }
            nextCPUTicks[pid] = usage.ri_user_time &+ usage.ri_system_time
        }
        previousCPUTicks = nextCPUTicks
        previousInstant = now
    }

    func isCPUBaselineStale(at now: ContinuousClock.Instant = .now) -> Bool {
        guard let previousInstant else { return true }
        let d = previousInstant.duration(to: now)
        let seconds = Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
        return seconds > 3.5
    }

    func sample(
        now: ContinuousClock.Instant = .now,
        totalMemoryBytes: UInt64,
        limit: Int = 10,
        excludingPIDs: Set<pid_t> = [],
        needCPU: Bool = true,
        needMemory: Bool = true
    ) -> (topCPU: [ProcessMetric], topMemory: [ProcessMetric]) {
        guard needCPU || needMemory else {
            return (cachedTopCPU, cachedTopMemory)
        }
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return (cachedTopCPU, cachedTopMemory) }
        var pids = [pid_t](repeating: 0, count: Int(count * 2))
        let byteSize = Int32(pids.count * MemoryLayout<pid_t>.stride)
        let actual = Int(proc_listallpids(&pids, byteSize))
        guard actual > 0 else { return (cachedTopCPU, cachedTopMemory) }

        let elapsedSeconds: Double
        if let previousInstant {
            let d = previousInstant.duration(to: now)
            elapsedSeconds = Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
        } else {
            elapsedSeconds = 0
        }

        let canComputeCPU = elapsedSeconds > 0.05
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

            if needCPU, totalTicks > 0 {
                let pct: Double
                if canComputeCPU, let prevTicks = previousCPUTicks[pid], totalTicks >= prevTicks {
                    let deltaNs = Double(totalTicks - prevTicks) * timebaseNumer / timebaseDenom
                    pct = (deltaNs / (elapsedSeconds * 1_000_000_000.0)) * 100.0
                } else {
                    pct = 0
                }
                cpuCandidates.append((pid, pct, totalTicks))
            }

            if needMemory {
                let footprint = usage.ri_phys_footprint
                if footprint > 1_048_576 {
                    memCandidates.append((pid, footprint))
                }
            }
        }

        if !metaCache.isEmpty {
            metaCache = metaCache.filter { nextCPUTicks[$0.key] != nil }
        }

        if canComputeCPU || previousInstant == nil {
            previousCPUTicks = nextCPUTicks
            previousInstant = now
        }

        if needCPU {
            if canComputeCPU || cachedTopCPU.isEmpty {
                cpuCandidates.sort {
                    if abs($0.percent - $1.percent) > 0.05 {
                        return $0.percent > $1.percent
                    }
                    return $0.totalTicks > $1.totalTicks
                }
                cachedTopCPU = cpuCandidates.prefix(limit).map { item -> ProcessMetric in
                    let meta = resolveMeta(for: item.pid)
                    return ProcessMetric(
                        pid: item.pid,
                        name: meta.name,
                        bundlePath: meta.bundlePath,
                        valueText: String(format: "%.1f%%", item.percent),
                        fraction: min(max(item.percent / 100.0, 0), 1)
                    )
                }
            } else if !excludingPIDs.isEmpty {
                cachedTopCPU.removeAll { excludingPIDs.contains($0.pid) }
            }
        }

        if needMemory {
            memCandidates.sort { $0.bytes > $1.bytes }
            let safeTotalMem = Double(max(totalMemoryBytes, 1))
            cachedTopMemory = memCandidates.prefix(limit).map { item -> ProcessMetric in
                let meta = resolveMeta(for: item.pid)
                return ProcessMetric(
                    pid: item.pid,
                    name: meta.name,
                    bundlePath: meta.bundlePath,
                    valueText: SystemMetrics.formatBytes(item.bytes),
                    fraction: min(max(Double(item.bytes) / (safeTotalMem * 0.4), 0), 1)
                )
            }
        }

        return (cachedTopCPU, cachedTopMemory)
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
        if let cached = metaCache[pid] {
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
        if metaCache.count > 256 {
            metaCache.removeAll(keepingCapacity: true)
        }
        metaCache[pid] = meta
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
