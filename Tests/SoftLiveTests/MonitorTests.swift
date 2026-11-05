import AppKit
import Darwin
import Testing
@testable import SoftLive

@Suite struct SystemMetricsTests {
    @Test func formatsPercentagesRatesBytesAndThermalProgress() {
        #expect(SystemMetrics.formatPercentage(0) == "0%")
        #expect(SystemMetrics.formatPercentage(0.184) == "18%")
        #expect(SystemMetrics.formatPercentage(0.836) == "84%")
        #expect(SystemMetrics.formatPercentage(1.2) == "100%")

        #expect(SystemMetrics.formatTemperature(nil) == "--°")
        #expect(SystemMetrics.formatTemperature(41.2) == "41°")
        #expect(SystemMetrics.formatTemperatureDetail(nil) == "-- °C")
        #expect(SystemMetrics.formatTemperatureDetail(41.24) == "41.2 °C")

        #expect(SystemMetrics.formatWatts(nil) == "-- W")
        #expect(SystemMetrics.formatWatts(-1) == "-- W")
        #expect(SystemMetrics.formatWatts(18.52) == "18.5 W")

        #expect(MemoryPressureLevel.normal.label == "压力正常")
        #expect(MemoryPressureLevel.warning.label == "压力偏高")
        #expect(MemoryPressureLevel.critical.label == "压力吃紧")

        #expect(SystemMetrics.thermalProgress(nil) == 0)
        #expect(SystemMetrics.thermalProgress(0) == 0)
        #expect(abs(SystemMetrics.thermalProgress(45) - 0.45) < 0.001)
        #expect(SystemMetrics.thermalProgress(100) == 1)
        #expect(SystemMetrics.thermalProgress(120) == 1)

        #expect(SystemMetrics.formatBytes(0) == "0 MB")
        #expect(SystemMetrics.formatBytes(512 * 1_048_576) == "512 MB")
        #expect(SystemMetrics.formatBytes(20 * 1_073_741_824) == "20.0 GB")

        #expect(SystemMetrics.formatRate(512) == "0 B/s")
        #expect(SystemMetrics.formatRate(128 * 1024) == "128 KB/s")
        #expect(SystemMetrics.formatRate(UInt64(2.4 * 1_048_576)) == "2.4 MB/s")
        #expect(SystemMetrics.formatRate(25 * 1_048_576) == "25 MB/s")

        #expect(SystemMetrics.formatCompactRate(512) == "0 B")
        #expect(SystemMetrics.formatCompactRate(621 * 1024) == "621 KB")
        #expect(SystemMetrics.formatCompactRate(UInt64(2.4 * 1_048_576)) == "2.4 MB")
        #expect(SystemMetrics.formatCompactRate(25 * 1_048_576) == "25 MB")
    }

    @Test func rendersColoredStatusBarImageWithVerticalBars() {
        let metrics = SystemMetrics(
            cpuUsage: 0.24,
            memoryUsage: 0.78,
            temperatureCelsius: 44.0,
            uploadBytesPerSec: 64 * 1024,
            downloadBytesPerSec: 3 * 1_048_576
        )
        let image = MonitorStatusBar.renderImage(for: metrics)
        #expect(!image.isTemplate)
        #expect(image.size == NSSize(width: 52, height: 22))
        #expect(image.tiffRepresentation != nil)

        // Crossing color thresholds within the same integer bar-height step must produce distinct DisplayKeys.
        let cpuBelow = MonitorStatusBar.DisplayKey(metrics: SystemMetrics(cpuUsage: 0.74))
        let cpuAbove = MonitorStatusBar.DisplayKey(metrics: SystemMetrics(cpuUsage: 0.76))
        #expect(cpuBelow.cpuBarSteps == cpuAbove.cpuBarSteps)
        #expect(cpuBelow != cpuAbove)

        let ramBelow = MonitorStatusBar.DisplayKey(metrics: SystemMetrics(memoryUsage: 0.87))
        let ramAbove = MonitorStatusBar.DisplayKey(metrics: SystemMetrics(memoryUsage: 0.89))
        #expect(ramBelow.ramBarSteps == ramAbove.ramBarSteps)
        #expect(ramBelow != ramAbove)

        let tmpBelow = MonitorStatusBar.DisplayKey(metrics: SystemMetrics(temperatureCelsius: 54.0))
        let tmpAbove = MonitorStatusBar.DisplayKey(metrics: SystemMetrics(temperatureCelsius: 55.5))
        #expect(tmpBelow.tmpBarSteps == tmpAbove.tmpBarSteps)
        #expect(tmpBelow != tmpAbove)
    }

    @Test @MainActor func togglesDetailActiveModeCleanly() {
        let suiteName = "dev.softlive.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let prefs = Preferences(defaults: defaults)
        let monitor = SystemMonitor(preferences: prefs)
        #expect(!monitor.isDetailActive)

        monitor.setDetailActive(true)
        #expect(monitor.isDetailActive)
        #expect(monitor.activeTab == .cpu)

        monitor.setActiveTab(.ram)
        #expect(monitor.activeTab == .ram)
        #expect(monitor.detailMetrics.memoryDetails.totalBytes > 0)

        monitor.setActiveTab(.tmp)
        #expect(monitor.activeTab == .tmp)

        monitor.setDetailActive(false)
        #expect(!monitor.isDetailActive)
    }
}

@Suite struct SystemSamplersTests {
    @Test func calculatesCPUUsageAndSplitFromTickDeltas() {
        let prev = CPUTicks(user: 1000, system: 500, idle: 3500, nice: 0)
        let next = CPUTicks(user: 1150, system: 550, idle: 4300, nice: 0)
        // active delta = 200, idle delta = 800, total = 1000 -> 20%
        #expect(abs(CPUTicks.usage(from: prev, to: next) - 0.20) < 0.0001)
        let split = CPUTicks.split(from: prev, to: next)
        #expect(abs(split.user - 0.15) < 0.0001)
        #expect(abs(split.system - 0.05) < 0.0001)
        #expect(abs(split.idle - 0.80) < 0.0001)

        // Zero delta returns 0
        #expect(CPUTicks.usage(from: next, to: next) == 0)

        // UInt32 wraparound handling
        let nearMax = CPUTicks(user: UInt32.max - 50, system: 0, idle: UInt32.max - 50, nice: 0)
        let wrapped = CPUTicks(user: 49, system: 0, idle: 49, nice: 0)
        #expect(abs(CPUTicks.usage(from: nearMax, to: wrapped) - 0.50) < 0.0001)
    }

    @Test func calculatesActivityMonitorMemoryUsage() {
        var stats = vm_statistics64()
        stats.internal_page_count = 1000
        stats.purgeable_count = 200
        stats.wire_count = 300
        stats.compressor_page_count = 400
        // (1000 - 200) + 300 + 400 = 1500 pages
        let bytes = MemorySampler.usedBytes(stats: stats, pageSize: 16384)
        #expect(bytes == 1500 * 16384)
    }

    @Test func filtersAppleSiliconThermalSensorNames() {
        #expect(ThermalSampler.isCoreSensorName("PMU tdie1"))
        #expect(ThermalSampler.isCoreSensorName("PMU2 tdie8"))
        #expect(ThermalSampler.isCoreSensorName("eACC MTR Temp Sensor0"))
        #expect(ThermalSampler.isCoreSensorName("pACC MTR Temp Sensor3"))
        #expect(!ThermalSampler.isCoreSensorName("PMU tcal"))
        #expect(!ThermalSampler.isCoreSensorName("PMU2 tcal"))
        #expect(!ThermalSampler.isCoreSensorName("PMU tdev1"))
        #expect(!ThermalSampler.isCoreSensorName("gas gauge battery"))
    }

    @Test func filtersPhysicalNetworkInterfacesAndComputesRates() {
        #expect(NetworkSampler.isPhysicalInterfaceName("en0"))
        #expect(NetworkSampler.isPhysicalInterfaceName("en5"))
        #expect(NetworkSampler.isPhysicalInterfaceName("pdp_ip0"))
        #expect(!NetworkSampler.isPhysicalInterfaceName("lo0"))
        #expect(!NetworkSampler.isPhysicalInterfaceName("utun4"))
        #expect(!NetworkSampler.isPhysicalInterfaceName("awdl0"))
        #expect(!NetworkSampler.isPhysicalInterfaceName("llw0"))

        let prev = NetworkCounters(receivedBytes: 1_000_000, sentBytes: 500_000)
        let curr = NetworkCounters(receivedBytes: 3_000_000, sentBytes: 700_000)
        let rates = NetworkCounters.rates(from: prev, to: curr, elapsedSeconds: 2.0)
        #expect(rates.downloadBytesPerSec == 1_000_000)
        #expect(rates.uploadBytesPerSec == 100_000)

        // Counter reset / wraparound should safely return 0 instead of underflowing
        let reset = NetworkCounters(receivedBytes: 100, sentBytes: 100)
        let resetRates = NetworkCounters.rates(from: curr, to: reset, elapsedSeconds: 1.0)
        #expect(resetRates.downloadBytesPerSec == 0)
        #expect(resetRates.uploadBytesPerSec == 0)
    }

    @Test func processSamplerDetectsStaleBaselineAndPreservesCacheAcrossShortPolls() {
        let sampler = ProcessSampler()
        let t0 = ContinuousClock.Instant.now
        #expect(sampler.isCPUBaselineStale(at: t0))

        sampler.captureBaseline(now: t0)
        #expect(!sampler.isCPUBaselineStale(at: t0.advanced(by: .seconds(2))))
        #expect(sampler.isCPUBaselineStale(at: t0.advanced(by: .seconds(4))))

        let first = sampler.sample(
            now: t0.advanced(by: .milliseconds(200)),
            totalMemoryBytes: 16 * 1_073_741_824,
            limit: 5,
            needCPU: true,
            needMemory: true
        )
        #expect(!first.topCPU.isEmpty)

        // An immediate out-of-band poll (< 50 ms later) must keep the previous cached list and baseline.
        let immediate = sampler.sample(
            now: t0.advanced(by: .milliseconds(210)),
            totalMemoryBytes: 16 * 1_073_741_824,
            limit: 5,
            needCPU: true,
            needMemory: false
        )
        #expect(immediate.topCPU == first.topCPU)
    }
}
