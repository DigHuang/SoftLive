import AppKit
import Darwin
import Foundation

nonisolated private final class LockedAppCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [InstalledAppTarget] = []

    init() {}

    func append(_ element: InstalledAppTarget) {
        lock.lock()
        storage.append(element)
        lock.unlock()
    }

    var elements: [InstalledAppTarget] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// Pre-indexed directory entries under `~/Library` so matching dozens of installed `.app` bundles
/// performs only a single pass of directory listings.
nonisolated struct UserLibraryIndex: Sendable {
    struct Entry: Sendable {
        let url: URL
        let name: String
        let lowerName: String
    }

    let homeDirectory: URL
    let appSupport: [Entry]
    let caches: [Entry]
    let containers: [Entry]
    let preferences: [Entry]
    let byHostPreferences: [Entry]
    let savedStates: [Entry]
    let httpStorages: [Entry]
    let webKit: [Entry]
    let logs: [Entry]
    let groupContainers: [Entry]
    let launchAgents: [Entry]

    init(homeDirectory: URL) {
        let stdHome = homeDirectory.standardizedFileURL
        self.homeDirectory = stdHome
        self.appSupport = Self.listEntries(in: stdHome.appending(path: "Library/Application Support", directoryHint: .isDirectory))
        self.caches = Self.listEntries(in: stdHome.appending(path: "Library/Caches", directoryHint: .isDirectory))
        self.containers = Self.listEntries(in: stdHome.appending(path: "Library/Containers", directoryHint: .isDirectory))
        self.preferences = Self.listEntries(in: stdHome.appending(path: "Library/Preferences", directoryHint: .isDirectory))
        self.byHostPreferences = Self.listEntries(in: stdHome.appending(path: "Library/Preferences/ByHost", directoryHint: .isDirectory))
        self.savedStates = Self.listEntries(in: stdHome.appending(path: "Library/Saved Application State", directoryHint: .isDirectory))
        self.httpStorages = Self.listEntries(in: stdHome.appending(path: "Library/HTTPStorages", directoryHint: .isDirectory))
        self.webKit = Self.listEntries(in: stdHome.appending(path: "Library/WebKit", directoryHint: .isDirectory))
        self.logs = Self.listEntries(in: stdHome.appending(path: "Library/Logs", directoryHint: .isDirectory))
        self.groupContainers = Self.listEntries(in: stdHome.appending(path: "Library/Group Containers", directoryHint: .isDirectory))
        self.launchAgents = Self.listEntries(in: stdHome.appending(path: "Library/LaunchAgents", directoryHint: .isDirectory))
    }

    private static func listEntries(in directory: URL) -> [Entry] {
        let options: FileManager.DirectoryEnumerationOptions = [
            .skipsHiddenFiles,
            .skipsPackageDescendants,
            .skipsSubdirectoryDescendants
        ]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: options
        ) else {
            return []
        }
        return urls.compactMap { url in
            guard !CleanRuleEngine.isSymbolicLink(url) else { return nil }
            let name = url.lastPathComponent
            return Entry(url: url.standardizedFileURL, name: name, lowerName: name.lowercased())
        }
    }
}

/// Multi-level heuristic engine that discovers installed macOS applications and their associated `~/Library` files.
nonisolated enum AppUninstallEngine {
    private static let genericAppNames: Set<String> = [
        "app", "application", "client", "desktop", "helper", "launcher",
        "mac", "macos", "player", "pro", "server", "service", "studio", "tool", "viewer"
    ]

    /// Scans `/Applications` and `~/Applications` (or custom test directories) and resolves each app's `~/Library` leftovers.
    static func scanInstalledApps(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationDirectories: [URL]? = nil
    ) -> [InstalledAppTarget] {
        let stdHome = homeDirectory.standardizedFileURL
        let appDirs = applicationDirectories ?? [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            stdHome.appending(path: "Applications", directoryHint: .isDirectory)
        ]

        let bundleURLs = discoverAppBundles(in: appDirs)
        guard !bundleURLs.isEmpty else { return [] }

        let libraryIndex = UserLibraryIndex(homeDirectory: stdHome)
        let collector = LockedAppCollector()

        DispatchQueue.concurrentPerform(iterations: bundleURLs.count) { idx in
            let bundleURL = bundleURLs[idx]
            if let target = inspectApp(at: bundleURL, libraryIndex: libraryIndex) {
                collector.append(target)
            }
        }

        return collector.elements.sorted { lhs, rhs in
            if lhs.totalSizeBytes != rhs.totalSizeBytes {
                return lhs.totalSizeBytes > rhs.totalSizeBytes
            }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    /// Inspects a single `.app` bundle (e.g. dropped from Finder) and resolves all of its associated `~/Library` files.
    static func inspectApp(
        at appURL: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> InstalledAppTarget? {
        let libraryIndex = UserLibraryIndex(homeDirectory: homeDirectory)
        return inspectApp(at: appURL, libraryIndex: libraryIndex)
    }

    static func inspectApp(
        at appURL: URL,
        libraryIndex: UserLibraryIndex
    ) -> InstalledAppTarget? {
        let stdURL = appURL.standardizedFileURL
        guard stdURL.pathExtension.lowercased() == "app",
              !CleanRuleEngine.isSymbolicLink(stdURL) else {
            return nil
        }

        let canonical = CleanRuleEngine.canonicalPath(stdURL)
        if canonical.hasPrefix("/System/") || canonical.hasPrefix("/Library/Apple/") {
            return nil
        }

        let plistURL = stdURL.appending(path: "Contents/Info.plist")
        guard let plist = NSDictionary(contentsOf: plistURL),
              let rawBundleID = (plist["CFBundleIdentifier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawBundleID.isEmpty else {
            return nil
        }

        let lowerBundleID = rawBundleID.lowercased()
        if lowerBundleID.hasPrefix("com.apple.") || lowerBundleID == "dev.softlive.softlive" {
            return nil
        }

        let bundleStem = stdURL.deletingPathExtension().lastPathComponent
        let displayName = (plist["CFBundleDisplayName"] as? String)
            ?? (plist["CFBundleName"] as? String)
            ?? bundleStem
        let version = (plist["CFBundleShortVersionString"] as? String)
            ?? (plist["CFBundleVersion"] as? String)
            ?? "1.0"

        let bundleMetrics = CleanRuleEngine.directoryMetrics(at: stdURL)
        guard bundleMetrics.bytes > 0 else { return nil }

        let bundleResidual = AppResidualItem(
            url: stdURL,
            kind: .appBundle,
            title: stdURL.lastPathComponent,
            subtitle: compactDisplayPath(stdURL, homeDirectory: libraryIndex.homeDirectory),
            sizeBytes: bundleMetrics.bytes,
            safetyTier: .safe
        )

        let associated = findAssociatedResiduals(
            bundleID: lowerBundleID,
            displayName: displayName,
            bundleStem: bundleStem,
            libraryIndex: libraryIndex
        )

        var allResiduals: [AppResidualItem] = [bundleResidual]
        allResiduals.append(contentsOf: associated)

        return InstalledAppTarget(
            bundleURL: stdURL,
            bundleID: rawBundleID,
            displayName: displayName,
            version: version,
            bundleSizeBytes: bundleMetrics.bytes,
            residuals: allResiduals,
            lastModified: bundleMetrics.lastModified
        )
    }

    /// Re-verifies safety invariants right before moving an `AppResidualItem` to the macOS Trash.
    static func canSafelyTrash(
        _ item: AppResidualItem,
        app: InstalledAppTarget,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        allowedApplicationDirectories: [URL]? = nil
    ) -> Bool {
        let fm = FileManager.default
        let targetPath = CleanRuleEngine.canonicalPath(item.url)
        guard fm.fileExists(atPath: targetPath),
              !CleanRuleEngine.isSymbolicLink(item.url) else {
            return false
        }

        if targetPath.hasPrefix("/System/") || targetPath.hasPrefix("/usr/") || targetPath.hasPrefix("/bin/") {
            return false
        }

        let lowerID = app.bundleID.lowercased()
        if lowerID.hasPrefix("com.apple.") || lowerID == "dev.softlive.softlive" {
            return false
        }

        if item.kind == .appBundle {
            let appBundlePath = CleanRuleEngine.canonicalPath(app.bundleURL)
            guard targetPath == appBundlePath && targetPath.lowercased().hasSuffix(".app") else {
                return false
            }
            if let allowedApplicationDirectories {
                let allowedRoots = allowedApplicationDirectories.map(CleanRuleEngine.canonicalPath)
                return allowedRoots.contains { root in
                    targetPath.hasPrefix(root + "/") && targetPath != root
                }
            }
            return true
        }

        let allowedLibraryDirs = [
            "Library/Application Support",
            "Library/Caches",
            "Library/Containers",
            "Library/Preferences",
            "Library/Saved Application State",
            "Library/HTTPStorages",
            "Library/WebKit",
            "Library/Logs",
            "Library/Group Containers",
            "Library/LaunchAgents"
        ].map {
            CleanRuleEngine.canonicalPath(
                homeDirectory.standardizedFileURL.appending(path: $0, directoryHint: .isDirectory)
            )
        }

        return allowedLibraryDirs.contains { root in
            targetPath.hasPrefix(root + "/") && targetPath != root
        }
    }

    // MARK: - Heuristic Residual Discovery

    private static func findAssociatedResiduals(
        bundleID: String,
        displayName: String,
        bundleStem: String,
        libraryIndex: UserLibraryIndex
    ) -> [AppResidualItem] {
        var found: [AppResidualItem] = []
        var seenPaths = Set<String>()

        let nameKeys = candidateNameKeys(bundleID: bundleID, displayName: displayName, bundleStem: bundleStem)

        func addEntry(
            _ entry: UserLibraryIndex.Entry,
            kind: AppResidualKind,
            tier: CleanSafetyTier
        ) {
            let path = CleanRuleEngine.canonicalPath(entry.url)
            guard seenPaths.insert(path).inserted else { return }
            let metrics = CleanRuleEngine.directoryMetrics(at: entry.url)
            guard metrics.bytes > 0 else { return }
            found.append(
                AppResidualItem(
                    url: entry.url,
                    kind: kind,
                    title: entry.name,
                    subtitle: compactDisplayPath(entry.url, homeDirectory: libraryIndex.homeDirectory),
                    sizeBytes: metrics.bytes,
                    safetyTier: tier
                )
            )
        }

        // 1. Application Support
        for entry in libraryIndex.appSupport {
            if matchesBundleIDOrName(entry.lowerName, bundleID: bundleID, nameKeys: nameKeys) {
                addEntry(entry, kind: .appSupport, tier: .safe)
            }
        }

        // 2. Caches
        for entry in libraryIndex.caches {
            if matchesBundleIDOrName(entry.lowerName, bundleID: bundleID, nameKeys: nameKeys) {
                addEntry(entry, kind: .caches, tier: .safe)
            }
        }

        // 3. Sandbox Containers
        for entry in libraryIndex.containers {
            if matchesBundleIDPrefix(entry.lowerName, bundleID: bundleID) {
                addEntry(entry, kind: .containers, tier: .safe)
            }
        }

        // 4. Preferences & ByHost Preferences
        for entry in libraryIndex.preferences where entry.lowerName.hasSuffix(".plist") {
            let stem = String(entry.lowerName.dropLast(".plist".count))
            if matchesBundleIDPrefix(stem, bundleID: bundleID) {
                addEntry(entry, kind: .preferences, tier: .safe)
            }
        }
        for entry in libraryIndex.byHostPreferences where entry.lowerName.hasSuffix(".plist") {
            if entry.lowerName.hasPrefix(bundleID + ".") {
                addEntry(entry, kind: .preferences, tier: .safe)
            }
        }

        // 5. Saved Application State, HTTPStorages, WebKit
        for entry in libraryIndex.savedStates where entry.lowerName.hasSuffix(".savedstate") {
            let stem = String(entry.lowerName.dropLast(".savedstate".count))
            if matchesBundleIDPrefix(stem, bundleID: bundleID) {
                addEntry(entry, kind: .stateAndWeb, tier: .safe)
            }
        }
        for entry in libraryIndex.httpStorages {
            let stem = entry.lowerName.hasSuffix(".binarycookies")
                ? String(entry.lowerName.dropLast(".binarycookies".count))
                : entry.lowerName
            if matchesBundleIDPrefix(stem, bundleID: bundleID) {
                addEntry(entry, kind: .stateAndWeb, tier: .safe)
            }
        }
        for entry in libraryIndex.webKit {
            if matchesBundleIDPrefix(entry.lowerName, bundleID: bundleID) {
                addEntry(entry, kind: .stateAndWeb, tier: .safe)
            }
        }

        // 6. Logs
        for entry in libraryIndex.logs {
            if matchesBundleIDOrName(entry.lowerName, bundleID: bundleID, nameKeys: nameKeys) {
                addEntry(entry, kind: .logs, tier: .safe)
            }
        }

        // 7. Group Containers & LaunchAgents (`.checkFirst` so shared vendor containers require manual review)
        for entry in libraryIndex.groupContainers {
            if entry.lowerName.contains(bundleID) {
                addEntry(entry, kind: .sharedAndAgents, tier: .checkFirst)
            }
        }
        for entry in libraryIndex.launchAgents where entry.lowerName.hasSuffix(".plist") {
            let stem = String(entry.lowerName.dropLast(".plist".count))
            if matchesBundleIDPrefix(stem, bundleID: bundleID) {
                addEntry(entry, kind: .sharedAndAgents, tier: .checkFirst)
            }
        }

        return found.sorted { lhs, rhs in
            if lhs.sizeBytes != rhs.sizeBytes {
                return lhs.sizeBytes > rhs.sizeBytes
            }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    private static func matchesBundleIDPrefix(_ candidate: String, bundleID: String) -> Bool {
        candidate == bundleID
            || candidate.hasPrefix(bundleID + ".")
            || candidate.hasPrefix(bundleID + "-")
    }

    private static func matchesBundleIDOrName(
        _ candidate: String,
        bundleID: String,
        nameKeys: Set<String>
    ) -> Bool {
        if matchesBundleIDPrefix(candidate, bundleID: bundleID) {
            return true
        }
        if nameKeys.contains(candidate) {
            return true
        }
        let compactCandidate = candidate.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
        if nameKeys.contains(compactCandidate) {
            return true
        }
        for key in nameKeys where key.count >= 4 {
            if compactCandidate.hasPrefix(key) {
                return true
            }
        }
        return false
    }

    private static func candidateNameKeys(
        bundleID: String,
        displayName: String,
        bundleStem: String
    ) -> Set<String> {
        var keys = Set<String>()
        for raw in [displayName, bundleStem] {
            let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if lower.count >= 3 && !genericAppNames.contains(lower) {
                keys.insert(lower)
            }
            let compact = lower.replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "-", with: "")
            if compact.count >= 3 && !genericAppNames.contains(compact) {
                keys.insert(compact)
            }
        }
        let parts = bundleID.split(separator: ".").map(String.init)
        if parts.count >= 3 {
            let last = parts[parts.count - 1]
            let prev = parts[parts.count - 2]
            if genericAppNames.contains(last) {
                if prev.count >= 4 && !genericAppNames.contains(prev) {
                    keys.insert(prev)
                }
            } else if last.count >= 4 {
                keys.insert(last)
            }
        }
        return keys
    }

    private static func discoverAppBundles(in roots: [URL]) -> [URL] {
        var urls: [URL] = []
        var seen = Set<String>()
        let fm = FileManager.default
        let options: FileManager.DirectoryEnumerationOptions = [
            .skipsHiddenFiles,
            .skipsPackageDescendants,
            .skipsSubdirectoryDescendants
        ]

        for root in roots {
            guard let items = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: options
            ) else { continue }

            for item in items where !CleanRuleEngine.isSymbolicLink(item) {
                if item.pathExtension.lowercased() == "app" {
                    let path = CleanRuleEngine.canonicalPath(item)
                    if seen.insert(path).inserted {
                        urls.append(item.standardizedFileURL)
                    }
                } else if let subItems = try? fm.contentsOfDirectory(
                    at: item,
                    includingPropertiesForKeys: [.isSymbolicLinkKey],
                    options: options
                ) {
                    for sub in subItems where sub.pathExtension.lowercased() == "app" && !CleanRuleEngine.isSymbolicLink(sub) {
                        let path = CleanRuleEngine.canonicalPath(sub)
                        if seen.insert(path).inserted {
                            urls.append(sub.standardizedFileURL)
                        }
                    }
                }
            }
        }
        return urls
    }

    private static func compactDisplayPath(_ url: URL, homeDirectory: URL) -> String {
        let path = CleanRuleEngine.canonicalPath(url)
        let homePath = CleanRuleEngine.canonicalPath(homeDirectory)
        if path.hasPrefix(homePath + "/") {
            return "~" + String(path.dropFirst(homePath.count))
        }
        return path
    }
}
