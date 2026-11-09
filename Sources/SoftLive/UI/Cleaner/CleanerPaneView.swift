import AppKit
import SwiftUI

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

/// Right-pane workspace for the `Cleaner` section inside `ControlCenterWindow`.
/// Maintains the exact same top-header offset (`y = 28 pt`), first-card top edge (`y = 50 pt`),
/// and `18 pt` group spacing as `Player`, `Monitor`, and `About`, while expanding its detail list
/// fluidly as the user resizes the window without ever overflowing the horizontal pane width.
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

    private var maxCandidateBytes: UInt64 {
        max(cleaner.candidates.first?.sizeBytes ?? 1, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            overviewAndBentoGroup
            itemsWorkspaceGroup
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            cleaner.refreshDiskSpace()
            if cleaner.lastScanDate == nil && !cleaner.isScanning {
                cleaner.scan()
            }
        }
        .onChange(of: cleaner.selectedCount) { _, newCount in
            if newCount == 0 {
                confirmingTrash = false
            }
        }
    }

    // MARK: - Section 1: Storage Hero & 4-Column Bento Categories

    private var overviewAndBentoGroup: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 8) {
                Text(L10n.tr("存储概览与分类筛选", "Storage Overview & Categories"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)

                Spacer(minLength: 8)

                staleThresholdPicker
            }
            .frame(height: 15)

            VStack(alignment: .leading, spacing: 12) {
                // Top Row: Volume status + Scan/Trash buttons
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

                    actionButtons
                        .layoutPriority(1)
                }

                // Segmented Storage Ribbon
                segmentedStorageBar

                // 4-Column Horizontal Bento Category Strip
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
            .frame(height: 28)
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
                .frame(height: 28)
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

    // MARK: - Section 2: Expansive Discovered Items Workspace

    private var itemsWorkspaceGroup: some View {
        VStack(alignment: .leading, spacing: 7) {
            // Toolbar header above the list card
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

            // Full-height flexible list card
            Group {
                if cleaner.isScanning {
                    placeholderView(
                        icon: "sparkles",
                        title: L10n.tr("正在按白名单并发扫描…", "Scanning allowlisted caches & leftovers…"),
                        subtitle: L10n.tr("自动跳过运行中应用与符号链接，不触碰隐私容器", "Skipping running applications and symbolic links")
                    )
                } else if cleaner.lastScanDate == nil {
                    placeholderView(
                        icon: "externaldrive.badge.checkmark",
                        title: L10n.tr("按需扫描，平时后台 0 开销", "On-Demand Scan · Zero Background Overhead"),
                        subtitle: L10n.tr("点击右上角「扫描」检查应用缓存、开发工具、构建产物与卸载残留", "Click Scan above to inspect rebuildable caches, builds, and leftovers"),
                        showScanButton: true
                    )
                } else if displayedCandidates.isEmpty {
                    placeholderView(
                        icon: "checkmark.seal.fill",
                        title: L10n.tr("未发现匹配项", "No Matching Items"),
                        subtitle: searchQuery.isEmpty
                            ? L10n.tr("当前分类或筛选条件下没有可清理项", "No cleanable items match the current filter")
                            : L10n.tr("未找到包含「\(searchQuery)」的扫描项", "No items matching \"\(searchQuery)\"")
                    )
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
                        guard preferences.cleanStaleThreshold != option else { return }
                        preferences.cleanStaleThreshold = option
                        if cleaner.lastScanDate != nil && !cleaner.isScanning {
                            cleaner.scan()
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
        showScanButton: Bool = false
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
                    cleaner.scan()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private func formGroup<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
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
}
