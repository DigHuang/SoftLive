import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension CleanCategory {
    var accentColor: Color {
        switch self {
        case .appCaches: MonitorPalette.cyan
        case .devCaches: MonitorPalette.indigo
        case .staleArtifacts: MonitorPalette.emerald
        case .leftoversAndInstallers: MonitorPalette.purple
        }
    }
}

extension AppResidualKind {
    var accentColor: Color {
        switch self {
        case .appBundle: MonitorPalette.emerald
        case .appSupport: MonitorPalette.indigo
        case .caches: MonitorPalette.cyan
        case .containers: MonitorPalette.purple
        case .preferences: MonitorPalette.teal
        case .stateAndWeb: MonitorPalette.cyan
        case .logs: MonitorPalette.amber
        case .sharedAndAgents: MonitorPalette.orange
        }
    }
}

private enum CleanTierFilter: String, CaseIterable, Identifiable {
    case all
    case safeOnly
    case checkFirstOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: L10n.tr("全部", "All")
        case .safeOnly: L10n.tr("安全项", "Safe")
        case .checkFirstOnly: L10n.tr("核对项", "Review")
        }
    }
}

private enum AppListSortOrder: String, CaseIterable, Identifiable {
    case totalSizeDesc
    case residualSizeDesc
    case nameAsc

    var id: String { rawValue }

    var title: String {
        switch self {
        case .totalSizeDesc: L10n.tr("按总体积", "Total Size")
        case .residualSizeDesc: L10n.tr("按残留量", "Leftovers")
        case .nameAsc: L10n.tr("按名称", "By Name")
        }
    }
}

/// Right-pane workspace for the `Cleaner` section inside `ControlCenterWindow`.
/// Supports two integrated modes:
/// 1. `缓存与残留 (Junk & Caches)` — 4-category allowlist Bento + full-height candidate table;
/// 2. `应用卸载 (App Uninstaller)` — master-detail installed app browser, `.app` drag-and-drop,
///    full uninstallation, and residuals-only "App Data Reset".
struct CleanerPaneView: View {
    let cleaner: DiskCleaner
    let preferences: Preferences

    @Environment(\.colorScheme) private var colorScheme
    @State private var filterCategory: CleanCategory?
    @State private var tierFilter: CleanTierFilter = .all
    @State private var sortOrder: CleanSortOrder = .sizeDesc
    @State private var searchQuery: String = ""
    @State private var confirmingTrash = false
    @State private var hoveredCandidateID: String?

    // App Uninstaller UI state
    @State private var appSearchQuery: String = ""
    @State private var appSortOrder: AppListSortOrder = .totalSizeDesc
    @State private var confirmingAppTrash = false
    @State private var hoveredAppID: String?
    @State private var hoveredResidualID: String?
    @State private var isDropTargeted = false

    private var isDark: Bool { colorScheme == .dark }

    private var displayedCandidates: [CleanCandidate] {
        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = cleaner.candidates.filter { item in
            if let filterCategory, item.category != filterCategory {
                return false
            }
            switch tierFilter {
            case .all:
                break
            case .safeOnly:
                if item.safetyTier != .safe { return false }
            case .checkFirstOnly:
                if item.safetyTier != .checkFirst { return false }
            }
            if !trimmedQuery.isEmpty {
                let matchesTitle = item.title.lowercased().contains(trimmedQuery)
                let matchesPath = item.subtitle.lowercased().contains(trimmedQuery)
                let matchesCat = item.category.title.lowercased().contains(trimmedQuery)
                if !matchesTitle && !matchesPath && !matchesCat {
                    return false
                }
            }
            return true
        }

        switch sortOrder {
        case .sizeDesc:
            return filtered.sorted { lhs, rhs in
                if lhs.sizeBytes != rhs.sizeBytes { return lhs.sizeBytes > rhs.sizeBytes }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        case .ageDesc:
            return filtered.sorted { lhs, rhs in
                let d1 = lhs.lastModified ?? .distantFuture
                let d2 = rhs.lastModified ?? .distantFuture
                if d1 != d2 { return d1 < d2 }
                return lhs.sizeBytes > rhs.sizeBytes
            }
        case .nameAsc:
            return filtered.sorted { lhs, rhs in
                let cmp = lhs.title.localizedStandardCompare(rhs.title)
                if cmp != .orderedSame { return cmp == .orderedAscending }
                return lhs.sizeBytes > rhs.sizeBytes
            }
        }
    }

    private var displayedApps: [InstalledAppTarget] {
        let q = appSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = cleaner.installedApps.filter { app in
            guard !q.isEmpty else { return true }
            return app.displayName.lowercased().contains(q)
                || app.bundleID.lowercased().contains(q)
        }
        switch appSortOrder {
        case .totalSizeDesc:
            return filtered.sorted { lhs, rhs in
                if lhs.totalSizeBytes != rhs.totalSizeBytes { return lhs.totalSizeBytes > rhs.totalSizeBytes }
                return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
        case .residualSizeDesc:
            return filtered.sorted { lhs, rhs in
                if lhs.residualSizeBytes != rhs.residualSizeBytes { return lhs.residualSizeBytes > rhs.residualSizeBytes }
                return lhs.totalSizeBytes > rhs.totalSizeBytes
            }
        case .nameAsc:
            return filtered.sorted { lhs, rhs in
                lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
        }
    }

    private var maxCandidateBytes: UInt64 {
        max(cleaner.candidates.first?.sizeBytes ?? 1, 1)
    }

    var body: some View {
        Group {
            switch cleaner.mode {
            case .junkClean:
                junkCleanWorkspace
            case .appUninstall:
                appUninstallWorkspace
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(MonitorPalette.emerald, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(MonitorPalette.emerald.opacity(0.08))
                    )
                    .overlay {
                        HStack(spacing: 8) {
                            Image(systemName: "app.badge.checkmark")
                                .font(.system(size: 16, weight: .semibold))
                            Text(L10n.tr("松开以解析该 .app 本体与关联残留文件", "Drop .app bundle to inspect its associated files"))
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(MonitorPalette.emerald, in: .capsule)
                    }
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDroppedProviders(providers)
        }
        .onAppear {
            cleaner.refreshDiskSpace()
            if cleaner.mode == .junkClean && cleaner.lastScanDate == nil && !cleaner.isScanning {
                cleaner.scan()
            } else if cleaner.mode == .appUninstall && cleaner.lastAppScanDate == nil && !cleaner.isScanningApps {
                cleaner.scanApps()
            }
        }
        .onChange(of: cleaner.mode) { _, newMode in
            confirmingTrash = false
            confirmingAppTrash = false
            if newMode == .junkClean && cleaner.lastScanDate == nil && !cleaner.isScanning {
                cleaner.scan()
            } else if newMode == .appUninstall && cleaner.lastAppScanDate == nil && !cleaner.isScanningApps {
                cleaner.scanApps()
            }
        }
        .onChange(of: cleaner.selectedCount) { _, newCount in
            if newCount == 0 {
                confirmingTrash = false
            }
        }
        .onChange(of: cleaner.selectedAppItemCount) { _, newCount in
            if newCount == 0 {
                confirmingAppTrash = false
            }
        }
    }

    // MARK: - Top Header Bar with Mode Switcher (Preserves y = 50 pt First-Card Alignment)

    private func topSectionHeader(title: String) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            Spacer(minLength: 8)
        }
        .frame(height: 15)
        .overlay(alignment: .trailing) {
            modeSwitcherPill
        }
    }

    private var modeSwitcherPill: some View {
        HStack(spacing: 2) {
            ForEach(CleanerMode.allCases) { item in
                let isSelected = cleaner.mode == item
                HStack(spacing: 4) {
                    Image(systemName: item.icon)
                        .font(.system(size: 10, weight: .semibold))
                    Text(item.title)
                        .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                        .fixedSize(horizontal: true, vertical: false)
                }
                .foregroundStyle(isSelected ? .primary : .secondary)
                .padding(.horizontal, 9)
                .frame(height: 20)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(isDark ? Color.white.opacity(0.16) : Color.white)
                            .shadow(color: .black.opacity(isDark ? 0.22 : 0.06), radius: 1.5, y: 0.5)
                            .overlay {
                                Capsule().strokeBorder(borderColor, lineWidth: 0.5)
                            }
                    }
                }
                .contentShape(.capsule)
                .onTapGesture {
                    guard cleaner.mode != item else { return }
                    withAnimation(.snappy(duration: 0.16)) {
                        cleaner.mode = item
                    }
                }
            }
        }
        .padding(2)
        .background(
            isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.05),
            in: .capsule
        )
    }

    // MARK: - Mode 1: Junk & Cache Clean Workspace

    private var junkCleanWorkspace: some View {
        VStack(alignment: .leading, spacing: 18) {
            overviewAndBentoGroup
            itemsWorkspaceGroup
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var overviewAndBentoGroup: some View {
        VStack(alignment: .leading, spacing: 7) {
            topSectionHeader(title: L10n.tr("存储概览与分类筛选", "Storage Overview & Categories"))

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(MonitorPalette.emerald.opacity(isDark ? 0.18 : 0.12))
                        Image(systemName: "internaldrive.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(MonitorPalette.emerald)
                    }
                    .frame(width: 34, height: 34)

                    VStack(alignment: .leading, spacing: 2.5) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(
                                L10n.tr(
                                    "可用 \(SystemMetrics.formatBytes(cleaner.diskSpace.availableBytes))",
                                    "\(SystemMetrics.formatBytes(cleaner.diskSpace.availableBytes)) Free"
                                )
                            )
                            .font(.system(size: 15, weight: .bold).monospacedDigit())
                            .foregroundStyle(.primary)

                            Text(
                                L10n.tr(
                                    "/ 共 \(SystemMetrics.formatBytes(cleaner.diskSpace.totalBytes))（\(SystemMetrics.formatPercentage(cleaner.diskSpace.usedFraction))）",
                                    "of \(SystemMetrics.formatBytes(cleaner.diskSpace.totalBytes)) (\(SystemMetrics.formatPercentage(cleaner.diskSpace.usedFraction)))"
                                )
                            )
                            .font(.system(size: 11.5, weight: .regular).monospacedDigit())
                            .foregroundStyle(.secondary)
                        }
                        .lineLimit(1)

                        statusSubtitleView
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    staleThresholdPicker
                    actionButtons
                        .layoutPriority(1)
                }

                segmentedStorageBar

                HStack(spacing: 8) {
                    ForEach(CleanCategory.allCases) { category in
                        bentoCategoryCard(category)
                    }
                }
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isDark ? Color.white.opacity(0.05) : Color.white)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(borderColor, lineWidth: 0.5)
                    }
            }
        }
    }

    @ViewBuilder
    private var statusSubtitleView: some View {
        if cleaner.selectedBytes > 0 {
            HStack(spacing: 5) {
                Circle()
                    .fill(MonitorPalette.emerald)
                    .frame(width: 6, height: 6)
                Text(
                    L10n.tr(
                        "已选 \(cleaner.selectedCount) 项 · 可释放 \(CleanCandidate.formatBytes(cleaner.selectedBytes))（移入废纸篓）",
                        "\(cleaner.selectedCount) selected · \(CleanCandidate.formatBytes(cleaner.selectedBytes)) to Trash"
                    )
                )
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(MonitorPalette.emerald)
                .lineLimit(1)
            }
        } else if let report = cleaner.lastReport, report.trashedCount > 0 {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(MonitorPalette.cyan)
                Text(
                    L10n.tr(
                        "已将 \(report.trashedCount) 项移入废纸篓（\(CleanCandidate.formatBytes(report.freedBytes))）",
                        "Moved \(report.trashedCount) items (\(CleanCandidate.formatBytes(report.freedBytes))) to Trash"
                    )
                )
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(MonitorPalette.cyan)
                .lineLimit(1)

                Text(L10n.tr("打开废纸篓", "Open Trash"))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .underline()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        cleaner.openTrashInFinder()
                    }
            }
        } else {
            Text(
                L10n.tr(
                    "白名单扫描 · 自动跳过运行中应用与符号链接",
                    "Allowlist-only · Skips running apps and symlinks"
                )
            )
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    private var segmentedStorageBar: some View {
        GeometryReader { geo in
            let fullWidth = max(geo.size.width, 100)
            let totalDisk = Double(max(cleaner.diskSpace.totalBytes, 1))
            let usedFraction = cleaner.diskSpace.usedFraction
            let totalUsedWidth = max(CGFloat(usedFraction) * fullWidth, 16)

            let catWidths: [(CleanCategory, CGFloat)] = CleanCategory.allCases.map { cat in
                let bytes = Double(cleaner.categoryBytes(cat))
                guard bytes > 0 else { return (cat, 0) }
                let raw = CGFloat(bytes / totalDisk) * fullWidth
                return (cat, min(max(raw, 14), totalUsedWidth * 0.20))
            }
            let sumCatWidth = catWidths.reduce(CGFloat(0)) { $0 + $1.1 }
            let baseSystemWidth = max(totalUsedWidth - sumCatWidth, 12)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.06))
                    .frame(width: fullWidth, height: 7)

                HStack(spacing: 1.5) {
                    Rectangle()
                        .fill(isDark ? Color.white.opacity(0.28) : Color.black.opacity(0.22))
                        .frame(width: baseSystemWidth, height: 7)

                    ForEach(catWidths, id: \.0.id) { cat, w in
                        if w > 0 {
                            Rectangle()
                                .fill(cat.accentColor)
                                .frame(width: w, height: 7)
                        }
                    }
                }
                .frame(height: 7)
                .clipShape(.capsule)
            }
        }
        .frame(height: 7)
    }

    private func bentoCategoryCard(_ category: CleanCategory) -> some View {
        let totalCount = cleaner.categoryCandidateCount(category)
        let selectedCount = cleaner.selectedCategoryCandidateCount(category)
        let catBytes = cleaner.categoryBytes(category)
        let isSelected = cleaner.isCategorySelected(category)
        let isFiltered = filterCategory == category
        let accent = category.accentColor

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(accent.opacity(isDark ? 0.20 : 0.12))
                    Image(systemName: category.icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(accent)
                }
                .frame(width: 22, height: 22)

                if totalCount > 0 {
                    Text("\(selectedCount)/\(totalCount)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 4.5)
                        .padding(.vertical, 1)
                        .background(
                            isDark ? Color.white.opacity(0.07) : Color.black.opacity(0.05),
                            in: .capsule
                        )
                }

                Spacer(minLength: 0)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(
                        totalCount == 0
                            ? Color.secondary.opacity(0.30)
                            : (isSelected ? accent : Color.secondary.opacity(0.65))
                    )
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard totalCount > 0 else { return }
                        confirmingTrash = false
                        cleaner.toggleCategory(category)
                    }
            }

            VStack(alignment: .leading, spacing: 1.5) {
                Text(category.shortTitle)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(cleaner.lastScanDate == nil ? "--" : CleanCandidate.formatBytes(catBytes))
                    .font(.system(size: 13, weight: .bold).monospacedDigit())
                    .foregroundStyle(catBytes > 0 ? .primary : .secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    isFiltered
                        ? accent.opacity(isDark ? 0.14 : 0.08)
                        : (isDark ? Color.white.opacity(0.04) : Color.black.opacity(0.025))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            isFiltered ? accent.opacity(0.75) : borderColor,
                            lineWidth: isFiltered ? 1.2 : 0.5
                        )
                }
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture {
            withAnimation(.snappy(duration: 0.15)) {
                filterCategory = (filterCategory == category) ? nil : category
            }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 6) {
            let scanTitle = cleaner.isScanning
                ? L10n.tr("扫描中…", "Scanning…")
                : (cleaner.lastScanDate == nil ? L10n.tr("扫描", "Scan") : L10n.tr("重扫", "Rescan"))

            HStack(spacing: 4) {
                Image(systemName: cleaner.isScanning ? "hourglass" : "arrow.clockwise")
                    .font(.system(size: 10.5, weight: .semibold))
                Text(scanTitle)
                    .font(.system(size: 11.5, weight: .medium))
            }
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.05),
                in: .capsule
            )
            .overlay {
                Capsule().strokeBorder(borderColor, lineWidth: 0.5)
            }
            .contentShape(.capsule)
            .onTapGesture {
                guard !cleaner.isScanning && !cleaner.isCleaning else { return }
                confirmingTrash = false
                cleaner.scan()
            }

            if cleaner.selectedCount > 0 {
                let trashLabel = confirmingTrash
                    ? L10n.tr("确认移入", "Confirm")
                    : L10n.tr("移入废纸篓", "Move to Trash")

                HStack(spacing: 4) {
                    Image(systemName: confirmingTrash ? "checkmark.circle.fill" : "trash.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                    Text(trashLabel)
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(.white)
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(
                    confirmingTrash ? MonitorPalette.orange : MonitorPalette.emerald,
                    in: .capsule
                )
                .contentShape(.capsule)
                .onTapGesture {
                    guard !cleaner.isScanning && !cleaner.isCleaning else { return }
                    if confirmingTrash {
                        confirmingTrash = false
                        _ = cleaner.trashSelected()
                    } else {
                        withAnimation(.snappy(duration: 0.15)) {
                            confirmingTrash = true
                        }
                    }
                }
            }
        }
    }

    private var itemsWorkspaceGroup: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 6) {
                HStack(spacing: 5) {
                    Text(
                        filterCategory.map {
                            L10n.tr("明细 · \($0.shortTitle)", "\($0.shortTitle)")
                        } ?? L10n.tr("扫描明细", "Items")
                    )
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                    if cleaner.lastScanDate != nil {
                        Text("\(displayedCandidates.count)")
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5.5)
                            .padding(.vertical, 1)
                            .background(
                                isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.06),
                                in: .capsule
                            )
                    }

                    if filterCategory != nil {
                        Text(L10n.tr("全部", "All"))
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(MonitorPalette.emerald)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.snappy(duration: 0.15)) {
                                    filterCategory = nil
                                }
                            }
                    }
                }
                .padding(.leading, 4)

                Spacer(minLength: 4)

                searchBox
                tierFilterPicker
                sortOrderButton
                quickSelectButton
            }

            Group {
                if cleaner.isScanning {
                    placeholderView(
                        icon: "sparkles",
                        title: L10n.tr("正在按白名单并发扫描…", "Scanning allowlisted caches & leftovers…"),
                        subtitle: L10n.tr("自动跳过运行中应用与符号链接，不触碰隐私容器", "Skipping running applications and symbolic links")
                    ) {
                        cleaner.scan()
                    }
                } else if cleaner.lastScanDate == nil {
                    placeholderView(
                        icon: "externaldrive.badge.checkmark",
                        title: L10n.tr("按需扫描，平时后台 0 开销", "On-Demand Scan · Zero Background Overhead"),
                        subtitle: L10n.tr("点击右上角「扫描」检查应用缓存、开发工具、构建产物与卸载残留", "Click Scan above to inspect rebuildable caches, builds, and leftovers"),
                        showScanButton: true
                    ) {
                        cleaner.scan()
                    }
                } else if displayedCandidates.isEmpty {
                    placeholderView(
                        icon: "checkmark.seal.fill",
                        title: L10n.tr("未发现匹配项", "No Matching Items"),
                        subtitle: searchQuery.isEmpty
                            ? L10n.tr("当前分类或筛选条件下没有可清理项", "No cleanable items match the current filter")
                            : L10n.tr("未找到包含「\(searchQuery)」的扫描项", "No items matching \"\(searchQuery)\"")
                    ) {
                        cleaner.scan()
                    }
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(displayedCandidates.enumerated()), id: \.element.id) { index, item in
                                if index > 0 {
                                    rowDivider
                                }
                                candidateRow(item)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .defaultScrollAnchor(.top)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isDark ? Color.white.opacity(0.05) : Color.white)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(borderColor, lineWidth: 0.5)
                    }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    // MARK: - Mode 2: App Uninstaller Workspace (Master-Detail Split View)

    private var appUninstallWorkspace: some View {
        VStack(alignment: .leading, spacing: 18) {
            appUninstallOverviewGroup
            appUninstallSplitGroup
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var appUninstallOverviewGroup: some View {
        VStack(alignment: .leading, spacing: 7) {
            topSectionHeader(title: L10n.tr("应用卸载与数据重置（支持拖入 .app）", "App Uninstaller & Reset (Drop .app Supported)"))

            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(MonitorPalette.purple.opacity(isDark ? 0.20 : 0.12))
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(MonitorPalette.purple)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 2.5) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(
                            L10n.tr(
                                "已发现 \(cleaner.installedApps.count) 款应用",
                                "\(cleaner.installedApps.count) Installed Apps"
                            )
                        )
                        .font(.system(size: 15, weight: .bold).monospacedDigit())
                        .foregroundStyle(.primary)

                        Text(
                            L10n.tr(
                                "/ 共占用 \(CleanCandidate.formatBytes(cleaner.totalInstalledAppsBytes))",
                                "· \(CleanCandidate.formatBytes(cleaner.totalInstalledAppsBytes)) Total"
                            )
                        )
                        .font(.system(size: 11.5, weight: .regular).monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)

                    appUninstallSubtitleView
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                appActionButtons
                    .layoutPriority(1)
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isDark ? Color.white.opacity(0.05) : Color.white)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(borderColor, lineWidth: 0.5)
                    }
            }
        }
    }

    @ViewBuilder
    private var appUninstallSubtitleView: some View {
        if let report = cleaner.lastUninstallReport, report.trashedCount > 0 {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(MonitorPalette.cyan)
                Text(
                    L10n.tr(
                        "已移入废纸篓 \(report.trashedCount) 项（\(CleanCandidate.formatBytes(report.freedBytes))）",
                        "Moved \(report.trashedCount) items (\(CleanCandidate.formatBytes(report.freedBytes))) to Trash"
                    )
                )
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(MonitorPalette.cyan)
                .lineLimit(1)

                Text(L10n.tr("打开废纸篓", "Open Trash"))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .underline()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        cleaner.openTrashInFinder()
                    }
            }
        } else if let app = cleaner.selectedApp, cleaner.selectedAppItemCount > 0 {
            let fullUninstall = cleaner.isSelectedAppBundleChecked
            HStack(spacing: 5) {
                Circle()
                    .fill(fullUninstall ? MonitorPalette.emerald : MonitorPalette.indigo)
                    .frame(width: 6, height: 6)
                Text(
                    fullUninstall
                        ? L10n.tr(
                            "彻底卸载「\(app.displayName)」· 已选 \(cleaner.selectedAppItemCount) 项（\(CleanCandidate.formatBytes(cleaner.selectedAppBytes)) 进废纸篓）",
                            "Uninstall \(app.displayName) · \(cleaner.selectedAppItemCount) items (\(CleanCandidate.formatBytes(cleaner.selectedAppBytes)))"
                        )
                        : L10n.tr(
                            "仅重置「\(app.displayName)」数据 · 已选 \(cleaner.selectedAppItemCount) 项（\(CleanCandidate.formatBytes(cleaner.selectedAppBytes))，保留应用本体）",
                            "Reset \(app.displayName) data · \(cleaner.selectedAppItemCount) items (\(CleanCandidate.formatBytes(cleaner.selectedAppBytes)), keeps .app)"
                        )
                )
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(fullUninstall ? MonitorPalette.emerald : MonitorPalette.indigo)
                .lineLimit(1)
            }
        } else {
            Text(
                L10n.tr(
                    "选择左侧应用或从访达拖入 .app，自动关联 Application Support、Caches、Preferences 与容器",
                    "Select an app or drop a .app bundle to inspect its bundle and ~/Library leftovers"
                )
            )
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    private var appSearchBox: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField(L10n.tr("搜索已安装应用…", "Filter applications…"), text: $appSearchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))

            if !appSearchQuery.isEmpty {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        appSearchQuery = ""
                    }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
    }

    private var appActionButtons: some View {
        HStack(spacing: 6) {
            let scanTitle = cleaner.isScanningApps
                ? L10n.tr("扫描中…", "Scanning…")
                : L10n.tr("刷新", "Rescan")

            HStack(spacing: 4) {
                Image(systemName: cleaner.isScanningApps ? "hourglass" : "arrow.clockwise")
                    .font(.system(size: 10.5, weight: .semibold))
                Text(scanTitle)
                    .font(.system(size: 11.5, weight: .medium))
            }
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.05),
                in: .capsule
            )
            .overlay {
                Capsule().strokeBorder(borderColor, lineWidth: 0.5)
            }
            .contentShape(.capsule)
            .onTapGesture {
                guard !cleaner.isScanningApps && !cleaner.isCleaning else { return }
                confirmingAppTrash = false
                cleaner.scanApps()
            }

            if cleaner.selectedAppItemCount > 0 {
                let isFullUninstall = cleaner.isSelectedAppBundleChecked
                let actionLabel: String = {
                    if confirmingAppTrash {
                        return L10n.tr("确认移入", "Confirm")
                    }
                    return isFullUninstall
                        ? L10n.tr("卸载至废纸篓", "Uninstall")
                        : L10n.tr("重置数据", "Reset Data")
                }()

                HStack(spacing: 4) {
                    Image(systemName: confirmingAppTrash ? "checkmark.circle.fill" : "trash.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                    Text(actionLabel)
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(.white)
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(
                    confirmingAppTrash
                        ? MonitorPalette.orange
                        : (isFullUninstall ? MonitorPalette.emerald : MonitorPalette.indigo),
                    in: .capsule
                )
                .contentShape(.capsule)
                .onTapGesture {
                    guard !cleaner.isScanningApps && !cleaner.isCleaning else { return }
                    if confirmingAppTrash {
                        confirmingAppTrash = false
                        _ = cleaner.trashSelectedAppItems()
                    } else {
                        withAnimation(.snappy(duration: 0.15)) {
                            confirmingAppTrash = true
                        }
                    }
                }
            }
        }
    }

    private var appUninstallSplitGroup: some View {
        HStack(alignment: .top, spacing: 12) {
            // Left Master Column: Installed Apps List (216 pt)
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .center, spacing: 4) {
                    Text(L10n.tr("应用列表", "Applications"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)

                    Text("\(displayedApps.count)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.06),
                            in: .capsule
                        )

                    Spacer(minLength: 4)

                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 9, weight: .semibold))
                        Text(appSortOrder.title)
                            .font(.system(size: 10, weight: .medium))
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6.5)
                    .frame(height: 20)
                    .background(
                        isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.045),
                        in: .capsule
                    )
                    .contentShape(.capsule)
                    .onTapGesture {
                        let all = AppListSortOrder.allCases
                        if let idx = all.firstIndex(of: appSortOrder) {
                            appSortOrder = all[(idx + 1) % all.count]
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 0) {
                    appSearchBox
                    rowDivider

                    Group {
                        if cleaner.isScanningApps {
                            VStack(spacing: 8) {
                                Image(systemName: "square.stack.3d.up.fill")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(MonitorPalette.purple)
                                Text(L10n.tr("正在扫描应用程序…", "Scanning Applications…"))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if displayedApps.isEmpty {
                            VStack(spacing: 6) {
                                Image(systemName: "app.dashed")
                                    .font(.system(size: 20))
                                    .foregroundStyle(.secondary)
                                Text(L10n.tr("未找到匹配应用", "No Apps Found"))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            ScrollView(.vertical, showsIndicators: true) {
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(Array(displayedApps.enumerated()), id: \.element.id) { index, app in
                                        if index > 0 {
                                            rowDivider
                                        }
                                        installedAppRow(app)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                            }
                            .defaultScrollAnchor(.top)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isDark ? Color.white.opacity(0.05) : Color.white)
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(borderColor, lineWidth: 0.5)
                        }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .frame(width: 216)

            // Right Detail Column: Selected App Breakdown & Residual Files
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .center, spacing: 6) {
                    Text(
                        cleaner.selectedApp.map {
                            L10n.tr("关联文件明细 · \($0.displayName)", "Associated Files · \($0.displayName)")
                        } ?? L10n.tr("关联文件明细", "Associated Files")
                    )
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 4)

                    Spacer(minLength: 4)

                    if cleaner.selectedApp != nil {
                        appResidualQuickButtons
                    }
                }

                Group {
                    if let app = cleaner.selectedApp {
                        VStack(alignment: .leading, spacing: 0) {
                            selectedAppHeroHeader(app)
                            rowDivider
                            ScrollView(.vertical, showsIndicators: true) {
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(Array(app.residuals.enumerated()), id: \.element.id) { index, item in
                                        if index > 0 {
                                            rowDivider
                                        }
                                        residualItemRow(item, app: app)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                            }
                            .defaultScrollAnchor(.top)
                        }
                    } else {
                        placeholderView(
                            icon: "square.stack.3d.up.fill",
                            title: L10n.tr("选择应用查看关联文件", "Select an Application"),
                            subtitle: L10n.tr("从左侧列表选择应用，或直接将 .app 拖入此处", "Choose an app on the left or drag a .app bundle here"),
                            showScanButton: cleaner.lastAppScanDate == nil
                        ) {
                            cleaner.scanApps()
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isDark ? Color.white.opacity(0.05) : Color.white)
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(borderColor, lineWidth: 0.5)
                        }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func installedAppRow(_ app: InstalledAppTarget) -> some View {
        let isSelected = cleaner.selectedApp?.id == app.id
        let isHovered = hoveredAppID == app.id
        let isRunning = cleaner.isAppRunning(app)

        return HStack(spacing: 9) {
            Image(nsImage: cleaner.icon(for: app))
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1.5) {
                HStack(spacing: 4) {
                    Text(app.displayName)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if isRunning {
                        Circle()
                            .fill(MonitorPalette.emerald)
                            .frame(width: 5.5, height: 5.5)
                    }
                }

                Text(
                    app.residualSizeBytes > 0
                        ? L10n.tr(
                            "残留 \(CleanCandidate.formatBytes(app.residualSizeBytes))",
                            "+\(CleanCandidate.formatBytes(app.residualSizeBytes)) data"
                        )
                        : L10n.tr("无附加残留", "Bundle only")
                )
                .font(.system(size: 10, weight: .regular).monospacedDigit())
                .foregroundStyle(app.residualSizeBytes > 0 ? MonitorPalette.purple : .secondary)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(CleanCandidate.formatBytes(app.totalSizeBytes))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(isSelected ? .primary : .secondary)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 10)
        .frame(height: 46)
        .background {
            if isSelected {
                Rectangle()
                    .fill(MonitorPalette.purple.opacity(isDark ? 0.18 : 0.10))
            } else if isHovered {
                Rectangle()
                    .fill(isDark ? Color.white.opacity(0.04) : Color.black.opacity(0.025))
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredAppID = hovering ? app.id : (hoveredAppID == app.id ? nil : hoveredAppID)
        }
        .onTapGesture {
            confirmingAppTrash = false
            cleaner.selectApp(app.id)
        }
    }

    private func selectedAppHeroHeader(_ app: InstalledAppTarget) -> some View {
        let isRunning = cleaner.isAppRunning(app)

        return HStack(spacing: 11) {
            Image(nsImage: cleaner.icon(for: app))
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(app.displayName)
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text("v\(app.version)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5.5)
                        .padding(.vertical, 1)
                        .background(
                            isDark ? Color.white.opacity(0.07) : Color.black.opacity(0.05),
                            in: .capsule
                        )

                    if isRunning {
                        Text(L10n.tr("运行中", "Running"))
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(MonitorPalette.amber)
                            .padding(.horizontal, 5.5)
                            .padding(.vertical, 1)
                            .background(MonitorPalette.amber.opacity(0.15), in: .capsule)
                    }
                }

                Text(
                    L10n.tr(
                        "\(app.bundleID) · 本体 \(CleanCandidate.formatBytes(app.bundleSizeBytes)) · 关联 \(CleanCandidate.formatBytes(app.residualSizeBytes))",
                        "\(app.bundleID) · App \(CleanCandidate.formatBytes(app.bundleSizeBytes)) · Data \(CleanCandidate.formatBytes(app.residualSizeBytes))"
                    )
                )
                .font(.system(size: 10.5, weight: .regular).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "folder")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(
                    isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    cleaner.revealInFinder(app.bundleURL)
                }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var appResidualQuickButtons: some View {
        HStack(spacing: 4) {
            let isFull = cleaner.isSelectedAppBundleChecked
            let hasAny = cleaner.selectedAppItemCount > 0

            Text(L10n.tr("完整卸载", "Full Uninstall"))
                .font(.system(size: 10, weight: isFull ? .semibold : .regular))
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(isFull ? MonitorPalette.emerald : .secondary)
                .padding(.horizontal, 7)
                .frame(height: 20)
                .background(
                    isFull
                        ? MonitorPalette.emerald.opacity(0.14)
                        : (isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.045)),
                    in: .capsule
                )
                .contentShape(.capsule)
                .onTapGesture {
                    confirmingAppTrash = false
                    cleaner.selectAllSafeAppResiduals()
                }

            Text(L10n.tr("仅清数据", "Reset Data"))
                .font(.system(size: 10, weight: (!isFull && hasAny) ? .semibold : .regular))
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle((!isFull && hasAny) ? MonitorPalette.indigo : .secondary)
                .padding(.horizontal, 7)
                .frame(height: 20)
                .background(
                    (!isFull && hasAny)
                        ? MonitorPalette.indigo.opacity(0.14)
                        : (isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.045)),
                    in: .capsule
                )
                .contentShape(.capsule)
                .onTapGesture {
                    confirmingAppTrash = false
                    cleaner.selectAppResidualsOnly()
                }

            if hasAny {
                Text(L10n.tr("清空", "Clear"))
                    .font(.system(size: 10, weight: .medium))
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6.5)
                    .frame(height: 20)
                    .background(
                        isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.045),
                        in: .capsule
                    )
                    .contentShape(.capsule)
                    .onTapGesture {
                        confirmingAppTrash = false
                        cleaner.deselectAllAppResiduals()
                    }
            }
        }
    }

    private func residualItemRow(_ item: AppResidualItem, app: InstalledAppTarget) -> some View {
        let isSelected = cleaner.selectedResidualIDs.contains(item.id)
        let isHovered = hoveredResidualID == item.id
        let accent = item.kind.accentColor

        return HStack(spacing: 10) {
            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(isSelected ? accent : .secondary.opacity(0.65))
                .frame(width: 18, height: 18)

            ZStack {
                RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                    .fill(accent.opacity(isDark ? 0.18 : 0.11))
                Image(systemName: item.kind.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent)
            }
            .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 1.5) {
                HStack(spacing: 5) {
                    Text(item.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(item.kind.title)
                        .font(.system(size: 9.5, weight: .medium))
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(accent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(accent.opacity(0.13), in: .capsule)

                    if item.safetyTier == .checkFirst {
                        Text(item.safetyTier.badgeTitle)
                            .font(.system(size: 9.5, weight: .semibold))
                            .fixedSize(horizontal: true, vertical: false)
                            .foregroundStyle(MonitorPalette.amber)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(MonitorPalette.amber.opacity(0.15), in: .capsule)
                    }
                }

                Text(item.subtitle)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(CleanCandidate.formatBytes(item.sizeBytes))
                .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(isSelected ? .primary : .secondary)
                .fixedSize(horizontal: true, vertical: false)

            Image(systemName: "folder")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(isHovered ? .primary : .secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
                .onTapGesture {
                    cleaner.revealInFinder(item.url)
                }
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(
            isHovered
                ? (isDark ? Color.white.opacity(0.035) : Color.black.opacity(0.02))
                : Color.clear
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredResidualID = hovering ? item.id : (hoveredResidualID == item.id ? nil : hoveredResidualID)
        }
        .onTapGesture {
            confirmingAppTrash = false
            cleaner.toggleResidual(item.id)
        }
        .contextMenu {
            Button(
                isSelected
                    ? L10n.tr("取消勾选", "Deselect")
                    : L10n.tr("勾选此项", "Select")
            ) {
                confirmingAppTrash = false
                cleaner.toggleResidual(item.id)
            }
            Button(L10n.tr("在访达中显示", "Reveal in Finder")) {
                cleaner.revealInFinder(item.url)
            }
            Button(L10n.tr("复制完整路径", "Copy Path")) {
                cleaner.copyPath(item.url)
            }
        }
    }

    // MARK: - Shared Controls (Junk Mode)

    private var searchBox: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField(L10n.tr("搜索…", "Search…"), text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .frame(width: 78)

            if !searchQuery.isEmpty {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        searchQuery = ""
                    }
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(
            isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.05),
            in: .capsule
        )
    }

    private var staleThresholdPicker: some View {
        HStack(spacing: 1) {
            Image(systemName: "clock")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 5)
                .padding(.trailing, 1)

            ForEach(CleanStaleThreshold.allCases, id: \.self) { option in
                let isSelected = option == preferences.cleanStaleThreshold
                Text(option.displayName)
                    .font(.system(size: 10.5, weight: isSelected ? .semibold : .regular))
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .padding(.horizontal, 5.5)
                    .frame(height: 20)
                    .background {
                        if isSelected {
                            Capsule()
                                .fill(isDark ? Color.white.opacity(0.15) : Color.white)
                                .overlay {
                                    Capsule().strokeBorder(borderColor, lineWidth: 0.5)
                                }
                        }
                    }
                    .contentShape(.capsule)
                    .onTapGesture {
                        guard preferences.cleanStaleThreshold != option else { return }
                        preferences.cleanStaleThreshold = option
                        if cleaner.lastScanDate != nil && !cleaner.isScanning {
                            cleaner.scan()
                        }
                    }
            }
        }
        .padding(3)
        .background(
            isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.05),
            in: .capsule
        )
    }

    private var tierFilterPicker: some View {
        HStack(spacing: 1) {
            ForEach(CleanTierFilter.allCases) { mode in
                let isSelected = tierFilter == mode
                Text(mode.title)
                    .font(.system(size: 10.5, weight: isSelected ? .semibold : .regular))
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .padding(.horizontal, 6.5)
                    .frame(height: 18)
                    .background {
                        if isSelected {
                            Capsule()
                                .fill(isDark ? Color.white.opacity(0.15) : Color.white)
                                .overlay {
                                    Capsule().strokeBorder(borderColor, lineWidth: 0.5)
                                }
                        }
                    }
                    .contentShape(.capsule)
                    .onTapGesture {
                        withAnimation(.snappy(duration: 0.14)) {
                            tierFilter = mode
                        }
                    }
            }
        }
        .padding(2)
        .background(
            isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.05),
            in: .capsule
        )
    }

    private var sortOrderButton: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 9.5, weight: .semibold))
            Text(sortOrder.displayName)
                .font(.system(size: 10.5, weight: .medium))
                .fixedSize(horizontal: true, vertical: false)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(
            isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.045),
            in: .capsule
        )
        .contentShape(.capsule)
        .onTapGesture {
            let all = CleanSortOrder.allCases
            if let idx = all.firstIndex(of: sortOrder) {
                sortOrder = all[(idx + 1) % all.count]
            }
        }
    }

    private var quickSelectButton: some View {
        let hasSelection = cleaner.selectedCount > 0
        return Text(hasSelection ? L10n.tr("清空", "Clear") : L10n.tr("选安全项", "Safe"))
            .font(.system(size: 10.5, weight: .medium))
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(
                isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.045),
                in: .capsule
            )
            .contentShape(.capsule)
            .onTapGesture {
                confirmingTrash = false
                if hasSelection {
                    cleaner.deselectAll()
                } else {
                    cleaner.selectSafeDefaults()
                }
            }
    }

    private func candidateRow(_ item: CleanCandidate) -> some View {
        let isSelected = cleaner.selectedIDs.contains(item.id)
        let isHovered = hoveredCandidateID == item.id
        let accent = item.category.accentColor
        let sizeRatio = min(max(Double(item.sizeBytes) / Double(maxCandidateBytes), 0.06), 1.0)

        return HStack(spacing: 10) {
            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isSelected ? accent : .secondary.opacity(0.65))
                .frame(width: 18, height: 18)

            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(accent.opacity(isDark ? 0.18 : 0.11))
                Image(systemName: item.category.icon)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(accent)
            }
            .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if item.safetyTier == .checkFirst {
                        Text(item.safetyTier.badgeTitle)
                            .font(.system(size: 9.5, weight: .semibold))
                            .fixedSize(horizontal: true, vertical: false)
                            .foregroundStyle(MonitorPalette.amber)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(MonitorPalette.amber.opacity(0.15), in: .capsule)
                    } else if filterCategory == nil {
                        Text(item.category.shortTitle)
                            .font(.system(size: 9.5, weight: .medium))
                            .fixedSize(horizontal: true, vertical: false)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.045),
                                in: .capsule
                            )
                    }

                    if let age = item.formattedAge() {
                        Text(age)
                            .font(.system(size: 10, weight: .regular).monospacedDigit())
                            .fixedSize(horizontal: true, vertical: false)
                            .foregroundStyle(.tertiary)
                    }
                }

                Text(item.subtitle)
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 7) {
                ZStack(alignment: .trailing) {
                    Capsule()
                        .fill(isDark ? Color.white.opacity(0.07) : Color.black.opacity(0.05))
                        .frame(width: 38, height: 4)
                    Capsule()
                        .fill(accent.opacity(isSelected ? 0.85 : 0.40))
                        .frame(width: max(CGFloat(sizeRatio) * 38, 3), height: 4)
                }

                Text(CleanCandidate.formatBytes(item.sizeBytes))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .frame(width: 60, alignment: .trailing)
            }
            .fixedSize(horizontal: true, vertical: false)

            Image(systemName: "folder")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isHovered ? .primary : .secondary)
                .frame(width: 24, height: 24)
                .background(
                    isHovered
                        ? (isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.05))
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    cleaner.revealInFinder(item.url)
                }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(
            isHovered
                ? (isDark ? Color.white.opacity(0.035) : Color.black.opacity(0.02))
                : Color.clear
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredCandidateID = hovering ? item.id : (hoveredCandidateID == item.id ? nil : hoveredCandidateID)
        }
        .onTapGesture {
            confirmingTrash = false
            cleaner.toggleCandidate(item.id)
        }
        .contextMenu {
            Button(
                isSelected
                    ? L10n.tr("取消勾选", "Deselect")
                    : L10n.tr("勾选此项", "Select")
            ) {
                confirmingTrash = false
                cleaner.toggleCandidate(item.id)
            }
            Button(L10n.tr("在访达中显示", "Reveal in Finder")) {
                cleaner.revealInFinder(item.url)
            }
            Button(L10n.tr("复制完整路径", "Copy Path")) {
                cleaner.copyPath(item.url)
            }
            Divider()
            Button(L10n.tr("打开系统废纸篓", "Open Trash")) {
                cleaner.openTrashInFinder()
            }
        }
    }

    private func placeholderView(
        icon: String,
        title: String,
        subtitle: String,
        showScanButton: Bool = false,
        onScan: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(MonitorPalette.emerald.opacity(isDark ? 0.16 : 0.10))
                    .frame(width: 44, height: 44)
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(MonitorPalette.emerald)
            }

            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)

            Text(subtitle)
                .font(.system(size: 11.5, weight: .regular))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            if showScanButton {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .semibold))
                    Text(L10n.tr("立即扫描", "Scan Now"))
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(height: 30)
                .background(MonitorPalette.emerald, in: .capsule)
                .padding(.top, 4)
                .contentShape(.capsule)
                .onTapGesture {
                    onScan()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Finder .app Drag & Drop Handler

    private func handleDroppedProviders(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }) else {
            return false
        }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let resolvedURL: URL?
            if let data = item as? Data {
                resolvedURL = URL(dataRepresentation: data, relativeTo: nil)
            } else if let url = item as? URL {
                resolvedURL = url
            } else {
                resolvedURL = nil
            }
            guard let appURL = resolvedURL else { return }
            Task { @MainActor in
                _ = cleaner.handleDroppedAppURL(appURL)
            }
        }
        return true
    }

    // MARK: - Shared Form Chrome

    private var dividerColor: Color {
        isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
    }

    private var borderColor: Color {
        isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.06)
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(dividerColor)
            .frame(height: 0.5)
    }
}
