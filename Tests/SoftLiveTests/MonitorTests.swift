import AppKit
import Darwin
import SwiftUI
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

        L10n.language = .zhHans
        #expect(MemoryPressureLevel.normal.label == "压力正常")
        #expect(MemoryPressureLevel.warning.label == "压力偏高")
        #expect(MemoryPressureLevel.critical.label == "压力吃紧")

        L10n.language = .en
        #expect(MemoryPressureLevel.normal.label == "Normal")
        #expect(MemoryPressureLevel.warning.label == "Elevated")
        #expect(MemoryPressureLevel.critical.label == "Critical")
        L10n.language = .system

        #expect(SystemMetrics.thermalProgress(nil) == 0)
        #expect(SystemMetrics.thermalProgress(0) == 0)
        #expect(abs(SystemMetrics.thermalProgress(45) - 0.45) < 0.001)
        #expect(SystemMetrics.thermalProgress(100) == 1)
        #expect(SystemMetrics.thermalProgress(120) == 1)

        #expect(SystemMetrics.formatBytes(0) == "0 MB")
        #expect(SystemMetrics.formatBytes(512 * 1_048_576) == "512 MB")
        #expect(SystemMetrics.formatBytes(20 * 1_073_741_824) == "20.0 GB")
        #expect(SystemMetrics.formatCompactBytes(512 * 1_048_576) == "512M")
        #expect(SystemMetrics.formatCompactBytes(2 * 1_073_741_824) == "2.0G")

        #expect(SystemMetrics.formatRate(512) == "0 B/s")
        #expect(SystemMetrics.formatRate(128 * 1024) == "128 KB/s")
        #expect(SystemMetrics.formatRate(UInt64(2.4 * 1_048_576)) == "2.4 MB/s")
        #expect(SystemMetrics.formatRate(25 * 1_048_576) == "25 MB/s")

        #expect(SystemMetrics.formatCompactRate(512) == "0 B")
        #expect(SystemMetrics.formatCompactRate(621 * 1024) == "621 KB")
        #expect(SystemMetrics.formatCompactRate(UInt64(999.6 * 1024)) == "1.0 MB")
        #expect(SystemMetrics.formatCompactRate(UInt64(2.4 * 1_048_576)) == "2.4 MB")
        #expect(SystemMetrics.formatCompactRate(UInt64(9.96 * 1_048_576)) == "10 MB")
        #expect(SystemMetrics.formatCompactRate(25 * 1_048_576) == "25 MB")
        #expect(SystemMetrics.formatCompactRate(UInt64(999.6 * 1_048_576)) == "1.0 GB")
        #expect(SystemMetrics.formatCompactRate(UInt64(12.3 * 1_073_741_824)) == "12 GB")
    }

    @Test func rendersStatusBarImageMonochromeByDefaultAndTintsOnAlertBreach() {
        let metrics = SystemMetrics(
            cpuUsage: 0.24,
            memoryUsage: 0.78,
            temperatureCelsius: 44.0,
            uploadBytesPerSec: 64 * 1024,
            downloadBytesPerSec: 3 * 1_048_576
        )

        let monoImage = MonitorStatusBar.renderImage(for: metrics, coloredBars: false)
        #expect(monoImage.isTemplate)
        #expect(MonitorStatusBar.fullWidth == 52)
        #expect(monoImage.size == NSSize(width: MonitorStatusBar.fullWidth, height: 22))
        #expect(monoImage.tiffRepresentation != nil)

        let coloredImage = MonitorStatusBar.renderImage(for: metrics, coloredBars: true)
        #expect(!coloredImage.isTemplate)
        #expect(coloredImage.size == NSSize(width: MonitorStatusBar.fullWidth, height: 22))

        let compactImage = MonitorStatusBar.renderImage(for: metrics, style: .barsOnly, coloredBars: false)
        #expect(compactImage.size == NSSize(width: MonitorStatusBar.barsOnlyWidth, height: 22))
        #expect(compactImage.isTemplate)

        #expect(
            MonitorStatusBar.DisplayKey(metrics: metrics, coloredBars: true)
                != MonitorStatusBar.DisplayKey(metrics: metrics, coloredBars: false)
        )

        // Monochrome mode keeps template rendering until a metric breaches its alert threshold.
        let monoCPUAlert = MonitorStatusBar.DisplayKey(
            metrics: SystemMetrics(cpuUsage: 0.85),
            coloredBars: false
        )
        #expect(monoCPUAlert.cpuTone == .critical)
        #expect(!monoCPUAlert.isTemplate)
        #expect(!MonitorStatusBar.renderImage(for: SystemMetrics(cpuUsage: 0.85), coloredBars: false).isTemplate)

        let monoRAMAlert = MonitorStatusBar.DisplayKey(
            metrics: SystemMetrics(memoryUsage: 0.86),
            coloredBars: false
        )
        #expect(monoRAMAlert.ramTone == .warning)
        #expect(!monoRAMAlert.isTemplate)

        let monoCriticalPressure = MonitorStatusBar.DisplayKey(
            metrics: SystemMetrics(memoryUsage: 0.60, memoryPressure: .critical),
            coloredBars: false
        )
        #expect(monoCriticalPressure.ramTone == .critical)
        #expect(!monoCriticalPressure.isTemplate)

        let monoTempAlert = MonitorStatusBar.DisplayKey(
            metrics: SystemMetrics(temperatureCelsius: 74.0),
            coloredBars: false
        )
        #expect(monoTempAlert.tmpTone == .critical)
        #expect(!monoTempAlert.isTemplate)

        // Crossing color thresholds within the same integer bar-height step must produce distinct DisplayKeys.
        let cpuBelow = MonitorStatusBar.DisplayKey(metrics: SystemMetrics(cpuUsage: 0.795), coloredBars: false)
        let cpuAbove = MonitorStatusBar.DisplayKey(metrics: SystemMetrics(cpuUsage: 0.805), coloredBars: false)
        #expect(cpuBelow.cpuBarSteps == cpuAbove.cpuBarSteps)
        #expect(cpuBelow != cpuAbove)

        let customThresholdHit = MonitorStatusBar.DisplayKey(
            metrics: SystemMetrics(cpuUsage: 0.72),
            coloredBars: false,
            cpuThreshold: MonitorCPUAlertThreshold.low.fraction
        )
        #expect(customThresholdHit.cpuTone == .critical)

        let ramBelow = MonitorStatusBar.DisplayKey(metrics: SystemMetrics(memoryUsage: 0.84), coloredBars: false)
        let ramAbove = MonitorStatusBar.DisplayKey(metrics: SystemMetrics(memoryUsage: 0.86), coloredBars: false)
        #expect(ramBelow.ramTone == .monochrome)
        #expect(ramAbove.ramTone == .warning)
        #expect(ramBelow != ramAbove)

        let tmpColoredBelow = MonitorStatusBar.DisplayKey(metrics: SystemMetrics(temperatureCelsius: 61.9), coloredBars: true)
        let tmpColoredAbove = MonitorStatusBar.DisplayKey(metrics: SystemMetrics(temperatureCelsius: 62.1), coloredBars: true)
        #expect(tmpColoredBelow.tmpBarSteps == tmpColoredAbove.tmpBarSteps)
        #expect(tmpColoredBelow.tmpTone == .accent)
        #expect(tmpColoredAbove.tmpTone == .warning)
        #expect(tmpColoredBelow != tmpColoredAbove)

        let tmpMonoBelow = MonitorStatusBar.DisplayKey(metrics: SystemMetrics(temperatureCelsius: 71.5), coloredBars: false)
        let tmpMonoAbove = MonitorStatusBar.DisplayKey(metrics: SystemMetrics(temperatureCelsius: 72.5), coloredBars: false)
        #expect(tmpMonoBelow.tmpBarSteps == tmpMonoAbove.tmpBarSteps)
        #expect(tmpMonoBelow.tmpTone == .monochrome)
        #expect(tmpMonoAbove.tmpTone == .critical)
        #expect(tmpMonoBelow != tmpMonoAbove)

        // Crossing the 0.01 bar-visibility threshold must produce distinct DisplayKeys.
        let hiddenBar = MonitorStatusBar.DisplayKey(metrics: SystemMetrics(cpuUsage: 0.005))
        let visibleBar = MonitorStatusBar.DisplayKey(metrics: SystemMetrics(cpuUsage: 0.025))
        #expect(hiddenBar.cpuBarSteps == 0)
        #expect(visibleBar.cpuBarSteps == 1)
        #expect(hiddenBar != visibleBar)

        // Tooltip formats live bilingual summary.
        L10n.language = .en
        defer { L10n.language = .system }
        let enTip = MonitorStatusBar.tooltipText(for: metrics)
        #expect(enTip == "CPU 24% · RAM 78% · Temp 44.0 °C · ↑ 64 KB/s ↓ 3.0 MB/s")
        L10n.language = .zhHans
        let zhTip = MonitorStatusBar.tooltipText(for: metrics)
        #expect(zhTip == "CPU 24% · RAM 78% · 温度 44.0 °C · ↑ 64 KB/s ↓ 3.0 MB/s")
    }

    @Test func rendersMonitorPopoverAcrossAllTabsAndLanguages() throws {
        let suiteName = "dev.softlive.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            L10n.language = .system
        }

        let prefs = Preferences(defaults: defaults)
        let monitor = SystemMonitor(preferences: prefs)
        monitor.setDetailActive(true)
        defer { monitor.setDetailActive(false) }

        for lang in [AppLanguage.zhHans, .en] {
            prefs.language = lang
            for tab in MonitorTab.allCases {
                monitor.setActiveTab(tab)
                let host = NSHostingView(
                    rootView: MonitorPopoverView(
                        monitor: monitor,
                        preferences: prefs,
                        onOpenSettings: {}
                    )
                )
                host.frame = NSRect(origin: .zero, size: MonitorPopoverView.panelSize)
                host.layoutSubtreeIfNeeded()
                let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                #expect(rep.pixelsWide >= Int(MonitorPopoverView.panelSize.width))
            }
        }
    }

    @Test func disablesAndReenablesSystemMonitorCleanly() async {
        let suiteName = "dev.softlive.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let prefs = Preferences(defaults: defaults)
        let monitor = SystemMonitor(preferences: prefs)

        for _ in 0..<40 where monitor.metrics.memoryUsage == 0 {
            try? await Task.sleep(for: .milliseconds(25))
        }
        #expect(monitor.metrics.memoryUsage > 0)

        monitor.setDetailActive(true)
        #expect(monitor.isDetailActive)

        prefs.showsSystemMonitor = false
        for _ in 0..<40 where monitor.metrics != .zero || monitor.isDetailActive {
            try? await Task.sleep(for: .milliseconds(25))
        }
        #expect(monitor.metrics == .zero)
        #expect(monitor.detailMetrics == .zero)
        #expect(!monitor.isDetailActive)

        prefs.showsSystemMonitor = true
        for _ in 0..<40 where monitor.metrics.memoryUsage == 0 {
            try? await Task.sleep(for: .milliseconds(25))
        }
        #expect(monitor.metrics.memoryUsage > 0)
    }

    @Test func rejectsProtectedProcessTerminationSafely() {
        let suiteName = "dev.softlive.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let prefs = Preferences(defaults: defaults)
        let monitor = SystemMonitor(preferences: prefs)
        #expect(!ProcessSampler.canSignal(pid: 0))
        #expect(!ProcessSampler.canSignal(pid: 1))
        #expect(!ProcessSampler.canSignal(pid: getpid()))
        #expect(!monitor.terminateProcess(pid: 1))
        #expect(!monitor.terminateProcess(pid: getpid()))
    }

    @Test func togglesDetailActiveModeCleanly() {
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

    @Test func statusBarSecondClickClosesPopoverEvenAfterMonitorDismissal() {
        let suiteName = "dev.softlive.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let prefs = Preferences(defaults: defaults)
        let monitor = SystemMonitor(preferences: prefs)
        let statusBar = MonitorStatusBar(monitor: monitor, preferences: prefs, menu: NSMenu())
        let t0 = ContinuousClock.Instant.now

        #expect(!statusBar.isPopoverVisible)
        #expect(!monitor.isDetailActive)

        // 1st click opens the popover.
        statusBar.handleLeftClick(now: t0)
        #expect(statusBar.isPopoverVisible)
        #expect(monitor.isDetailActive)

        // Direct 2nd click closes the popover.
        let t1 = t0.advanced(by: .seconds(1))
        statusBar.handleLeftClick(now: t1)
        #expect(!statusBar.isPopoverVisible)
        #expect(!monitor.isDetailActive)

        // Re-open the popover.
        let t2 = t1.advanced(by: .seconds(1))
        statusBar.handleLeftClick(now: t2)
        #expect(statusBar.isPopoverVisible)
        #expect(monitor.isDetailActive)

        // Simulate macOS delivering the 2nd click to the global/local event monitor first,
        // followed milliseconds later by NSStatusBarButton's action for the same click.
        let t3 = t2.advanced(by: .seconds(1))
        statusBar.dismissFromOutsideClick(now: t3)
        statusBar.handleLeftClick(now: t3.advanced(by: .milliseconds(20)))
        #expect(!statusBar.isPopoverVisible)
        #expect(!monitor.isDetailActive)

        // Because the 2nd click consumed the suppression window, an immediate 3rd click re-opens cleanly.
        statusBar.handleLeftClick(now: t3.advanced(by: .milliseconds(100)))
        #expect(statusBar.isPopoverVisible)
        #expect(monitor.isDetailActive)

        statusBar.handleLeftClick(now: t3.advanced(by: .milliseconds(200)))
        #expect(!statusBar.isPopoverVisible)
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

        // Single-direction wraparound should preserve the other direction's rate
        let partialWrap = NetworkCounters(receivedBytes: 100, sentBytes: 900_000)
        let partialRates = NetworkCounters.rates(from: curr, to: partialWrap, elapsedSeconds: 2.0)
        #expect(partialRates.downloadBytesPerSec == 0)
        #expect(partialRates.uploadBytesPerSec == 100_000)
    }

    @Test func smcStructMatchesKernel80ByteLayout() {
        #expect(SMCSampler.structSize == 80)
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
