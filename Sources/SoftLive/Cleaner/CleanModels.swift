import Foundation

/// Top-level workspace mode inside the Control Center `Cleaner` tab.
enum CleanerMode: String, CaseIterable, Identifiable, Sendable {
    case junkClean
    case appUninstall

    var id: String { rawValue }

    var title: String {
        switch self {
        case .junkClean:
            L10n.tr("缓存与残留", "Junk & Caches")
        case .appUninstall:
            L10n.tr("应用卸载", "App Uninstaller")
        }
    }

    var icon: String {
        switch self {
        case .junkClean: "sparkles"
        case .appUninstall: "square.stack.3d.up.fill"
        }
    }
}

/// Classification of files associated with an installed application.
enum AppResidualKind: String, CaseIterable, Sendable, Equatable {
    case appBundle
    case appSupport
    case caches
    case containers
    case preferences
    case stateAndWeb
    case logs
    case sharedAndAgents

    var title: String {
        switch self {
        case .appBundle: L10n.tr("应用本体", "App Bundle")
        case .appSupport: L10n.tr("应用支持", "App Support")
        case .caches: L10n.tr("缓存数据", "Caches")
        case .containers: L10n.tr("沙盒容器", "Container")
        case .preferences: L10n.tr("偏好设置", "Preferences")
        case .stateAndWeb: L10n.tr("状态与网络", "State & Web")
        case .logs: L10n.tr("诊断日志", "Logs")
        case .sharedAndAgents: L10n.tr("共享与启动项", "Shared & Agents")
        }
    }

    var icon: String {
        switch self {
        case .appBundle: "app.badge.fill"
        case .appSupport: "folder.fill"
        case .caches: "internaldrive"
        case .containers: "cube.box.fill"
        case .preferences: "slider.horizontal.3"
        case .stateAndWeb: "window.ceiling"
        case .logs: "doc.text.fill"
        case .sharedAndAgents: "link.circle.fill"
        }
    }
}

/// A single file or directory belonging to an installed application (the `.app` bundle itself or a `~/Library` leftover).
struct AppResidualItem: Identifiable, Equatable, Sendable {
    let id: String
    let url: URL
    let kind: AppResidualKind
    let title: String
    let subtitle: String
    let sizeBytes: UInt64
    let safetyTier: CleanSafetyTier

    nonisolated init(
        url: URL,
        kind: AppResidualKind,
        title: String,
        subtitle: String,
        sizeBytes: UInt64,
        safetyTier: CleanSafetyTier
    ) {
        let std = url.standardizedFileURL
        let rawPath = std.path(percentEncoded: false)
        self.id = rawPath.count > 1 && rawPath.hasSuffix("/") ? String(rawPath.dropLast()) : rawPath
        self.url = std
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.sizeBytes = sizeBytes
        self.safetyTier = safetyTier
    }
}

/// An installed macOS application together with all discovered associated files in `~/Library`.
struct InstalledAppTarget: Identifiable, Equatable, Sendable {
    let id: String
    let bundleURL: URL
    let bundleID: String
    let displayName: String
    let version: String
    let bundleSizeBytes: UInt64
    let residuals: [AppResidualItem]
    let lastModified: Date?

    nonisolated init(
        bundleURL: URL,
        bundleID: String,
        displayName: String,
        version: String,
        bundleSizeBytes: UInt64,
        residuals: [AppResidualItem],
        lastModified: Date? = nil
    ) {
        let std = bundleURL.standardizedFileURL
        let rawPath = std.path(percentEncoded: false)
        self.id = rawPath.count > 1 && rawPath.hasSuffix("/") ? String(rawPath.dropLast()) : rawPath
        self.bundleURL = std
        self.bundleID = bundleID
        self.displayName = displayName
        self.version = version
        self.bundleSizeBytes = bundleSizeBytes
        self.residuals = residuals
        self.lastModified = lastModified
    }

    nonisolated var totalSizeBytes: UInt64 {
        residuals.reduce(0) { $0 &+ $1.sizeBytes }
    }

    nonisolated var residualSizeBytes: UInt64 {
        residuals.reduce(0) { sum, item in
            item.kind == .appBundle ? sum : (sum &+ item.sizeBytes)
        }
    }

    nonisolated var residualFileCount: Int {
        residuals.reduce(0) { count, item in
            item.kind == .appBundle ? count : (count + 1)
        }
    }
}

/// Safety classification for a discovered cleanable item.
enum CleanSafetyTier: String, CaseIterable, Sendable, Equatable {
    /// Rebuildable caches and stale build artifacts; pre-selected by default.
    case safe
    /// Items that may require re-downloading or manual review (e.g. Xcode Archives, orphaned app data, old DMG/PKG installers);
    /// left unchecked by default so one-click runs never touch them without explicit user selection.
    case checkFirst

    var defaultSelected: Bool {
        switch self {
        case .safe: true
        case .checkFirst: false
        }
    }

    var badgeTitle: String {
        switch self {
        case .safe: L10n.tr("安全清理", "Safe")
        case .checkFirst: L10n.tr("建议核对", "Check First")
        }
    }
}

/// Top-level allowlisted cleanup categories.
enum CleanCategory: String, CaseIterable, Identifiable, Sendable {
    case appCaches
    case devCaches
    case staleArtifacts
    case leftoversAndInstallers

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appCaches:
            L10n.tr("应用缓存与日志", "App Caches & Logs")
        case .devCaches:
            L10n.tr("开发工具与包缓存", "Dev Tools & Packages")
        case .staleArtifacts:
            L10n.tr("闲置项目构建产物", "Stale Project Builds")
        case .leftoversAndInstallers:
            L10n.tr("卸载残留与安装包", "Leftovers & Installers")
        }
    }

    var shortTitle: String {
        switch self {
        case .appCaches:
            L10n.tr("应用缓存", "App Caches")
        case .devCaches:
            L10n.tr("开发与包", "Dev & Pkgs")
        case .staleArtifacts:
            L10n.tr("项目构建", "Builds")
        case .leftoversAndInstallers:
            L10n.tr("残留与安装包", "Leftovers")
        }
    }

    var subtitle: String {
        switch self {
        case .appCaches:
            L10n.tr("应用缓存、日志、崩溃报告与更新包（跳过运行中应用）", "User caches, logs, crash reports & updater leftovers")
        case .devCaches:
            L10n.tr("Xcode、Simulator、Homebrew、npm / pnpm / Cargo / pip / AI 缓存", "Xcode, Simulator, Homebrew, npm / pnpm / Cargo / pip & AI caches")
        case .staleArtifacts:
            L10n.tr("闲置项目的 .build / node_modules / target / .next / dist", "Inactive project .build / node_modules / target / .next / dist")
        case .leftoversAndInstallers:
            L10n.tr("已卸载应用的孤立数据目录与下载区旧安装包（DMG / PKG / ZIP）", "Orphaned app leftovers & old Downloads installers")
        }
    }

    var icon: String {
        switch self {
        case .appCaches: "internaldrive"
        case .devCaches: "hammer.fill"
        case .staleArtifacts: "folder.fill.badge.gearshape"
        case .leftoversAndInstallers: "archivebox.fill"
        }
    }
}

/// Sort order for discovered cleanup candidates.
enum CleanSortOrder: String, CaseIterable, Identifiable, Sendable {
    case sizeDesc
    case ageDesc
    case nameAsc

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sizeDesc: L10n.tr("按体积", "By Size")
        case .ageDesc: L10n.tr("按时间", "Oldest")
        case .nameAsc: L10n.tr("按名称", "By Name")
        }
    }
}

/// Inactivity window before project build artifacts or Downloads installers are eligible for cleanup.
enum CleanStaleThreshold: Int, CaseIterable, Sendable {
    case sevenDays = 7
    case fourteenDays = 14
    case thirtyDays = 30

    var displayName: String {
        switch self {
        case .sevenDays: L10n.tr("7 天", "7d")
        case .fourteenDays: L10n.tr("14 天", "14d")
        case .thirtyDays: L10n.tr("30 天", "30d")
        }
    }

    var timeInterval: TimeInterval {
        TimeInterval(rawValue) * 86_400
    }
}

/// A single allowlisted file or directory discovered during a scan.
struct CleanCandidate: Identifiable, Equatable, Sendable {
    let id: String
    let url: URL
    let category: CleanCategory
    let title: String
    let subtitle: String
    let sizeBytes: UInt64
    let safetyTier: CleanSafetyTier
    let lastModified: Date?

    nonisolated init(
        url: URL,
        category: CleanCategory,
        title: String,
        subtitle: String,
        sizeBytes: UInt64,
        safetyTier: CleanSafetyTier,
        lastModified: Date? = nil
    ) {
        let std = url.standardizedFileURL
        let rawPath = std.path(percentEncoded: false)
        self.id = rawPath.count > 1 && rawPath.hasSuffix("/") ? String(rawPath.dropLast()) : rawPath
        self.url = std
        self.category = category
        self.title = title
        self.subtitle = subtitle
        self.sizeBytes = sizeBytes
        self.safetyTier = safetyTier
        self.lastModified = lastModified
    }
}

/// Snapshot of system volume capacity.
struct DiskSpaceSummary: Equatable, Sendable {
    let totalBytes: UInt64
    let availableBytes: UInt64

    var usedBytes: UInt64 {
        totalBytes > availableBytes ? totalBytes - availableBytes : 0
    }

    var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(usedBytes) / Double(totalBytes), 0), 1)
    }

    static func current(for url: URL = URL(fileURLWithPath: "/")) -> DiskSpaceSummary {
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else {
            return DiskSpaceSummary(totalBytes: 0, availableBytes: 0)
        }
        let total = UInt64(max(values.volumeTotalCapacity ?? 0, 0))
        let availableImportant = values.volumeAvailableCapacityForImportantUsage.map { UInt64(max($0, 0)) }
        let availableStandard = values.volumeAvailableCapacity.map { UInt64(max($0, 0)) }
        let available = min(availableImportant ?? availableStandard ?? 0, total)
        return DiskSpaceSummary(totalBytes: total, availableBytes: available)
    }
}

/// Result summary emitted after moving selected items to the Trash.
struct CleanSummaryReport: Equatable, Sendable {
    let trashedCount: Int
    let freedBytes: UInt64
    let skippedCount: Int
    let completedAt: Date
}

extension CleanCandidate {
    /// Formats byte counts across KB, MB, and GB so sub-megabyte caches never display as "0 MB".
    static func formatBytes(_ bytes: UInt64) -> String {
        if bytes == 0 {
            return "0 KB"
        }
        let kb = Double(bytes) / 1024.0
        if kb < 1024.0 {
            return "\(max(Int(kb.rounded()), 1)) KB"
        }
        let mb = kb / 1024.0
        if mb < 10.0 {
            return String(format: "%.1f MB", mb)
        }
        if mb < 1024.0 {
            return "\(Int(mb.rounded())) MB"
        }
        let gb = mb / 1024.0
        return String(format: "%.1f GB", gb)
    }

    /// Formats a relative age label (e.g. "12 天前" / "12d ago") for display in candidate rows.
    func formattedAge(now: Date = .now) -> String? {
        guard let lastModified else { return nil }
        let days = max(Int(now.timeIntervalSince(lastModified) / 86_400), 0)
        if days == 0 {
            return L10n.tr("今天", "Today")
        }
        if days < 365 {
            return L10n.tr("\(days)天前", "\(days)d ago")
        }
        let years = days / 365
        return L10n.tr("\(years)年前", "\(years)y ago")
    }
}
