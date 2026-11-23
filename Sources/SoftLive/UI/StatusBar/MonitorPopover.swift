import AppKit
import SwiftUI

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
    @State private var terminateErrorMessage: String?
    @State private var errorResetTask: Task<Void, Never>?
    @State private var isGearHovered = false

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
            sectionDivider
            footerBar
        }
        .padding(Self.innerPadding)
        .frame(width: Self.cardWidth)
        .background {
            Color.clear
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { cardHeight in
            onActiveHeightChange?(cardHeight + 2 * Self.margin)
        }
        .padding(Self.margin)
        .frame(width: Self.panelSize.width, height: Self.panelSize.height, alignment: .top)
        .animation(.spring(duration: 0.28, bounce: 0.05), value: selectedTab)
        .onChange(of: monitor.isDetailActive) { _, active in
            if !active {
                cancelConfirm()
                clearTerminateError()
                isGearHovered = false
            }
        }
        .focusEffectDisabled()
    }

    // MARK: - Horizontal Tab Bar (CPU / RAM / TMP)

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(MonitorTab.allCases) { tab in
                let isSelected = selectedTab == tab
                let alertColor = tabAlertColor(for: tab)
                HStack(spacing: 5) {
                    Text(tab.rawValue)
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                    Text(tabSummary(for: tab))
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(alertColor ?? (isSelected ? .primary : .secondary))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(
                                colorScheme == .dark
                                    ? Color.white.opacity(0.14)
                                    : Color.white.opacity(0.86)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(SoftLiveTheme.hairline, lineWidth: 0.5)
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
        .padding(3)
        .background(
            SoftLiveTheme.insetWell,
            in: RoundedRectangle(cornerRadius: 10.5, style: .continuous)
        )
    }

    private func tabAlertColor(for tab: MonitorTab) -> Color? {
        switch tab {
        case .cpu:
            if metrics.cpuUsage >= cpuAlertThreshold {
                return SoftLiveTheme.critical
            }
            return nil
        case .ram:
            switch metrics.memoryPressure {
            case .critical:
                return SoftLiveTheme.critical
            case .warning:
                return SoftLiveTheme.warning
            case .normal:
                return metrics.memoryUsage >= ramAlertThreshold ? SoftLiveTheme.warning : nil
            }
        case .tmp:
            if let celsius = metrics.temperatureCelsius, celsius >= thermalAlertThreshold {
                return SoftLiveTheme.critical
            }
            return nil
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
        let accent = SoftLiveTheme.cpuColor(metrics.cpuUsage, threshold: cpuAlertThreshold)
        return VStack(alignment: .leading, spacing: 10) {
            // Hero + 60s Sparkline
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
                                    .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1.5)
                                    .background(SoftLiveTheme.insetWell, in: Capsule())
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

                SparklineView(samples: metrics.cpuHistory, color: accent, minSpan: 0.15)
                    .frame(height: 32)
            }

            sectionDivider

            // E-Core + P-Core + GPU Utilization Matrix
            VStack(alignment: .leading, spacing: 7) {
                let eColor = SoftLiveTheme.accent.opacity(0.60)
                let pColor = SoftLiveTheme.accent
                let gpuColor = Color.primary.opacity(0.45)

                HStack(spacing: 10) {
                    clusterLegend(color: eColor, label: L10n.tr("能效 E", "Eff E"), value: d.efficiencyUsage)
                    clusterLegend(color: pColor, label: L10n.tr("性能 P", "Perf P"), value: d.performanceUsage)
                    Spacer()
                    clusterLegend(color: gpuColor, label: "GPU", value: d.gpuUsage)
                }

                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(Array(d.efficiencyCores.enumerated()), id: \.offset) { idx, usage in
                        coreVerticalBar(
                            label: "E\(idx + 1)",
                            fraction: usage,
                            color: coreBarColor(usage, base: eColor)
                        )
                    }
                    ForEach(Array(d.performanceCores.enumerated()), id: \.offset) { idx, usage in
                        coreVerticalBar(
                            label: "P\(idx + 1)",
                            fraction: usage,
                            color: coreBarColor(usage, base: pColor)
                        )
                    }
                    if !d.efficiencyCores.isEmpty || !d.performanceCores.isEmpty {
                        Rectangle()
                            .fill(SoftLiveTheme.hairline)
                            .frame(width: 0.5, height: 38)
                            .padding(.horizontal, 2)
                    }
                    coreVerticalBar(
                        label: "GPU",
                        fraction: d.gpuUsage,
                        color: coreBarColor(d.gpuUsage, base: gpuColor)
                    )
                }
                .frame(height: 44)
            }

            sectionDivider

            // Top 10 CPU Processes
            processListSection(
                title: L10n.tr("CPU 占用 Top 10", "Top 10 CPU Processes"),
                processes: d.topProcesses,
                barColor: accent
            )
        }
    }

    private func coreBarColor(_ usage: Double, base: Color) -> Color {
        if usage >= cpuAlertThreshold { return SoftLiveTheme.critical }
        if usage >= max(0.55, cpuAlertThreshold - 0.15) { return SoftLiveTheme.warning }
        return base
    }

    private func clusterLegend(color: Color, label: String, value: Double) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(color)
                .frame(width: 2, height: 8)
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
                    .fill(SoftLiveTheme.hairline)
                if clamped > 0.005 {
                    Capsule()
                        .fill(color)
                        .frame(height: max(2.5, barHeight * clamped))
                }
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
        let accent = SoftLiveTheme.ramStatusColor(
            usage: metrics.memoryUsage,
            pressure: metrics.memoryPressure,
            threshold: ramAlertThreshold
        )
        let swapColor: Color = switch metrics.memoryPressure {
        case .critical:
            SoftLiveTheme.critical
        case .warning:
            d.swapUsedBytes > 1_073_741_824 ? SoftLiveTheme.warning : .secondary
        case .normal:
            .secondary
        }
        let appColor = SoftLiveTheme.accent
        let wiredColor = SoftLiveTheme.accent.opacity(0.55)
        let compColor = Color.primary.opacity(0.28)

        return VStack(alignment: .leading, spacing: 10) {
            // Hero + Memory Pressure + 60s Sparkline
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(L10n.tr("物理内存", "Physical Memory"))
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.primary)
                            Text(d.pressure.label)
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(accent.opacity(0.14), in: Capsule())
                        }
                        Text(L10n.tr(
                            "已用 \(SystemMetrics.formatBytes(d.usedBytes)) / \(SystemMetrics.formatBytes(d.totalBytes)) · 可用 \(SystemMetrics.formatBytes(d.freeBytes))",
                            "Used \(SystemMetrics.formatBytes(d.usedBytes)) / \(SystemMetrics.formatBytes(d.totalBytes)) · Free \(SystemMetrics.formatBytes(d.freeBytes))"
                        ))
                            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    Spacer()
                    Text(SystemMetrics.formatPercentage(metrics.memoryUsage))
                        .font(.system(size: 24, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(accent)
                }

                SparklineView(samples: metrics.memoryHistory, color: accent, minSpan: 0.15)
                    .frame(height: 32)
            }

            sectionDivider

            // Multi-segment Memory Composition
            VStack(alignment: .leading, spacing: 7) {
                let barWidth: CGFloat = Self.cardWidth - 2 * Self.innerPadding
                let total = Double(max(d.totalBytes, 1))
                let appW = barWidth * min(Double(d.appBytes) / total, 1)
                let wiredW = barWidth * min(Double(d.wiredBytes) / total, 1)
                let compW = barWidth * min(Double(d.compressedBytes) / total, 1)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(SoftLiveTheme.hairline)
                    HStack(spacing: 1.5) {
                        Rectangle()
                            .fill(appColor)
                            .frame(width: max(0, appW))
                        Rectangle()
                            .fill(wiredColor)
                            .frame(width: max(0, wiredW))
                        Rectangle()
                            .fill(compColor)
                            .frame(width: max(0, compW))
                    }
                    .clipShape(Capsule())
                }
                .frame(width: barWidth, height: 7)

                HStack(spacing: 0) {
                    ramLegendItem(tickColor: appColor, title: "App", bytes: d.appBytes)
                    Spacer(minLength: 4)
                    ramLegendItem(tickColor: wiredColor, title: L10n.tr("联动", "Wired"), bytes: d.wiredBytes)
                    Spacer(minLength: 4)
                    ramLegendItem(tickColor: compColor, title: L10n.tr("压缩", "Comp."), bytes: d.compressedBytes)
                    Spacer(minLength: 4)
                    ramLegendItem(tickColor: nil, textColor: swapColor, title: "Swap", bytes: d.swapUsedBytes)
                }
            }

            sectionDivider

            // Top 10 Memory Hogs
            processListSection(
                title: L10n.tr("内存占用 Top 10", "Top 10 Memory Processes"),
                processes: d.topProcesses,
                barColor: accent
            )
        }
    }

    private func ramLegendItem(
        tickColor: Color?,
        textColor: Color = .secondary,
        title: String,
        bytes: UInt64
    ) -> some View {
        HStack(spacing: 4) {
            if let tickColor {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(tickColor)
                    .frame(width: 2, height: 8)
            }
            Text("\(title) \(SystemMetrics.formatCompactBytes(bytes))")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(textColor)
                .lineLimit(1)
        }
    }

    // MARK: - 3. TMP Tab

    private var tmpTabContent: some View {
        let d = metrics.thermalDetails
        let accent = SoftLiveTheme.thermalColor(metrics.temperatureCelsius, alertThreshold: thermalAlertThreshold)
        return VStack(alignment: .leading, spacing: 10) {
            // Hero + Thermal State + 60s Sparkline
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(L10n.tr("SoC 核心温度", "SoC Temp"))
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
                                .fixedSize()
                        }
                        Text(L10n.tr(
                            "峰值 \(SystemMetrics.formatTemperatureDetail(d.maxDieCelsius)) · 最低 \(SystemMetrics.formatTemperatureDetail(d.minDieCelsius))",
                            "Peak \(SystemMetrics.formatTemperatureDetail(d.maxDieCelsius)) · Min \(SystemMetrics.formatTemperatureDetail(d.minDieCelsius))"
                        ))
                            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    Spacer()
                    Text(SystemMetrics.formatTemperatureDetail(metrics.temperatureCelsius))
                        .font(.system(size: 24, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(accent)
                }

                SparklineView(samples: metrics.thermalHistory, color: accent, minSpan: 0.10)
                    .frame(height: 32)
            }

            sectionDivider

            // Hardware Power (Watts) + Cooling Fan (RPM)
            HStack(spacing: 8) {
                telemetryStatBlock(
                    icon: "bolt",
                    title: L10n.tr("整机功耗", "System Power"),
                    value: SystemMetrics.formatWatts(d.systemPowerWatts)
                )
                telemetryStatBlock(
                    icon: "fanblades",
                    title: L10n.tr("散热风扇", "Cooling Fan"),
                    value: formatFan(d)
                )
            }

            sectionDivider

            // 5 Subsystem Thermal Distribution Bars (0 ~ 100 °C)
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

    private func telemetryStatBlock(icon: String, title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(value)
                .font(.system(size: 13.5, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            SoftLiveTheme.insetWell,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }

    private func thermalZoneBar(label: String, celsius: Double?) -> some View {
        let progress = SystemMetrics.thermalProgress(celsius)
        let color = SoftLiveTheme.thermalColor(celsius, alertThreshold: thermalAlertThreshold)
        let barWidth: CGFloat = 108
        return HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 134, alignment: .leading)
                .lineLimit(1)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(SoftLiveTheme.hairline)
                if progress > 0.005 {
                    Capsule()
                        .fill(color)
                        .frame(width: max(3, barWidth * progress))
                }
            }
            .frame(width: barWidth, height: 5.5)

            Text(SystemMetrics.formatTemperatureDetail(celsius))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(celsius == nil ? .secondary : color)
                .frame(width: 50, alignment: .trailing)
        }
        .frame(height: 18)
    }

    private func thermalStateText(_ celsius: Double?) -> String {
        guard let celsius else { return L10n.tr("传感器就绪", "Ready") }
        if celsius >= thermalAlertThreshold { return L10n.tr("高温预警", "Throttling") }
        if celsius >= max(55, thermalAlertThreshold - 10) { return L10n.tr("高负载温升", "Warm") }
        return L10n.tr("热状态正常", "Nominal")
    }

    // MARK: - Top 10 Process List (Hover-Reveal + Direct Confirm Quit)

    private func processListSection(
        title: String,
        processes: [ProcessMetric],
        barColor: Color
    ) -> some View {
        let displayList = (confirmingPID != nil ? (frozenProcesses ?? processes) : processes)
        let currentPID = getpid()
        let headerHintText: String? = if let error = terminateErrorMessage {
            error
        } else if confirmingPID != nil {
            L10n.tr("再次点击确认结束", "Click again to quit")
        } else {
            nil
        }

        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                if let headerHintText {
                    Text(headerHintText)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(SoftLiveTheme.critical)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
            .padding(.bottom, 1)

            ForEach(0..<10, id: \.self) { index in
                if index < displayList.count {
                    let proc = displayList[index]
                    let canKill = proc.isTerminable && proc.pid > 1 && proc.pid != currentPID
                    ProcessRowView(
                        index: index,
                        process: proc,
                        barColor: barColor,
                        canKill: canKill,
                        isConfirming: confirmingPID == proc.pid,
                        isPopoverActive: monitor.isDetailActive,
                        onArmConfirm: {
                            clearTerminateError()
                            armConfirm(for: proc.pid, currentProcesses: processes)
                        },
                        onConfirmQuit: {
                            let targetPID = proc.pid
                            let targetName = proc.name
                            cancelConfirm()
                            if !monitor.terminateProcess(pid: targetPID) {
                                showTerminateError(for: targetName)
                            }
                        }
                    )
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

    private func showTerminateError(for name: String) {
        errorResetTask?.cancel()
        terminateErrorMessage = L10n.tr("无法结束 \(name)", "Cannot quit \(name)")
        errorResetTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            terminateErrorMessage = nil
        }
    }

    private func clearTerminateError() {
        errorResetTask?.cancel()
        errorResetTask = nil
        terminateErrorMessage = nil
    }

    // MARK: - Footer Bar (Live Network)

    private var footerBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(SystemMetrics.formatRate(metrics.uploadBytesPerSec))
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(SystemMetrics.formatRate(metrics.downloadBytesPerSec))
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let onOpenSettings {
                Image(systemName: "gearshape")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(isGearHovered ? .primary : .secondary)
                    .frame(width: 22, height: 22)
                    .background(
                        isGearHovered ? SoftLiveTheme.insetWell : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if isGearHovered != hovering {
                            isGearHovered = hovering
                        }
                    }
                    .help(L10n.tr("打开监听配置中心", "Open Monitor Settings"))
                    .onTapGesture(perform: onOpenSettings)
            }
        }
        .padding(.horizontal, 2)
    }

    // MARK: - Helpers

    private var sectionDivider: some View {
        Rectangle()
            .fill(SoftLiveTheme.hairline)
            .frame(height: 0.5)
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

// MARK: - Process Row (In-Place Trailing Hover Quit)

private struct ProcessRowView: View {
    let index: Int
    let process: ProcessMetric
    let barColor: Color
    let canKill: Bool
    let isConfirming: Bool
    let isPopoverActive: Bool
    let onArmConfirm: () -> Void
    let onConfirmQuit: () -> Void

    @State private var isRowHovered = false
    @State private var isActionHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Text("\(index + 1)")
                .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .trailing)

            Image(nsImage: ProcessIconCache.icon(for: process.bundlePath))
                .resizable()
                .interpolation(.high)
                .frame(width: 15, height: 15)

            Text(process.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(SoftLiveTheme.hairline)
                let clamped = min(max(process.fraction, 0), 1)
                if clamped > 0.001 {
                    Capsule()
                        .fill(barColor)
                        .frame(width: max(2.5, 30 * clamped))
                }
            }
            .frame(width: 30, height: 4)

            // Flush-right 52 pt slot swaps value text for the quit/confirm pill in-place on hover.
            Group {
                if canKill && isConfirming {
                    Text(L10n.tr("确认", "Confirm"))
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6.5)
                        .frame(height: 17)
                        .background(SoftLiveTheme.critical, in: Capsule())
                        .fixedSize(horizontal: true, vertical: false)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: onConfirmQuit)
                } else if canKill && isRowHovered {
                    Text(L10n.tr("结束", "Quit"))
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 7.5)
                        .frame(height: 17)
                        .background(
                            Color.primary.opacity(isActionHovered ? 0.14 : 0.09),
                            in: Capsule()
                        )
                        .fixedSize(horizontal: true, vertical: false)
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            if isActionHovered != hovering {
                                isActionHovered = hovering
                            }
                        }
                        .onTapGesture(perform: onArmConfirm)
                } else {
                    Text(process.valueText)
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.primary)
                }
            }
            .frame(width: 52, height: 18, alignment: .trailing)
        }
        .frame(height: 20)
        .background {
            if isRowHovered || isConfirming {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(SoftLiveTheme.insetWell)
                    .padding(.horizontal, -4)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            if isRowHovered != hovering {
                isRowHovered = hovering
            }
            if !hovering && isActionHovered {
                isActionHovered = false
            }
        }
        .onChange(of: isPopoverActive) { _, active in
            if !active {
                isRowHovered = false
                isActionHovered = false
            }
        }
    }
}

// MARK: - 60-Second Area Sparkline View

private struct SparklineView: View {
    let samples: [Double]
    let color: Color
    var minSpan: Double = 0.15

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            guard w > 8, h > 6 else { return }

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
                padded = Array(samples.suffix(capacity)).map { min(max($0, 0), 1) }
            } else {
                let first = min(max(samples.first ?? 0, 0), 1)
                padded = Array(repeating: first, count: capacity - samples.count)
                    + samples.map { min(max($0, 0), 1) }
            }

            let dataMin = padded.min() ?? 0
            let dataMax = padded.max() ?? 0
            let rawSpan = dataMax - dataMin
            let span = min(max(rawSpan * 1.15, minSpan), 1.0)
            let mid = (dataMin + dataMax) / 2
            var low = mid - span / 2
            var high = mid + span / 2
            if low < 0 {
                high = min(1, high - low)
                low = 0
            }
            if high > 1 {
                low = max(0, low - (high - 1))
                high = 1
            }
            let effectiveSpan = max(high - low, 0.001)

            let endX = w - 4
            let stepX = endX / CGFloat(max(capacity - 1, 1))
            var linePath = Path()
            var areaPath = Path()

            for (idx, raw) in padded.enumerated() {
                let normalized = min(max((raw - low) / effectiveSpan, 0), 1)
                let x = CGFloat(idx) * stepX
                let y = (h - 3) - (h - 6) * CGFloat(normalized)
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
            areaPath.addLine(to: CGPoint(x: endX, y: h))
            areaPath.closeSubpath()

            context.fill(
                areaPath,
                with: .linearGradient(
                    Gradient(colors: [color.opacity(0.24), color.opacity(0.02)]),
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
                let normalized = min(max((last - low) / effectiveSpan, 0), 1)
                let lastY = (h - 3) - (h - 6) * CGFloat(normalized)
                let dotRect = CGRect(x: endX - 2.5, y: lastY - 2.5, width: 5, height: 5)
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
