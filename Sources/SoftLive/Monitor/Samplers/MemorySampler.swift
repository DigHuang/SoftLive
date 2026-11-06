import Darwin
import Foundation

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
        let rawPressure = Sysctl.int("kern.memorystatus_vm_pressure_level")
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
