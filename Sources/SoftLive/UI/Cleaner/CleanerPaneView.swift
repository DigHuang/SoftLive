import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum CleanTierFilter: String, CaseIterable, Identifiable {
    case all
    case safeOnly
    case checkFirstOnly

    var id: String { rawValue }

    var menuTitle: String {
        switch self {
        case .all: L10n.tr("全部", "All")
        case .safeOnly: L10n.tr("安全", "Safe")
        case .checkFirstOnly: L10n.tr("需核对", "Check First")
        }
    }

    var buttonTitle: String {
        switch self {
        case .all: L10n.tr("全部级别", "All Tiers")
        case .safeOnly: L10n.tr("安全", "Safe")
        case .checkFirstOnly: L10n.tr("需核对", "Check First")
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
        case .totalSizeDesc: L10n.tr("总占用", "Total Size")
        case .residualSizeDesc: L10n.tr("关联数据", "Associated Data")
        case .nameAsc: L10n.tr("按名称", "By Name")
        }
    }
}

/// Right-pane workspace for the `Cleaner` section inside `ControlCenterWindow`.
/// Supports two integrated modes inside a single elevated Frost Instrument surface:
/// 1. `缓存与残留 (Junk & Caches)` — volume summary, text scope tabs, filterable lazy list, and pinned action bar;
/// 2. `应用卸载 (App Uninstaller)` — master-detail installed app browser, `.app` drag-and-drop,
///    full uninstallation, and residuals-only data reset.
struct CleanerPaneView: View {
    let cleaner: DiskCleaner
    let preferences: Preferences

    @Environment(\.colorScheme) private var colorScheme
    @State private var filterCategory: CleanCategory?
    @State private var tierFilter: CleanTierFilter = .all
    @State private var sortOrder: CleanSortOrder = .sizeDesc
    @State private var searchQuery: String = ""
    @State private var confirmingTrash = false

    // App Uninstaller UI state
    @State private var appSearchQuery: String = ""
    @State private var appSortOrder: AppListSortOrder = .totalSizeDesc
    @State private var confirmingAppTrash = false
    @State private var isDropTargeted = false

    private var isDark: Bool { colorScheme == .dark }

    private var modeBinding: Binding<CleanerMode> {
        Binding(
            get: { cleaner.mode },
            set: { newValue in
                guard cleaner.mode != newValue else { return }
                cleaner.clearDropError()
                cleaner.mode = newValue
            }
        )
    }

    // MARK: - Filtering & Sorting

    private func computeDisplayedCandidates() -> [CleanCandidate] {
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
                let matchesTitle = item.displayTitle.lowercased().contains(trimmedQuery)
                    || item.title.lowercased().contains(trimmedQuery)
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
                return lhs.displayTitle.localizedStandardCompare(rhs.displayTitle) == .orderedAscending
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
                let cmp = lhs.displayTitle.localizedStandardCompare(rhs.displayTitle)
                if cmp != .orderedSame { return cmp == .orderedAscending }
                return lhs.sizeBytes > rhs.sizeBytes
            }
        }
    }

    private func computeDisplayedApps() -> [InstalledAppTarget] {
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

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            topHeaderStrip

            Group {
                switch cleaner.mode {
                case .junkClean:
                    junkCleanSurface
                case .appUninstall:
                    appUninstallSurface
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(SoftLiveTheme.surface)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(SoftLiveTheme.hairline, lineWidth: 0.5)
                    }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay {
            if isDropTargeted {
                dropOverlay
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDroppedProviders(providers)
        }
        .onAppear {
            cleaner.refreshDiskSpace()
            cleaner.refreshRunningApps()
            if cleaner.mode == .junkClean && cleaner.lastScanDate == nil && !cleaner.isScanning {
                cleaner.scan()
            } else if cleaner.mode == .appUninstall && cleaner.lastAppScanDate == nil && !cleaner.isScanningApps {
                cleaner.scanApps()
            }
        }
        .task {
            for await _ in NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.didLaunchApplicationNotification) {
                cleaner.refreshRunningApps()
            }
        }
        .task {
            for await _ in NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.didTerminateApplicationNotification) {
                cleaner.refreshRunningApps()
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

    // MARK: - Top Header Strip (y = 28 pt, height = 15 pt, clear center for Zero-Jump Invariant)

    private var topHeaderStrip: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(L10n.tr("空间清理", "Cleaner"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.leading, 4)

            Spacer(minLength: 4)

            Picker("", selection: modeBinding) {
                ForEach(CleanerMode.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        }
        .frame(height: 15)
    }

    // MARK: - Mode 1: Junk & Caches Unified Surface

    private var junkCleanSurface: some View {
        let filtered = computeDisplayedCandidates()
        let now = Date.now

        return VStack(alignment: .leading, spacing: 0) {
            volumeAndStaleHeader
            horizontalHairline
            scopeFilterStrip
            horizontalHairline
            junkToolbar(displayedCandidates: filtered)
            horizontalHairline
            junkListRegion(filtered: filtered, now: now)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            horizontalHairline
            junkBottomActionBar
        }
    }

    private var volumeAndStaleHeader: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(
                        L10n.tr(
                            "\(SystemMetrics.formatBytes(cleaner.diskSpace.availableBytes)) 可用",
                            "\(SystemMetrics.formatBytes(cleaner.diskSpace.availableBytes)) Free"
                        )
                    )
                    .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.primary)

                    Text(
                        L10n.tr(
                            "/ \(SystemMetrics.formatBytes(cleaner.diskSpace.totalBytes))（已用 \(SystemMetrics.formatPercentage(cleaner.diskSpace.usedFraction))）",
                            "/ \(SystemMetrics.formatBytes(cleaner.diskSpace.totalBytes)) (\(SystemMetrics.formatPercentage(cleaner.diskSpace.usedFraction)) used)"
                        )
                    )
                    .font(.system(size: 11.5, weight: .regular).monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                .lineLimit(1)

                twoToneStorageBar
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            staleThresholdMenu
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var twoToneStorageBar: some View {
        GeometryReader { geo in
            let fullWidth = max(geo.size.width, 80)
            let totalDisk = Double(max(cleaner.diskSpace.totalBytes, 1))
            let usedWidth = min(max(CGFloat(cleaner.diskSpace.usedFraction) * fullWidth, 0), fullWidth)
            let reclaimableBytes = cleaner.totalScanBytes
            let rawReclaimable = CGFloat(Double(reclaimableBytes) / totalDisk) * fullWidth
            let reclaimableWidth = reclaimableBytes > 0
                ? min(max(rawReclaimable, 4), usedWidth)
                : 0
            let systemUsedWidth = max(usedWidth - reclaimableWidth, 0)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.06))
                    .frame(width: fullWidth, height: 4)

                HStack(spacing: 0) {
                    if systemUsedWidth > 0 {
                        Rectangle()
                            .fill(isDark ? Color.white.opacity(0.24) : Color.black.opacity(0.20))
                            .frame(width: systemUsedWidth, height: 4)
                    }
                    if reclaimableWidth > 0 {
                        Rectangle()
                            .fill(SoftLiveTheme.accent)
                            .frame(width: reclaimableWidth, height: 4)
                    }
                }
                .frame(maxWidth: fullWidth, maxHeight: 4, alignment: .leading)
                .clipShape(.capsule)
            }
        }
        .frame(height: 4)
    }

    private var staleThresholdMenu: some View {
        let entries: [FrostMenuEntry] = CleanStaleThreshold.allCases.map { option in
            .item(
                title: L10n.tr("闲置超过 \(option.displayName)", "Stale > \(option.displayName)"),
                isSelected: option == preferences.cleanStaleThreshold
            ) {
                guard preferences.cleanStaleThreshold != option else { return }
                confirmingTrash = false
                preferences.cleanStaleThreshold = option
                if cleaner.lastScanDate != nil && !cleaner.isScanning && !cleaner.isCleaning {
                    cleaner.scan()
                }
            }
        }

        return FrostDropdown(
            entries: entries,
            chrome: .toolbar(height: 24),
            alignment: .trailing,
            indicator: .picker,
            accessibilityLabel: L10n.tr("闲置时间阈值", "Stale Threshold"),
            accessibilityValue: preferences.cleanStaleThreshold.displayName
        ) {
            Text(
                L10n.tr(
                    "闲置 > \(preferences.cleanStaleThreshold.displayName)",
                    "Stale > \(preferences.cleanStaleThreshold.displayName)"
                )
            )
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.primary)
            .lineLimit(1)
        }
    }

    private var scopeFilterStrip: some View {
        HStack(spacing: 12) {
            scopeTabButton(title: L10n.tr("全部", "All"), category: nil)

            ForEach(CleanCategory.allCases) { category in
                let label: String = if cleaner.lastScanDate == nil {
                    category.shortTitle
                } else {
                    "\(category.shortTitle) · \(CleanCandidate.formatBytes(cleaner.categoryBytes(category)))"
                }
                scopeTabButton(title: label, category: category)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
    }

    private func scopeTabButton(title: String, category: CleanCategory?) -> some View {
        let isSelected = filterCategory == category

        return Button {
            guard filterCategory != category else { return }
            withAnimation(.snappy(duration: 0.14)) {
                filterCategory = category
            }
        } label: {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Text(title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular).monospacedDigit())
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                Rectangle()
                    .fill(isSelected ? SoftLiveTheme.accent : Color.clear)
                    .frame(height: 2)
            }
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func junkToolbar(displayedCandidates: [CleanCandidate]) -> some View {
        HStack(spacing: 8) {
            searchField(
                placeholder: L10n.tr("搜索名称或路径…", "Search name or path…"),
                text: $searchQuery
            )
            .frame(minWidth: 180, maxWidth: 260)

            Spacer(minLength: 4)

            FrostDropdown(
                entries: CleanTierFilter.allCases.map { option in
                    .item(
                        title: option.menuTitle,
                        isSelected: tierFilter == option
                    ) {
                        withAnimation(.snappy(duration: 0.14)) {
                            tierFilter = option
                        }
                    }
                },
                chrome: .toolbar(height: 26),
                alignment: .trailing,
                indicator: .picker,
                accessibilityLabel: L10n.tr("安全等级筛选", "Safety Filter"),
                accessibilityValue: tierFilter.buttonTitle
            ) {
                Text(tierFilter.buttonTitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }

            FrostDropdown(
                entries: CleanSortOrder.allCases.map { option in
                    .item(
                        title: option.displayName,
                        isSelected: sortOrder == option
                    ) {
                        sortOrder = option
                    }
                },
                chrome: .toolbar(height: 26),
                alignment: .trailing,
                indicator: .picker,
                accessibilityLabel: L10n.tr("排序方式", "Sort Order"),
                accessibilityValue: sortOrder.displayName
            ) {
                Text(sortOrder.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }

            FrostDropdown(
                entries: [
                    .item(
                        title: L10n.tr("全选当前", "Select All Shown"),
                        isEnabled: !displayedCandidates.isEmpty
                    ) {
                        confirmingTrash = false
                        for item in displayedCandidates where !cleaner.selectedIDs.contains(item.id) {
                            cleaner.toggleCandidate(item.id)
                        }
                    },
                    .item(
                        title: L10n.tr("仅选安全项", "Select Safe Only"),
                        isEnabled: !cleaner.candidates.isEmpty
                    ) {
                        confirmingTrash = false
                        cleaner.selectSafeDefaults()
                    },
                    .separator,
                    .item(
                        title: L10n.tr("取消全选", "Deselect All"),
                        isEnabled: cleaner.selectedCount > 0
                    ) {
                        confirmingTrash = false
                        cleaner.deselectAll()
                    },
                ],
                chrome: .borderless(height: 26),
                alignment: .trailing,
                indicator: .menu,
                accessibilityLabel: L10n.tr("批量选择", "Selection Actions")
            ) {
                Text(L10n.tr("选择", "Select"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func junkListRegion(filtered: [CleanCandidate], now: Date) -> some View {
        if cleaner.isScanning && cleaner.candidates.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.regular)
                Text(L10n.tr("正在按白名单扫描…", "Scanning allowlisted caches & leftovers…"))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.primary)
                Text(L10n.tr("自动跳过运行中应用与符号链接", "Skipping running applications and symbolic links"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if cleaner.lastScanDate == nil {
            VStack(spacing: 10) {
                Image(systemName: "internaldrive")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(.secondary)
                Text(L10n.tr("按需扫描，平时后台 0 开销", "On-Demand Scan · Zero Background Overhead"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(L10n.tr("检查应用缓存、开发工具、构建产物与卸载残留", "Inspect rebuildable caches, dev tools, builds, and leftovers"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Button {
                    cleaner.scan()
                } label: {
                    Text(L10n.tr("立即扫描", "Scan Now"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 28)
                        .background {
                            solidButtonFill(SoftLiveTheme.accent, darkOpacity: 0.88, cornerRadius: 7)
                        }
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filtered.isEmpty {
            let hasNoFilter = cleaner.candidates.isEmpty && searchQuery.isEmpty && filterCategory == nil && tierFilter == .all
            VStack(spacing: 8) {
                Image(systemName: hasNoFilter ? "checkmark.circle" : "magnifyingglass")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(.secondary)
                Text(
                    hasNoFilter
                        ? L10n.tr("空间干净，暂无可清理项", "All Clear")
                        : L10n.tr("未发现匹配项", "No Matching Items")
                )
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)

                Text(
                    !searchQuery.isEmpty
                        ? L10n.tr("未找到包含「\(searchQuery)」的扫描项", "No items matching \"\(searchQuery)\"")
                        : (hasNoFilter
                            ? L10n.tr("当前白名单路径下暂无符合条件的缓存或残留", "No cleanable caches or stale artifacts found")
                            : L10n.tr("当前分类或筛选条件下没有可清理项", "No cleanable items match the current filter"))
                )
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let firstID = filtered.first?.id
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered) { item in
                        if item.id != firstID {
                            horizontalHairline
                        }
                        CleanerCandidateRow(
                            item: item,
                            isSelected: cleaner.selectedIDs.contains(item.id),
                            showCategory: filterCategory == nil,
                            now: now,
                            isDark: isDark,
                            onToggle: {
                                confirmingTrash = false
                                cleaner.toggleCandidate(item.id)
                            },
                            onReveal: { cleaner.revealInFinder(item.url) },
                            onCopyPath: { cleaner.copyPath(item.url) },
                            onOpenTrash: { cleaner.openTrashInFinder() }
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .defaultScrollAnchor(.top)
        }
    }

    private var junkBottomActionBar: some View {
        HStack(spacing: 10) {
            junkBottomStatusView
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Button {
                    guard !cleaner.isScanning && !cleaner.isCleaning else { return }
                    confirmingTrash = false
                    cleaner.clearDropError()
                    cleaner.scan()
                } label: {
                    HStack(spacing: 5) {
                        if cleaner.isScanning {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.75)
                                .frame(width: 12, height: 12)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10.5, weight: .medium))
                        }
                        Text(
                            cleaner.isScanning
                                ? L10n.tr("扫描中…", "Scanning…")
                                : (cleaner.lastScanDate == nil ? L10n.tr("扫描", "Scan") : L10n.tr("重扫", "Rescan"))
                        )
                        .font(.system(size: 11.5, weight: .medium))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 11)
                    .frame(height: 26)
                    .insetWellChrome(cornerRadius: 6.5)
                }
                .buttonStyle(.plain)
                .disabled(cleaner.isScanning || cleaner.isCleaning)
                .fixedSize(horizontal: true, vertical: false)

                if cleaner.selectedCount > 0 {
                    twoStepCrimsonTrashControls(
                        isConfirming: $confirmingTrash,
                        isWorking: cleaner.isCleaning,
                        idleTitle: L10n.tr("移入废纸篓", "Move to Trash"),
                        confirmTitle: L10n.tr("确认移入", "Confirm"),
                        workingTitle: L10n.tr("清理中…", "Moving…"),
                        isDisabled: cleaner.isScanning || cleaner.isCleaning
                    ) {
                        cleaner.trashSelectedAsync()
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    @ViewBuilder
    private var junkBottomStatusView: some View {
        if let dropError = cleaner.dropErrorMessage {
            dropErrorBanner(dropError)
        } else if let report = cleaner.lastReport, report.trashedCount > 0 || report.skippedCount > 0 {
            trashReportStatusView(
                report: report,
                blockedMessage: L10n.tr(
                    "未能移入：\(report.skippedCount) 项正被占用或受保护",
                    "Skipped \(report.skippedCount) items (in use or protected)"
                )
            )
        } else if !cleaner.isScanning && cleaner.isScanningProtectedFolders {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.75)
                    .frame(width: 12, height: 12)
                Text(
                    cleaner.selectedCount > 0
                        ? L10n.tr(
                            "已选 \(cleaner.selectedCount) 项 · \(CleanCandidate.formatBytes(cleaner.selectedBytes)) · 正在检查文稿与下载目录…",
                            "\(cleaner.selectedCount) selected · \(CleanCandidate.formatBytes(cleaner.selectedBytes)) · Checking Documents & Downloads…"
                        )
                        : L10n.tr("正在检查文稿与下载目录…", "Checking Documents & Downloads…")
                )
                .font(.system(size: 11.5, weight: .regular).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            }
        } else if cleaner.selectedCount > 0 {
            Text(
                L10n.tr(
                    "已选 \(cleaner.selectedCount) 项 · \(CleanCandidate.formatBytes(cleaner.selectedBytes))",
                    "\(cleaner.selectedCount) selected · \(CleanCandidate.formatBytes(cleaner.selectedBytes))"
                )
            )
            .font(.system(size: 11.5, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
        } else if cleaner.lastScanDate != nil {
            Text(L10n.tr("未选择清理项", "No items selected"))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            Text(L10n.tr("白名单扫描 · 自动跳过运行中应用与符号链接", "Allowlist-only · Skips running apps & symlinks"))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    // MARK: - Mode 2: App Uninstaller Single-Surface Master-Detail Split

    private var appUninstallSurface: some View {
        let apps = computeDisplayedApps()

        return HStack(spacing: 0) {
            appMasterPane(apps: apps)
                .frame(width: 216)
                .frame(maxHeight: .infinity)

            verticalHairline

            appDetailInspector
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func appMasterPane(apps: [InstalledAppTarget]) -> some View {
        let firstAppID = apps.first?.id

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                searchField(
                    placeholder: L10n.tr("搜索应用…", "Filter apps…"),
                    text: $appSearchQuery
                )

                FrostDropdown(
                    entries: AppListSortOrder.allCases.map { option in
                        .item(
                            title: option.title,
                            isSelected: appSortOrder == option
                        ) {
                            appSortOrder = option
                        }
                    },
                    chrome: .iconSquare(size: 26),
                    alignment: .trailing,
                    indicator: .none,
                    accessibilityLabel: L10n.tr("应用排序", "Sort Apps"),
                    accessibilityValue: appSortOrder.title,
                    toolTip: L10n.tr("排序：\(appSortOrder.title)", "Sort: \(appSortOrder.title)")
                ) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            horizontalHairline

            Group {
                if cleaner.isScanningApps && apps.isEmpty {
                    VStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.regular)
                        Text(L10n.tr("正在扫描应用程序…", "Scanning Applications…"))
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if apps.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "app.dashed")
                            .font(.system(size: 24))
                            .foregroundStyle(.secondary)
                        Text(L10n.tr("未找到匹配应用", "No Apps Found"))
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(apps) { app in
                                if app.id != firstAppID {
                                    horizontalHairline
                                }
                                CleanerInstalledAppRow(
                                    app: app,
                                    icon: cleaner.icon(for: app),
                                    isSelected: cleaner.selectedApp?.id == app.id,
                                    onSelect: {
                                        confirmingAppTrash = false
                                        cleaner.selectApp(app.id)
                                    }
                                )
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .defaultScrollAnchor(.top)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            horizontalHairline

            HStack(spacing: 6) {
                Text(
                    L10n.tr(
                        "\(cleaner.installedApps.count) 款 · \(CleanCandidate.formatBytes(cleaner.totalInstalledAppsBytes))",
                        "\(cleaner.installedApps.count) apps · \(CleanCandidate.formatBytes(cleaner.totalInstalledAppsBytes))"
                    )
                )
                .font(.system(size: 10.5, weight: .regular).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)

                Spacer(minLength: 4)

                Button {
                    guard !cleaner.isScanningApps && !cleaner.isCleaning else { return }
                    confirmingAppTrash = false
                    cleaner.clearDropError()
                    cleaner.scanApps()
                } label: {
                    HStack(spacing: 4) {
                        if cleaner.isScanningApps {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.7)
                                .frame(width: 11, height: 11)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10, weight: .medium))
                        }
                        Text(L10n.tr("刷新", "Refresh"))
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .insetWellChrome(cornerRadius: 6)
                }
                .buttonStyle(.plain)
                .disabled(cleaner.isScanningApps || cleaner.isCleaning)
                .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 10)
            .frame(height: 44)
        }
    }

    @ViewBuilder
    private var appDetailInspector: some View {
        if let app = cleaner.selectedApp {
            VStack(alignment: .leading, spacing: 0) {
                selectedAppHeader(app)
                horizontalHairline
                groupedResidualsList(for: app)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                horizontalHairline
                appBottomActionBar(for: app)
            }
        } else {
            VStack(spacing: 8) {
                if cleaner.isScanningApps {
                    ProgressView()
                        .controlSize(.regular)
                    Text(L10n.tr("正在扫描应用程序…", "Scanning Applications…"))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.primary)
                } else {
                    Image(systemName: "app.dashed")
                        .font(.system(size: 28, weight: .regular))
                        .foregroundStyle(.secondary)
                    Text(L10n.tr("选择应用或拖入 .app", "Select an App or Drop .app"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(L10n.tr("自动关联应用本体与 8 类残留数据", "Inspect app bundle and 8 categories of associated data"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func selectedAppHeader(_ app: InstalledAppTarget) -> some View {
        let isRunning = cleaner.isAppRunning(app)

        return VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 10) {
                    Image(nsImage: cleaner.icon(for: app))
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 38, height: 38)

                    VStack(alignment: .leading, spacing: 2.5) {
                        HStack(spacing: 6) {
                            Text(app.displayName)
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.tail)

                            Text("v\(app.version)")
                                .font(.system(size: 10.5, weight: .regular).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: true, vertical: false)

                            if isRunning {
                                Text(L10n.tr("运行中", "Running"))
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .fixedSize(horizontal: true, vertical: false)
                                    .foregroundStyle(SoftLiveTheme.warning)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(
                                        SoftLiveTheme.warning.opacity(isDark ? 0.16 : 0.12),
                                        in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    )
                            }
                        }

                        Text(app.bundleID)
                            .font(.system(size: 10.5, weight: .regular))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 8) {
                    Text(
                        L10n.tr(
                            "本体 \(CleanCandidate.formatBytes(app.bundleSizeBytes)) · 关联 \(CleanCandidate.formatBytes(app.residualSizeBytes))",
                            "App \(CleanCandidate.formatBytes(app.bundleSizeBytes)) · Data \(CleanCandidate.formatBytes(app.residualSizeBytes))"
                        )
                    )
                    .font(.system(size: 10.5, weight: .regular).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                    Spacer(minLength: 4)

                    Button {
                        cleaner.revealInFinder(app.bundleURL)
                    } label: {
                        Text(L10n.tr("在访达中显示", "Reveal in Finder"))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(SoftLiveTheme.accent)
                    }
                    .buttonStyle(.plain)
                    .fixedSize(horizontal: true, vertical: false)
                }
            }

            appPresetStrip
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var appPresetStrip: some View {
        let isFull = cleaner.isSelectedAppBundleChecked
        let hasAny = cleaner.selectedAppItemCount > 0
        let isResetActive = !isFull && hasAny

        return HStack(spacing: 8) {
            HStack(spacing: 2) {
                presetOptionButton(
                    title: L10n.tr("完整卸载", "Full Uninstall"),
                    isActive: isFull
                ) {
                    confirmingAppTrash = false
                    cleaner.selectAllSafeAppResiduals()
                }

                presetOptionButton(
                    title: L10n.tr("仅清数据", "Reset Data"),
                    isActive: isResetActive
                ) {
                    confirmingAppTrash = false
                    cleaner.selectAppResidualsOnly()
                }
            }
            .padding(2)
            .insetWellChrome(cornerRadius: 6.5)

            Spacer(minLength: 4)

            if hasAny {
                Button {
                    confirmingAppTrash = false
                    cleaner.deselectAllAppResiduals()
                } label: {
                    Text(L10n.tr("清空", "Clear"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    private func presetOptionButton(title: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? SoftLiveTheme.accent : .secondary)
                .padding(.horizontal, 9)
                .frame(height: 20)
                .background(
                    isActive ? SoftLiveTheme.selectionFill : Color.clear,
                    in: RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func groupedResidualsList(for app: InstalledAppTarget) -> some View {
        let grouped = Dictionary(grouping: app.residuals, by: \.kind)
        let sections: [(kind: AppResidualKind, items: [AppResidualItem])] = AppResidualKind.allCases.compactMap { kind in
            guard let items = grouped[kind], !items.isEmpty else { return nil }
            return (kind, items)
        }

        return ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(sections, id: \.kind) { section in
                    HStack {
                        Text(section.kind.title)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 24)
                    .background(SoftLiveTheme.insetWell)

                    horizontalHairline

                    ForEach(section.items) { item in
                        CleanerResidualRow(
                            item: item,
                            isSelected: cleaner.selectedResidualIDs.contains(item.id),
                            isDark: isDark,
                            onToggle: {
                                confirmingAppTrash = false
                                cleaner.toggleResidual(item.id)
                            },
                            onReveal: { cleaner.revealInFinder(item.url) },
                            onCopyPath: { cleaner.copyPath(item.url) },
                            onOpenTrash: { cleaner.openTrashInFinder() }
                        )
                        horizontalHairline
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .defaultScrollAnchor(.top)
    }

    private func appBottomActionBar(for app: InstalledAppTarget) -> some View {
        let isFullUninstall = cleaner.isSelectedAppBundleChecked

        return HStack(spacing: 8) {
            appBottomStatusView(for: app)
                .frame(maxWidth: .infinity, alignment: .leading)

            if cleaner.selectedAppItemCount > 0 {
                twoStepCrimsonTrashControls(
                    isConfirming: $confirmingAppTrash,
                    isWorking: cleaner.isCleaning,
                    idleTitle: isFullUninstall
                        ? L10n.tr("卸载至废纸篓", "Uninstall to Trash")
                        : L10n.tr("清理所选数据", "Clean Selected Data"),
                    confirmTitle: L10n.tr("确认", "Confirm"),
                    workingTitle: L10n.tr("处理中…", "Working…"),
                    isDisabled: cleaner.isScanningApps || cleaner.isCleaning
                ) {
                    cleaner.trashSelectedAppItemsAsync()
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    @ViewBuilder
    private func appBottomStatusView(for app: InstalledAppTarget) -> some View {
        if let dropError = cleaner.dropErrorMessage {
            dropErrorBanner(dropError)
        } else if cleaner.isInspectingDrop {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.75)
                    .frame(width: 12, height: 12)
                Text(L10n.tr("正在解析 .app…", "Inspecting .app…"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } else if let report = cleaner.lastUninstallReport, report.trashedCount > 0 || report.skippedCount > 0 {
            trashReportStatusView(
                report: report,
                blockedMessage: L10n.tr(
                    "未能移除：应用未退出或 \(report.skippedCount) 项受保护",
                    "Blocked: running or \(report.skippedCount) protected"
                )
            )
        } else if cleaner.selectedAppItemCount > 0 {
            Text(
                L10n.tr(
                    "已选 \(cleaner.selectedAppItemCount) 项 · \(CleanCandidate.formatBytes(cleaner.selectedAppBytes))",
                    "\(cleaner.selectedAppItemCount) selected · \(CleanCandidate.formatBytes(cleaner.selectedAppBytes))"
                )
            )
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
        } else {
            Text(L10n.tr("拖入 .app 或勾选项目", "Drop .app or select items"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    // MARK: - Shared Components

    private func searchField(placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)

            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))

            if !text.wrappedValue.isEmpty {
                Button {
                    text.wrappedValue = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .insetWellChrome(cornerRadius: 6.5)
    }

    private func solidButtonFill(_ token: Color, darkOpacity: Double, cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return shape
            .fill(Color.black)
            .overlay {
                shape.fill(token.opacity(isDark ? darkOpacity : 1.0))
            }
    }

    @ViewBuilder
    private func twoStepCrimsonTrashControls(
        isConfirming: Binding<Bool>,
        isWorking: Bool,
        idleTitle: String,
        confirmTitle: String,
        workingTitle: String,
        isDisabled: Bool,
        onConfirm: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 6) {
            if isConfirming.wrappedValue && !isWorking {
                Button {
                    withAnimation(.snappy(duration: 0.14)) {
                        isConfirming.wrappedValue = false
                    }
                } label: {
                    Text(L10n.tr("取消", "Cancel"))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .insetWellChrome(cornerRadius: 6.5)
                }
                .buttonStyle(.plain)
            }

            Button {
                guard !isDisabled else { return }
                if isConfirming.wrappedValue {
                    isConfirming.wrappedValue = false
                    onConfirm()
                } else {
                    withAnimation(.snappy(duration: 0.14)) {
                        isConfirming.wrappedValue = true
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    if isWorking {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.75)
                            .frame(width: 12, height: 12)
                    } else if isConfirming.wrappedValue {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    Text(
                        isWorking
                            ? workingTitle
                            : (isConfirming.wrappedValue ? confirmTitle : idleTitle)
                    )
                    .font(.system(size: 11.5, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background {
                    solidButtonFill(SoftLiveTheme.critical, darkOpacity: 0.68, cornerRadius: 6.5)
                }
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
        }
    }

    @ViewBuilder
    private func trashReportStatusView(report: CleanSummaryReport, blockedMessage: String) -> some View {
        if report.trashedCount > 0 && report.skippedCount > 0 {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(SoftLiveTheme.warning)
                Text(
                    L10n.tr(
                        "已移入 \(report.trashedCount) 项（\(CleanCandidate.formatBytes(report.freedBytes))），\(report.skippedCount) 项跳过",
                        "Moved \(report.trashedCount) (\(CleanCandidate.formatBytes(report.freedBytes))); \(report.skippedCount) skipped"
                    )
                )
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(SoftLiveTheme.warning)
                .lineLimit(1)

                openTrashLink
            }
        } else if report.trashedCount > 0 {
            HStack(spacing: 6) {
                Text(
                    L10n.tr(
                        "已移入 \(report.trashedCount) 项（\(CleanCandidate.formatBytes(report.freedBytes))）",
                        "Moved \(report.trashedCount) (\(CleanCandidate.formatBytes(report.freedBytes))) to Trash"
                    )
                )
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)

                openTrashLink
            }
        } else {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(SoftLiveTheme.warning)
                Text(blockedMessage)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(SoftLiveTheme.warning)
                    .lineLimit(1)
            }
        }
    }

    private var openTrashLink: some View {
        Button {
            cleaner.openTrashInFinder()
        } label: {
            Text(L10n.tr("打开废纸篓", "Open Trash"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(SoftLiveTheme.accent)
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func dropErrorBanner(_ message: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(SoftLiveTheme.warning)
            Text(message)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(SoftLiveTheme.warning)
                .lineLimit(1)
                .help(message)
            Button {
                cleaner.clearDropError()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(SoftLiveTheme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(SoftLiveTheme.selectionFill)
            )
            .overlay {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.app")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(SoftLiveTheme.accent)
                    Text(L10n.tr("松开以解析该 .app 本体与关联残留文件", "Drop .app bundle to inspect its associated files"))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    SoftLiveTheme.surface,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(SoftLiveTheme.hairline, lineWidth: 0.5)
                }
            }
            .padding(.top, 22)
            .allowsHitTesting(false)
    }

    private var horizontalHairline: some View {
        Rectangle()
            .fill(SoftLiveTheme.hairline)
            .frame(height: 0.5)
    }

    private var verticalHairline: some View {
        Rectangle()
            .fill(SoftLiveTheme.hairline)
            .frame(width: 0.5)
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
                cleaner.inspectDroppedAppURL(appURL)
            }
        }
        return true
    }
}

// MARK: - Isolated Row Subviews & Shared Row Chrome

private struct CheckFirstTag: View {
    let isDark: Bool

    var body: some View {
        Text(L10n.tr("需核对", "Check First"))
            .font(.system(size: 9.5, weight: .semibold))
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(SoftLiveTheme.warning)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                SoftLiveTheme.warning.opacity(isDark ? 0.16 : 0.12),
                in: RoundedRectangle(cornerRadius: 4, style: .continuous)
            )
    }
}

private struct RevealFinderButton: View {
    let isVisible: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.forward.circle")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .help(L10n.tr("在访达中显示", "Reveal in Finder"))
    }
}

private struct CleanerCandidateRow: View {
    let item: CleanCandidate
    let isSelected: Bool
    let showCategory: Bool
    let now: Date
    let isDark: Bool
    let onToggle: () -> Void
    let onReveal: () -> Void
    let onCopyPath: () -> Void
    let onOpenTrash: () -> Void

    @State private var isHovered = false

    private var metadataText: String? {
        let age = item.formattedAge(now: now)
        if showCategory {
            if let age {
                return "\(age) · \(item.category.shortTitle)"
            }
            return item.category.shortTitle
        }
        return age
    }

    var body: some View {
        HStack(spacing: 10) {
            Toggle(
                "",
                isOn: Binding(
                    get: { isSelected },
                    set: { _ in onToggle() }
                )
            )
            .labelsHidden()
            .toggleStyle(.checkbox)

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1.5) {
                    HStack(spacing: 6) {
                        Text(item.displayTitle)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if item.safetyTier == .checkFirst {
                            CheckFirstTag(isDark: isDark)
                        }
                    }

                    Text(item.subtitle)
                        .font(.system(size: 10.5, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let metadataText {
                    Text(metadataText)
                        .font(.system(size: 10.5, weight: .regular).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }

                Text(CleanCandidate.formatBytes(item.sizeBytes))
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .frame(minWidth: 56, alignment: .trailing)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onToggle()
            }

            RevealFinderButton(isVisible: isHovered, action: onReveal)
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(isHovered ? SoftLiveTheme.insetWell : Color.clear)
        .onHover { hovering in
            if isHovered != hovering {
                isHovered = hovering
            }
        }
        .cleanerRowContextMenu(
            isSelected: isSelected,
            onToggle: onToggle,
            onReveal: onReveal,
            onCopyPath: onCopyPath,
            onOpenTrash: onOpenTrash
        )
    }
}

private struct CleanerInstalledAppRow: View {
    let app: InstalledAppTarget
    let icon: NSImage
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 1.5) {
                Text(app.displayName)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(
                    app.residualSizeBytes > 0
                        ? L10n.tr(
                            "关联 \(CleanCandidate.formatBytes(app.residualSizeBytes))",
                            "Data \(CleanCandidate.formatBytes(app.residualSizeBytes))"
                        )
                        : L10n.tr("仅应用本体", "Bundle only")
                )
                .font(.system(size: 10, weight: .regular).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(CleanCandidate.formatBytes(app.totalSizeBytes))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(isSelected ? .primary : .secondary)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
        .background {
            if isSelected {
                Rectangle().fill(SoftLiveTheme.selectionFill)
            } else if isHovered {
                Rectangle().fill(SoftLiveTheme.insetWell)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            if isHovered != hovering {
                isHovered = hovering
            }
        }
        .onTapGesture {
            onSelect()
        }
    }
}

private struct CleanerResidualRow: View {
    let item: AppResidualItem
    let isSelected: Bool
    let isDark: Bool
    let onToggle: () -> Void
    let onReveal: () -> Void
    let onCopyPath: () -> Void
    let onOpenTrash: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Toggle(
                "",
                isOn: Binding(
                    get: { isSelected },
                    set: { _ in onToggle() }
                )
            )
            .labelsHidden()
            .toggleStyle(.checkbox)

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1.5) {
                    HStack(spacing: 5) {
                        Text(item.title)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if item.safetyTier == .checkFirst {
                            CheckFirstTag(isDark: isDark)
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
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onToggle()
            }

            RevealFinderButton(isVisible: isHovered, action: onReveal)
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(isHovered ? SoftLiveTheme.insetWell : Color.clear)
        .onHover { hovering in
            if isHovered != hovering {
                isHovered = hovering
            }
        }
        .cleanerRowContextMenu(
            isSelected: isSelected,
            onToggle: onToggle,
            onReveal: onReveal,
            onCopyPath: onCopyPath,
            onOpenTrash: onOpenTrash
        )
    }
}

private extension View {
    func insetWellChrome(cornerRadius: CGFloat) -> some View {
        background(
            SoftLiveTheme.insetWell,
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(SoftLiveTheme.hairline, lineWidth: 0.5)
        }
    }

    func cleanerRowContextMenu(
        isSelected: Bool,
        onToggle: @escaping () -> Void,
        onReveal: @escaping () -> Void,
        onCopyPath: @escaping () -> Void,
        onOpenTrash: @escaping () -> Void
    ) -> some View {
        contextMenu {
            Button(isSelected ? L10n.tr("取消勾选", "Deselect") : L10n.tr("勾选此项", "Select")) {
                onToggle()
            }
            Button(L10n.tr("在访达中显示", "Reveal in Finder")) {
                onReveal()
            }
            Button(L10n.tr("复制完整路径", "Copy Path")) {
                onCopyPath()
            }
            Divider()
            Button(L10n.tr("打开系统废纸篓", "Open Trash")) {
                onOpenTrash()
            }
        }
    }
}
