import AppKit
import SwiftUI

// MARK: - Adaptive Semantic Palette (Light & Dark Mode)

enum MonitorPalette {
    static let cyan = adaptive(light: (0.00, 0.48, 1.00), dark: (0.22, 0.74, 0.97))     // #007AFF / #38BDF8
    static let indigo = adaptive(light: (0.35, 0.34, 0.84), dark: (0.51, 0.55, 0.97))   // #5856D6 / #818CF8
    static let purple = adaptive(light: (0.69, 0.32, 0.87), dark: (0.75, 0.52, 0.99))   // #AF52DE / #C084FC
    static let emerald = adaptive(light: (0.06, 0.65, 0.50), dark: (0.20, 0.83, 0.60))  // #10B981 / #34D399
    static let teal = adaptive(light: (0.05, 0.58, 0.53), dark: (0.18, 0.83, 0.75))     // #0D9488 / #2DD4BF
    static let amber = adaptive(light: (0.96, 0.58, 0.04), dark: (0.98, 0.75, 0.14))    // #F59E0B / #FBBF24
    static let orange = adaptive(light: (1.00, 0.42, 0.00), dark: (0.98, 0.57, 0.24))   // #FF6B00 / #FB923C
    static let coral = adaptive(light: (0.94, 0.27, 0.27), dark: (0.97, 0.44, 0.44))    // #EF4444 / #F87171

    private static func adaptive(
        light: (CGFloat, CGFloat, CGFloat),
        dark: (CGFloat, CGFloat, CGFloat)
    ) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let rgb = isDark ? dark : light
                return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
            }
        )
    }

    static func cpuColor(
        _ usage: Double,
        threshold: Double = MonitorCPUAlertThreshold.standard.fraction
    ) -> Color {
        usage >= threshold ? orange : cyan
    }

    /// Primary visual theme for the RAM tab (hero value, sparkline, and process bars).
    static func ramThemeColor(pressure: MemoryPressureLevel) -> Color {
        pressure == .critical ? coral : indigo
    }

    /// Semantic status color for the memory pressure badge and tab indicator dot.
    static func ramPressureColor(
        usage: Double,
        pressure: MemoryPressureLevel,
        alertThreshold: Double = MonitorRAMAlertThreshold.standard.fraction
    ) -> Color {
        switch pressure {
        case .critical: coral
        case .warning: amber
        case .normal: usage >= alertThreshold ? amber : emerald
        }
    }

    static func thermalColor(
        _ celsius: Double?,
        alertThreshold: Double = MonitorThermalAlertThreshold.standard.celsius
    ) -> Color {
        guard let celsius else { return teal }
        if celsius >= alertThreshold { return coral }
        if celsius >= 55 { return amber }
        return teal
    }
}

// MARK: - Main Popover View (macOS 26+ Liquid Glass)

struct MonitorPopoverView: View {
    static let cardWidth: CGFloat = 336
    static let innerPadding: CGFloat = 14
    /// Room around the card for the Liquid Glass rim and native shadow.
    static let margin: CGFloat = 14
    static let maxCardHeight: CGFloat = 620
    static let panelSize = NSSize(
        width: cardWidth + 2 * margin,
        height: maxCardHeight + 2 * margin
    )

    let monitor: SystemMonitor
    var preferences: Preferences?
    var onOpenSettings: (() -> Void)?
    var onActiveHeightChange: ((CGFloat) -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @State private var confirmingPID: pid_t?
    @State private var frozenProcesses: [ProcessMetric]?
    @State private var confirmResetTask: Task<Void, Never>?

    private var metrics: SystemMetrics { monitor.detailMetrics }
    private var selectedTab: MonitorTab { monitor.activeTab }
    private var cpuAlertThreshold: Double {
        preferences?.monitorCPUAlertThreshold.fraction ?? MonitorCPUAlertThreshold.standard.fraction
    }
    private var ramAlertThreshold: Double {
        preferences?.monitorRAMAlertThreshold.fraction ?? MonitorRAMAlertThreshold.standard.fraction
    }
    private var thermalAlertThreshold: Double {
        preferences?.monitorThermalAlertThreshold.celsius ?? MonitorThermalAlertThreshold.standard.celsius
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            tabBar
            switch selectedTab {
            case .cpu:
                cpuTabContent
            case .ram:
                ramTabContent
            case .tmp:
                tmpTabContent
            }
            footerBar
        }
        .padding(Self.innerPadding)
        .frame(width: Self.cardWidth)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        colorScheme == .dark
                            ? Color(red: 0.07, green: 0.09, blue: 0.13).opacity(0.55)
                            : Color.white.opacity(0.62)
                    )
                Color.clear
                    .glassEffect(.regular, in: .rect(cornerRadius: 22))
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { cardHeight in
            onActiveHeightChange?(cardHeight + 2 * Self.margin)
        }
        .padding(Self.margin)
        .frame(width: Self.panelSize.width, height: Self.panelSize.height, alignment: .top)
        .animation(.spring(duration: 0.28, bounce: 0.05), value: selectedTab)
        .focusEffectDisabled()
    }

    // MARK: - Horizontal Tab Bar (CPU / RAM / TMP)

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(MonitorTab.allCases) { tab in
                let isSelected = selectedTab == tab
                let dotColor = tabDotColor(for: tab)
                let textAccent = tabTextAccent(for: tab)
                HStack(spacing: 5) {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 6, height: 6)
                    Text(tab.rawValue)
                        .font(.system(size: 11.5, weight: .bold, design: .rounded))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                    Text(tabSummary(for: tab))
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(isSelected ? textAccent : .secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(
                                colorScheme == .dark
                                    ? Color.white.opacity(0.14)
                                    : Color.white.opacity(0.95)
                            )
                            .shadow(
                                color: .black.opacity(colorScheme == .dark ? 0.20 : 0.06),
                                radius: 2.5,
                                y: 1
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(
                                        colorScheme == .dark
                                            ? Color.white.opacity(0.16)
                                            : Color.black.opacity(0.05),
                                        lineWidth: 0.5
                                    )
                            }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    cancelConfirm()
                    monitor.setActiveTab(tab)
                }
            }
        }
        .padding(3.5)
        .background(
            colorScheme == .dark
                ? Color.white.opacity(0.065)
                : Color(red: 0.12, green: 0.16, blue: 0.24).opacity(0.06),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }

    private func tabDotColor(for tab: MonitorTab) -> Color {
        switch tab {
        case .cpu: MonitorPalette.cpuColor(metrics.cpuUsage, threshold: cpuAlertThreshold)
        case .ram: MonitorPalette.ramPressureColor(
            usage: metrics.memoryUsage,
            pressure: metrics.memoryPressure,
            alertThreshold: ramAlertThreshold
        )
        case .tmp: MonitorPalette.thermalColor(metrics.temperatureCelsius, alertThreshold: thermalAlertThreshold)
        }
    }

    private func tabTextAccent(for tab: MonitorTab) -> Color {
        switch tab {
        case .cpu: MonitorPalette.cpuColor(metrics.cpuUsage, threshold: cpuAlertThreshold)
        case .ram: MonitorPalette.ramThemeColor(pressure: metrics.memoryPressure)
        case .tmp: MonitorPalette.thermalColor(metrics.temperatureCelsius, alertThreshold: thermalAlertThreshold)
        }
    }

    private func tabSummary(for tab: MonitorTab) -> String {
        switch tab {
        case .cpu:
            SystemMetrics.formatPercentage(metrics.cpuUsage)
        case .ram:
            SystemMetrics.formatPercentage(metrics.memoryUsage)
        case .tmp:
            SystemMetrics.formatTemperature(metrics.temperatureCelsius)
        }
    }

    // MARK: - 1. CPU Tab

    private var cpuTabContent: some View {
        let d = metrics.cpuDetails
        let accent = MonitorPalette.cpuColor(metrics.cpuUsage, threshold: cpuAlertThreshold)
        return VStack(alignment: .leading, spacing: 10) {
            // Hero + 60s Sparkline Card
            hudCard {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(d.chipName.isEmpty ? "Apple Silicon" : d.chipName)
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                if !d.performanceCores.isEmpty {
                                    Text("\(d.performanceCores.count)P + \(d.efficiencyCores.count)E")
                                        .font(.system(size: 9.5, weight: .bold).monospacedDigit())
                                        .foregroundStyle(MonitorPalette.cyan)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1.5)
                                        .background(MonitorPalette.cyan.opacity(0.14), in: Capsule())
                                }
                            }
                            HStack(spacing: 8) {
                                Text(L10n.tr("用户 \(SystemMetrics.formatPercentage(d.userUsage))", "User \(SystemMetrics.formatPercentage(d.userUsage))"))
                                Text(L10n.tr("系统 \(SystemMetrics.formatPercentage(d.systemUsage))", "Sys \(SystemMetrics.formatPercentage(d.systemUsage))"))
                                Text(String(format: L10n.tr("负载 %.2f", "Load %.2f"), d.loadAverage1m))
                            }
                            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(SystemMetrics.formatPercentage(metrics.cpuUsage))
                            .font(.system(size: 24, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(accent)
                    }

                    SparklineView(samples: metrics.cpuHistory, color: accent)
                        .frame(height: 32)
                }
            }

            // E-Core + P-Core + GPU Utilization Matrix Card
            hudCard {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 10) {
                        clusterLegend(color: MonitorPalette.cyan, label: L10n.tr("能效 E", "Eff E"), value: d.efficiencyUsage)
                        clusterLegend(color: MonitorPalette.indigo, label: L10n.tr("性能 P", "Perf P"), value: d.performanceUsage)
                        Spacer()
                        clusterLegend(color: MonitorPalette.purple, label: "GPU", value: d.gpuUsage)
                    }

                    HStack(alignment: .bottom, spacing: 4.5) {
                        ForEach(Array(d.efficiencyCores.enumerated()), id: \.offset) { idx, usage in
                            coreVerticalBar(
                                label: "E\(idx + 1)",
                                fraction: usage,
                                color: MonitorPalette.cyan
                            )
                        }
                        ForEach(Array(d.performanceCores.enumerated()), id: \.offset) { idx, usage in
                            coreVerticalBar(
                                label: "P\(idx + 1)",
                                fraction: usage,
                                color: MonitorPalette.indigo
                            )
                        }
                        coreVerticalBar(
                            label: "GPU",
                            fraction: d.gpuUsage,
                            color: MonitorPalette.purple
                        )
                    }
                    .frame(height: 44)
                }
            }

            // Top 10 CPU Processes Card (with inline Kill button)
            processListCard(
                title: L10n.tr("高占用进程 Top 10 (CPU)", "Top 10 CPU Processes"),
                processes: d.topProcesses,
                barColor: accent
            )
        }
    }

    private func clusterLegend(color: Color, label: String, value: Double) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 5.5, height: 5.5)
            Text("\(label) \(SystemMetrics.formatPercentage(value))")
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func coreVerticalBar(label: String, fraction: Double, color: Color) -> some View {
        let clamped = min(max(fraction, 0), 1)
        let barHeight: CGFloat = 31
        return VStack(spacing: 3) {
            ZStack(alignment: .bottom) {
                Capsule()
                    .fill(trackColor)
                Capsule()
                    .fill(color)
                    .frame(height: max(3.5, barHeight * clamped))
            }
            .frame(width: 7, height: barHeight)
            Text(label)
                .font(.system(size: 8, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 2. RAM Tab

    private var ramTabContent: some View {
        let d = metrics.memoryDetails
        let accent = MonitorPalette.ramThemeColor(pressure: metrics.memoryPressure)
        let badgeColor = MonitorPalette.ramPressureColor(
            usage: metrics.memoryUsage,
            pressure: metrics.memoryPressure,
            alertThreshold: ramAlertThreshold
        )
        return VStack(alignment: .leading, spacing: 10) {
            // Hero + Memory Pressure + 60s Sparkline Card
            hudCard {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(L10n.tr("物理内存", "Physical Memory"))
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(.primary)
                                Text(d.pressure.label)
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundStyle(badgeColor)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1.5)
                                    .background(badgeColor.opacity(0.14), in: Capsule())
                            }
                            Text(L10n.tr(
                                "已用 \(SystemMetrics.formatBytes(d.usedBytes)) / \(SystemMetrics.formatBytes(d.totalBytes)) · 可用 \(SystemMetrics.formatBytes(d.freeBytes))",
                                "Used \(SystemMetrics.formatBytes(d.usedBytes)) / \(SystemMetrics.formatBytes(d.totalBytes)) · Free \(SystemMetrics.formatBytes(d.freeBytes))"
                            ))
                                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(SystemMetrics.formatPercentage(metrics.memoryUsage))
                            .font(.system(size: 24, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(accent)
                    }

                    SparklineView(samples: metrics.memoryHistory, color: accent)
                        .frame(height: 32)
                }
            }

            // Multi-segment Memory Composition Card
            hudCard {
                VStack(alignment: .leading, spacing: 7) {
                    let barWidth: CGFloat = Self.cardWidth - 2 * Self.innerPadding - 20
                    let total = Double(max(d.totalBytes, 1))
                    let appW = barWidth * min(Double(d.appBytes) / total, 1)
                    let wiredW = barWidth * min(Double(d.wiredBytes) / total, 1)
                    let compW = barWidth * min(Double(d.compressedBytes) / total, 1)
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(trackColor)
                        HStack(spacing: 1.5) {
                            Rectangle()
                                .fill(MonitorPalette.cyan)
                                .frame(width: max(0, appW))
                            Rectangle()
                                .fill(MonitorPalette.indigo)
                                .frame(width: max(0, wiredW))
                            Rectangle()
                                .fill(MonitorPalette.teal)
                                .frame(width: max(0, compW))
                        }
                        .clipShape(Capsule())
                    }
                    .frame(width: barWidth, height: 7)

                    HStack(spacing: 0) {
                        ramLegendPill(color: MonitorPalette.cyan, title: "App", bytes: d.appBytes)
                        Spacer(minLength: 4)
                        ramLegendPill(color: MonitorPalette.indigo, title: L10n.tr("联动", "Wired"), bytes: d.wiredBytes)
                        Spacer(minLength: 4)
                        ramLegendPill(color: MonitorPalette.teal, title: L10n.tr("压缩", "Comp."), bytes: d.compressedBytes)
                        Spacer(minLength: 4)
                        ramLegendPill(
                            color: d.swapUsedBytes > 1_073_741_824 ? MonitorPalette.coral : .secondary,
                            title: "Swap",
                            bytes: d.swapUsedBytes
                        )
                    }
                }
            }

            // Top 10 Memory Hogs Card (with inline Kill button)
            processListCard(
                title: L10n.tr("内存大户排行 Top 10 (Phys Footprint)", "Top 10 Memory Processes"),
                processes: d.topProcesses,
                barColor: accent
            )
        }
    }

    private func ramLegendPill(color: Color, title: String, bytes: UInt64) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 5.5, height: 5.5)
            Text("\(title) \(SystemMetrics.formatCompactBytes(bytes))")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }


    // MARK: - 3. TMP Tab

    private var tmpTabContent: some View {
        let d = metrics.thermalDetails
        let accent = MonitorPalette.thermalColor(metrics.temperatureCelsius, alertThreshold: thermalAlertThreshold)
        return VStack(alignment: .leading, spacing: 10) {
            // Hero + Thermal State + 60s Sparkline Card
            hudCard {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(L10n.tr("SoC 核心温度", "SoC Temperature"))
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(thermalStateText(metrics.temperatureCelsius))
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundStyle(accent)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1.5)
                                    .background(accent.opacity(0.14), in: Capsule())
                                    .lineLimit(1)
                            }
                            Text(L10n.tr(
                                "峰值 \(SystemMetrics.formatTemperatureDetail(d.maxDieCelsius)) · 最低 \(SystemMetrics.formatTemperatureDetail(d.minDieCelsius))",
                                "Peak \(SystemMetrics.formatTemperatureDetail(d.maxDieCelsius)) · Min \(SystemMetrics.formatTemperatureDetail(d.minDieCelsius))"
                            ))
                                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(SystemMetrics.formatTemperatureDetail(metrics.temperatureCelsius))
                            .font(.system(size: 24, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(accent)
                    }

                    SparklineView(samples: metrics.thermalHistory, color: accent)
                        .frame(height: 32)
                }
            }

            // Hardware Power (Watts) + Cooling Fan (RPM) Cards
            HStack(spacing: 8) {
                hudCard {
                    HStack(spacing: 8) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(MonitorPalette.amber)
                            .frame(width: 26, height: 26)
                            .background(MonitorPalette.amber.opacity(0.14), in: Circle())
                        VStack(alignment: .leading, spacing: 1) {
                            Text(L10n.tr("整机功耗", "System Power"))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text(SystemMetrics.formatWatts(d.systemPowerWatts))
                                .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                                .foregroundStyle(.primary)
                        }
                        Spacer(minLength: 0)
                    }
                }

                hudCard {
                    HStack(spacing: 8) {
                        Image(systemName: "fanblades.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(MonitorPalette.cyan)
                            .frame(width: 26, height: 26)
                            .background(MonitorPalette.cyan.opacity(0.14), in: Circle())
                        VStack(alignment: .leading, spacing: 1) {
                            Text(L10n.tr("散热风扇", "Cooling Fan"))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text(formatFan(d))
                                .font(.system(size: 12.5, weight: .bold, design: .rounded).monospacedDigit())
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }

            // 5 Subsystem Thermal Distribution Bars (0 ~ 100 °C)
            hudCard {
                VStack(alignment: .leading, spacing: 7) {
                    Text(L10n.tr("硬件关键部位热力分布 (0 ~ 100 °C)", "Hardware Thermal Zones (0 ~ 100 °C)"))
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)

                    thermalZoneBar(label: L10n.tr("SoC 性能核峰值", "SoC P-Core Peak"), celsius: d.maxDieCelsius)
                    thermalZoneBar(label: L10n.tr("SoC 核心均值", "SoC Die Average"), celsius: metrics.temperatureCelsius)
                    thermalZoneBar(label: L10n.tr("主板与供电 (PMU)", "Logic Board (PMU)"), celsius: d.boardAverageCelsius)
                    thermalZoneBar(label: L10n.tr("SSD 固态闪存 (NAND)", "SSD Storage (NAND)"), celsius: d.nandCelsius)
                    thermalZoneBar(label: L10n.tr("智能电池 (Battery)", "Smart Battery"), celsius: d.batteryCelsius)
                }
            }
        }
    }

    private func thermalZoneBar(label: String, celsius: Double?) -> some View {
        let progress = SystemMetrics.thermalProgress(celsius)
        let color = MonitorPalette.thermalColor(celsius, alertThreshold: thermalAlertThreshold)
        let barWidth: CGFloat = 94
        return HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 128, alignment: .leading)
                .lineLimit(1)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(trackColor)
                Capsule()
                    .fill(color)
                    .frame(width: max(4, barWidth * progress))
            }
            .frame(width: barWidth, height: 5.5)

            Text(SystemMetrics.formatTemperatureDetail(celsius))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(color)
                .frame(width: 50, alignment: .trailing)
        }
        .frame(height: 18)
    }

    private func thermalStateText(_ celsius: Double?) -> String {
        guard let celsius else { return L10n.tr("传感器就绪", "Sensors Ready") }
        if celsius >= 80 { return L10n.tr("高温降频预警", "Thermal Throttling") }
        if celsius >= 60 { return L10n.tr("高负载温升", "Warm Under Load") }
        return L10n.tr("热状态正常", "Nominal")
    }

    // MARK: - Top 10 Process List Card (with Direct Kill Button)

    private func processListCard(
        title: String,
        processes: [ProcessMetric],
        barColor: Color
    ) -> some View {
        let displayList = (confirmingPID != nil ? (frozenProcesses ?? processes) : processes)
        let currentPID = getpid()
        return hudCard {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(title)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(confirmingPID != nil ? L10n.tr("再次点击红色按钮确认结束", "Click red button to confirm") : L10n.tr("点击 ✕ 结束进程", "Click ✕ to quit process"))
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(confirmingPID != nil ? MonitorPalette.coral : .secondary.opacity(0.8))
                }
                .padding(.bottom, 1)

                ForEach(0..<10, id: \.self) { index in
                    if index < displayList.count {
                        let proc = displayList[index]
                        let isConfirming = confirmingPID == proc.pid
                        let canKill = proc.pid > 1 && proc.pid != currentPID
                        HStack(spacing: 6) {
                            Text("\(index + 1)")
                                .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 14, alignment: .trailing)

                            Image(nsImage: ProcessIconCache.icon(for: proc.bundlePath))
                                .resizable()
                                .interpolation(.high)
                                .frame(width: 15, height: 15)

                            Text(proc.name)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.tail)

                            Spacer(minLength: 4)

                            if !isConfirming {
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(trackColor)
                                    Capsule()
                                        .fill(barColor)
                                        .frame(width: max(3, 30 * min(max(proc.fraction, 0), 1)))
                                }
                                .frame(width: 30, height: 4)
                            }

                            Text(proc.valueText)
                                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.primary)
                                .frame(width: 52, alignment: .trailing)

                            if canKill {
                                if isConfirming {
                                    Text(L10n.tr("结束", "Quit"))
                                        .font(.system(size: 9.5, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6)
                                        .frame(height: 17)
                                        .background(MonitorPalette.coral, in: Capsule())
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            let targetPID = proc.pid
                                            cancelConfirm()
                                            monitor.terminateProcess(pid: targetPID)
                                        }
                                } else {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 17, height: 17)
                                        .background(trackColor, in: Circle())
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            armConfirm(for: proc.pid, currentProcesses: processes)
                                        }
                                }
                            } else {
                                Color.clear.frame(width: 17, height: 17)
                            }
                        }
                        .frame(height: 20)
                    } else {
                        HStack(spacing: 6) {
                            Text("\(index + 1)")
                                .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .frame(width: 14, alignment: .trailing)
                            Text("—")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                            Spacer()
                        }
                        .frame(height: 20)
                    }
                }
            }
        }
    }

    private func armConfirm(for pid: pid_t, currentProcesses: [ProcessMetric]) {
        confirmResetTask?.cancel()
        frozenProcesses = currentProcesses
        confirmingPID = pid
        confirmResetTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            confirmingPID = nil
            frozenProcesses = nil
        }
    }

    private func cancelConfirm() {
        confirmResetTask?.cancel()
        confirmResetTask = nil
        confirmingPID = nil
        frozenProcesses = nil
    }

    // MARK: - Footer Bar (Live Network)

    private var footerBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 4) {
                Circle()
                    .fill(MonitorPalette.cyan)
                    .frame(width: 5, height: 5)
                Text(L10n.tr("上传 \(SystemMetrics.formatRate(metrics.uploadBytesPerSec))", "Up \(SystemMetrics.formatRate(metrics.uploadBytesPerSec))"))
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                Circle()
                    .fill(MonitorPalette.emerald)
                    .frame(width: 5, height: 5)
                Text(L10n.tr("下载 \(SystemMetrics.formatRate(metrics.downloadBytesPerSec))", "Down \(SystemMetrics.formatRate(metrics.downloadBytesPerSec))"))
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let onOpenSettings {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 18)
                    .background(trackColor, in: Capsule())
                    .contentShape(Rectangle())
                    .help(L10n.tr("打开监听配置中心", "Open Monitor Settings"))
                    .onTapGesture(perform: onOpenSettings)
            }
        }
    }

    // MARK: - Helpers & Card Wrapper

    private var trackColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.11)
            : Color(red: 0.12, green: 0.16, blue: 0.24).opacity(0.085)
    }

    private func hudCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        colorScheme == .dark
                            ? Color.white.opacity(0.065)
                            : Color.white.opacity(0.76)
                    )
                    .shadow(
                        color: .black.opacity(colorScheme == .dark ? 0 : 0.025),
                        radius: 4,
                        y: 1
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(
                                colorScheme == .dark
                                    ? Color.white.opacity(0.10)
                                    : Color(red: 0.12, green: 0.16, blue: 0.24).opacity(0.065),
                                lineWidth: 0.5
                            )
                    }
            }
    }

    private func formatFan(_ details: ThermalDetails) -> String {
        guard let rpm = details.fanRPM else {
            return L10n.tr("被动散热", "Fanless")
        }
        if rpm < 50 {
            return L10n.tr("0 RPM (停转)", "0 RPM (Idle)")
        }
        if let maxRPM = details.fanMaxRPM, maxRPM > 0 {
            let pct = Int((Double(rpm) / Double(maxRPM) * 100).rounded())
            return "\(rpm) RPM (\(pct)%)"
        }
        return "\(rpm) RPM"
    }
}

// MARK: - 60-Second Area Sparkline View

private struct SparklineView: View {
    let samples: [Double]
    let color: Color

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            guard w > 4, h > 4 else { return }

            for frac in [0.25, 0.65] {
                let y = h * frac
                var grid = Path()
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: w, y: y))
                context.stroke(grid, with: .color(.primary.opacity(0.06)), lineWidth: 0.5)
            }

            let capacity = 30
            let padded: [Double]
            if samples.count >= capacity {
                padded = Array(samples.suffix(capacity))
            } else {
                padded = Array(repeating: samples.first ?? 0, count: capacity - samples.count) + samples
            }

            let stepX = w / CGFloat(max(capacity - 1, 1))
            var linePath = Path()
            var areaPath = Path()

            for (idx, raw) in padded.enumerated() {
                let clamped = min(max(raw, 0), 1)
                let x = CGFloat(idx) * stepX
                let y = h - 2 - (h - 5) * CGFloat(clamped)
                let pt = CGPoint(x: x, y: y)
                if idx == 0 {
                    linePath.move(to: pt)
                    areaPath.move(to: CGPoint(x: x, y: h))
                    areaPath.addLine(to: pt)
                } else {
                    linePath.addLine(to: pt)
                    areaPath.addLine(to: pt)
                }
            }
            areaPath.addLine(to: CGPoint(x: w, y: h))
            areaPath.closeSubpath()

            context.fill(
                areaPath,
                with: .linearGradient(
                    Gradient(colors: [color.opacity(0.28), color.opacity(0.02)]),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: 0, y: h)
                )
            )
            context.stroke(
                linePath,
                with: .color(color),
                style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
            )

            if let last = padded.last {
                let clamped = min(max(last, 0), 1)
                let lastY = h - 2 - (h - 5) * CGFloat(clamped)
                let dotRect = CGRect(x: w - 2.5, y: lastY - 2.5, width: 5, height: 5)
                context.fill(Path(ellipseIn: dotRect), with: .color(color))
            }
        }
    }
}

// MARK: - Process Icon Cache

private enum ProcessIconCache {
    private static var cache: [String: NSImage] = [:]
    private static let fallbackIcon: NSImage = {
        NSWorkspace.shared.icon(for: .unixExecutable)
    }()

    static func icon(for bundlePath: String?) -> NSImage {
        guard let bundlePath, !bundlePath.isEmpty else {
            return fallbackIcon
        }
        if let cached = cache[bundlePath] {
            return cached
        }
        let img = NSWorkspace.shared.icon(forFile: bundlePath)
        if cache.count > 128 {
            cache.removeAll(keepingCapacity: true)
        }
        cache[bundlePath] = img
        return img
    }
}
