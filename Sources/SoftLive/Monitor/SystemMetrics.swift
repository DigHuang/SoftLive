import Foundation

/// Immutable snapshot of system resource metrics sampled by `SystemMonitor`.
struct SystemMetrics: Equatable, Sendable {
    var cpuUsage: Double = 0
    var memoryUsage: Double = 0
    var temperatureCelsius: Double?
    var uploadBytesPerSec: UInt64 = 0
    var downloadBytesPerSec: UInt64 = 0
    var memoryPressure: MemoryPressureLevel = .normal
    var cpuHistory: [Double] = []
    var memoryHistory: [Double] = []
    var thermalHistory: [Double] = []
    var cpuDetails = CPUDetails()
    var memoryDetails = MemoryDetails()
    var thermalDetails = ThermalDetails()

    static let zero = SystemMetrics()

    /// Normalized 0.0...1.0 progress for a `0...100 °C` thermal gauge bar.
    static func thermalProgress(_ celsius: Double?) -> Double {
        guard let celsius else { return 0 }
        return min(max(celsius / 100.0, 0), 1)
    }

    static func formatPercentage(_ fraction: Double) -> String {
        let clamped = min(max(fraction, 0), 1)
        return "\(Int((clamped * 100).rounded()))%"
    }

    static func formatTemperature(_ celsius: Double?) -> String {
        guard let celsius else { return "--°" }
        return "\(Int(celsius.rounded()))°"
    }

    static func formatTemperatureDetail(_ celsius: Double?) -> String {
        guard let celsius else { return "-- °C" }
        return String(format: "%.1f °C", celsius)
    }

    static func formatWatts(_ watts: Double?) -> String {
        guard let watts, watts >= 0 else { return "-- W" }
        return String(format: "%.1f W", watts)
    }

    static func formatBytes(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1.0 {
            return String(format: "%.1f GB", gb)
        }
        let mb = Double(bytes) / 1_048_576
        if mb >= 1.0 {
            return String(format: "%.0f MB", mb)
        }
        return "0 MB"
    }

    static func formatCompactBytes(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1.0 {
            return String(format: "%.1fG", gb)
        }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.0fM", max(mb, 0))
    }

    static func formatRate(_ bytesPerSec: UInt64) -> String {
        "\(formatCompactRate(bytesPerSec))/s"
    }

    static func formatCompactRate(_ bytesPerSec: UInt64) -> String {
        if bytesPerSec < 1024 {
            return "0 B"
        }
        let kb = Double(bytesPerSec) / 1024
        if kb < 1000 {
            return "\(Int(kb.rounded())) KB"
        }
        let mb = kb / 1024
        if mb < 10 {
            return String(format: "%.1f MB", mb)
        }
        if mb < 1000 {
            return "\(Int(mb.rounded())) MB"
        }
        let gb = mb / 1024
        return String(format: "%.1f GB", gb)
    }
}

struct ProcessMetric: Equatable, Sendable, Identifiable {
    let pid: Int32
    let name: String
    let bundlePath: String?
    let valueText: String
    let fraction: Double

    var id: Int32 { pid }
}

struct CPUDetails: Equatable, Sendable {
    var chipName: String = ""
    var userUsage: Double = 0
    var systemUsage: Double = 0
    var gpuUsage: Double = 0
    var efficiencyCores: [Double] = []
    var performanceCores: [Double] = []
    var efficiencyUsage: Double = 0
    var performanceUsage: Double = 0
    var loadAverage1m: Double = 0
    var topProcesses: [ProcessMetric] = []
}

enum MemoryPressureLevel: Int, Equatable, Sendable {
    case normal = 1
    case warning = 2
    case critical = 4

    var label: String {
        switch self {
        case .normal: "压力正常"
        case .warning: "压力偏高"
        case .critical: "压力吃紧"
        }
    }
}

struct MemoryDetails: Equatable, Sendable {
    var totalBytes: UInt64 = 0
    var usedBytes: UInt64 = 0
    var appBytes: UInt64 = 0
    var wiredBytes: UInt64 = 0
    var compressedBytes: UInt64 = 0
    var freeBytes: UInt64 = 0
    var swapUsedBytes: UInt64 = 0
    var pressure: MemoryPressureLevel = .normal
    var topProcesses: [ProcessMetric] = []
}

struct ThermalDetails: Equatable, Sendable {
    var maxDieCelsius: Double?
    var minDieCelsius: Double?
    var nandCelsius: Double?
    var batteryCelsius: Double?
    var boardAverageCelsius: Double?
    var systemPowerWatts: Double?
    var fanRPM: Int?
    var fanMaxRPM: Int?
}
