import AppKit
import SwiftUI

enum MonitorTab: String, CaseIterable, Identifiable {
    case cpu = "CPU"
    case ram = "RAM"
    case tmp = "TMP"

    var id: String { rawValue }
}

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

    static func cpuColor(_ usage: Double) -> Color {
        usage >= 0.80 ? orange : cyan
    }

    /// Primary visual theme for the RAM tab (hero value, sparkline, and process bars).
    static func ramThemeColor(pressure: MemoryPressureLevel) -> Color {
        pressure == .critical ? coral : indigo
    }

    /// Semantic status color for the memory pressure badge and tab indicator dot.
    static func ramPressureColor(usage: Double, pressure: MemoryPressureLevel) -> Color {
        switch pressure {
        case .critical: coral
        case .warning: amber
        case .normal: usage >= 0.88 ? amber : emerald
        }
    }

    static func thermalColor(_ celsius: Double?) -> Color {
        guard let celsius else { return teal }
        if celsius >= 72 { return coral }
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
    let onOpenMenu: () -> Void
    var onActiveHeightChange: ((CGFloat) -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedTab: MonitorTab = .cpu
    @State private var confirmingPID: pid_t?
    @State private var frozenProcesses: [ProcessMetric]?
    @State private var confirmResetTask: Task<Void, Never>?

    private var metrics: SystemMetrics { monitor.metrics }

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
                    selectedTab = tab
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
        case .cpu: MonitorPalette.cpuColor(metrics.cpuUsage)
        case .ram: MonitorPalette.ramPressureColor(usage: metrics.memoryUsage, pressure: metrics.memoryPressure)
        case .tmp: MonitorPalette.thermalColor(metrics.temperatureCelsius)
        }
    }

    private func tabTextAccent(for tab: MonitorTab) -> Color {
        switch tab {
        case .cpu: MonitorPalette.cpuColor(metrics.cpuUsage)
        case .ram: MonitorPalette.ramThemeColor(pressure: metrics.memoryPressure)
        case .tmp: MonitorPalette.thermalColor(metrics.temperatureCelsius)
        }
    }

    private func tabSummary(for tab: MonitorTab) -> String {
        switch tab {
        case .cpu:
            SystemMetrics.formatPercentage(metrics.cpuUsage)
        case .ram:
            SystemMetrics.formatPercentage(metrics.memoryUsage)
        case .tmp:
            if let c = metrics.temperatureCelsius {
                "\(Int(c.rounded()))°"
            } else {
                "--°"
            }
        }
    }

    // MARK: - 1. CPU Tab

    private var cpuTabContent: some View {
        let d = metrics.cpuDetails
        let accent = MonitorPalette.cpuColor(metrics.cpuUsage)
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
                                Text("用户 \(SystemMetrics.formatPercentage(d.userUsage))")
                                Text("系统 \(SystemMetrics.formatPercentage(d.systemUsage))")
                                Text(String(format: "负载 %.2f", d.loadAverage1m))
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
                        clusterLegend(color: MonitorPalette.cyan, label: "能效 E", value: d.efficiencyUsage)
                        clusterLegend(color: MonitorPalette.indigo, label: "性能 P", value: d.performanceUsage)
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
                title: "高占用进程 Top 10 (CPU)",
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
        return VStack(spacing: 3) {
            GeometryReader { geo in
                ZStack(alignment: .bottom) {
                    Capsule()
                        .fill(trackColor)
                    Capsule()
                        .fill(color)
                        .frame(height: max(3.5, geo.size.height * clamped))
                }
            }
            .frame(width: 7)
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
            pressure: metrics.memoryPressure
        )
        return VStack(alignment: .leading, spacing: 10) {
            // Hero + Memory Pressure + 60s Sparkline Card
            hudCard {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text("物理内存")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(.primary)
                                Text(pressureLabel(d.pressure))
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundStyle(badgeColor)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1.5)
                                    .background(badgeColor.opacity(0.14), in: Capsule())
                            }
                            Text("已用 \(SystemMetrics.formatBytes(d.usedBytes)) / \(SystemMetrics.formatBytes(d.totalBytes)) · 可用 \(SystemMetrics.formatBytes(d.freeBytes))")
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
                    GeometryReader { geo in
                        let total = Double(max(d.totalBytes, 1))
                        let appW = geo.size.width * min(Double(d.appBytes) / total, 1)
                        let wiredW = geo.size.width * min(Double(d.wiredBytes) / total, 1)
                        let compW = geo.size.width * min(Double(d.compressedBytes) / total, 1)
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
                    }
                    .frame(height: 7)

                    HStack(spacing: 0) {
                        ramLegendPill(color: MonitorPalette.cyan, title: "App", bytes: d.appBytes)
                        Spacer(minLength: 4)
                        ramLegendPill(color: MonitorPalette.indigo, title: "联动", bytes: d.wiredBytes)
                        Spacer(minLength: 4)
                        ramLegendPill(color: MonitorPalette.teal, title: "压缩", bytes: d.compressedBytes)
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
                title: "内存大户排行 Top 10 (Phys Footprint)",
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

    private func pressureLabel(_ level: MemoryPressureLevel) -> String {
        switch level {
        case .normal: "压力正常"
        case .warning: "压力偏高"
        case .critical: "压力吃紧"
        }
    }

    // MARK: - 3. TMP Tab

    private var tmpTabContent: some View {
        let d = metrics.thermalDetails
        let accent = MonitorPalette.thermalColor(metrics.temperatureCelsius)
        return VStack(alignment: .leading, spacing: 10) {
            // Hero + Thermal State + 60s Sparkline Card
            hudCard {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text("SoC 核心温度")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(.primary)
                                Text(thermalStateText(metrics.temperatureCelsius))
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundStyle(accent)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1.5)
                                    .background(accent.opacity(0.14), in: Capsule())
                            }
                            Text("峰值 \(formatTemp(d.maxDieCelsius)) · 最低 \(formatTemp(d.minDieCelsius))")
                                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(formatTemp(metrics.temperatureCelsius))
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
                            Text("整机功耗")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text(formatWatts(d.systemPowerWatts))
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
                            Text("散热风扇")
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
                    Text("硬件关键部位热力分布 (0 ~ 100 °C)")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)

                    thermalZoneBar(label: "SoC 性能核峰值", celsius: d.maxDieCelsius)
                    thermalZoneBar(label: "SoC 核心均值", celsius: metrics.temperatureCelsius)
                    thermalZoneBar(label: "主板与供电 (PMU)", celsius: d.boardAverageCelsius)
                    thermalZoneBar(label: "SSD 固态闪存 (NAND)", celsius: d.nandCelsius)
                    thermalZoneBar(label: "智能电池 (Battery)", celsius: d.batteryCelsius)
                }
            }
        }
    }

    private func thermalZoneBar(label: String, celsius: Double?) -> some View {
        let progress = SystemMetrics.thermalProgress(celsius)
        let color = MonitorPalette.thermalColor(celsius)
        return HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 128, alignment: .leading)
                .lineLimit(1)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(trackColor)
                    Capsule()
                        .fill(color)
                        .frame(width: max(4, geo.size.width * progress))
                }
            }
            .frame(height: 5.5)

            Text(formatTemp(celsius))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(color)
                .frame(width: 50, alignment: .trailing)
        }
        .frame(height: 18)
    }

    private func thermalStateText(_ celsius: Double?) -> String {
        guard let celsius else { return "传感器就绪" }
        if celsius >= 80 { return "高温降频预警" }
        if celsius >= 60 { return "高负载温升" }
        return "热状态正常"
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
                    Text(confirmingPID != nil ? "再次点击红色按钮确认结束" : "点击 ✕ 结束进程")
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
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule()
                                            .fill(trackColor)
                                        Capsule()
                                            .fill(barColor)
                                            .frame(width: max(3, geo.size.width * min(max(proc.fraction, 0), 1)))
                                    }
                                }
                                .frame(width: 30, height: 4)
                            }

                            Text(proc.valueText)
                                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.primary)
                                .frame(width: 52, alignment: .trailing)

                            if canKill {
                                if isConfirming {
                                    Text("结束")
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

    // MARK: - Footer Bar (Live Network + Menu Entry)

    private var footerBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Circle()
                    .fill(MonitorPalette.cyan)
                    .frame(width: 5, height: 5)
                Text("上传 \(SystemMetrics.formatRate(metrics.uploadBytesPerSec))")
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                Circle()
                    .fill(MonitorPalette.emerald)
                    .frame(width: 5, height: 5)
                Text("下载 \(SystemMetrics.formatRate(metrics.downloadBytesPerSec))")
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 10, weight: .semibold))
                Text("设置")
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(
                colorScheme == .dark
                    ? Color.white.opacity(0.08)
                    : Color.white.opacity(0.80),
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .strokeBorder(
                        colorScheme == .dark
                            ? Color.white.opacity(0.10)
                            : Color(red: 0.12, green: 0.16, blue: 0.24).opacity(0.065),
                        lineWidth: 0.5
                    )
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpenMenu)
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

    private func formatTemp(_ celsius: Double?) -> String {
        guard let celsius else { return "-- °C" }
        return String(format: "%.1f °C", celsius)
    }

    private func formatWatts(_ watts: Double?) -> String {
        guard let watts else { return "-- W" }
        return String(format: "%.1f W", watts)
    }

    private func formatFan(_ details: ThermalDetails) -> String {
        guard let rpm = details.fanRPM else {
            return "被动散热"
        }
        if rpm < 50 {
            return "0 RPM (停转)"
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
