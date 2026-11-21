import AppKit
import Darwin
import Foundation

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
        guard CleanRuleEngine.isDirectory(directory) else { return [] }
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
        "agent", "app", "application", "applications", "client", "daemon", "darwin",
        "desktop", "electron", "extension", "helper", "launcher", "mac", "macos",
        "macosx", "manager", "notifier", "osx", "player", "pro", "server", "service",
        "studio", "tool", "updater", "viewer", "wrapper"
    ]

    /// Scans `/Applications` and `~/Applications` (or custom test directories) and resolves each app's `~/Library` leftovers.
    static func scanInstalledApps(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationDirectories: [URL]? = nil,
        cancelToken: CleanCancellationToken? = nil
    ) -> [InstalledAppTarget] {
        guard cancelToken?.isCancelled != true else { return [] }
        let stdHome = homeDirectory.standardizedFileURL
        let appDirs = applicationDirectories ?? [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            stdHome.appending(path: "Applications", directoryHint: .isDirectory)
        ]

        let bundleURLs = discoverAppBundles(in: appDirs, cancelToken: cancelToken)
        guard !bundleURLs.isEmpty, cancelToken?.isCancelled != true else { return [] }

        let libraryIndex = UserLibraryIndex(homeDirectory: stdHome)
        let collector = LockedCollector<InstalledAppTarget>()

        DispatchQueue.concurrentPerform(iterations: bundleURLs.count) { idx in
            guard cancelToken?.isCancelled != true else { return }
            let bundleURL = bundleURLs[idx]
            if let target = inspectApp(at: bundleURL, libraryIndex: libraryIndex, cancelToken: cancelToken) {
                collector.append(target)
            }
        }

        guard cancelToken?.isCancelled != true else { return [] }
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
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        cancelToken: CleanCancellationToken? = nil
    ) -> InstalledAppTarget? {
        let libraryIndex = UserLibraryIndex(homeDirectory: homeDirectory)
        return inspectApp(at: appURL, libraryIndex: libraryIndex, cancelToken: cancelToken)
    }

    static func inspectApp(
        at appURL: URL,
        libraryIndex: UserLibraryIndex,
        cancelToken: CleanCancellationToken? = nil
    ) -> InstalledAppTarget? {
        guard cancelToken?.isCancelled != true else { return nil }
        let stdURL = appURL.standardizedFileURL
        guard stdURL.isFileURL,
              stdURL.pathExtension.lowercased() == "app",
              CleanRuleEngine.isDirectory(stdURL) else {
            return nil
        }

        let resolvedPath = CleanRuleEngine.canonicalResolvedPath(stdURL)
        if isProtectedSystemOrTrashPath(resolvedPath, homeDirectory: libraryIndex.homeDirectory) {
            return nil
        }

        if resolvedPath == CleanRuleEngine.canonicalResolvedPath(Bundle.main.bundleURL) {
            return nil
        }

        let plistURL = stdURL.appending(path: "Contents/Info.plist")
        guard let plist = NSDictionary(contentsOf: plistURL),
              let rawBundleID = (plist["CFBundleIdentifier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawBundleID.isEmpty else {
            return nil
        }

        if let packageType = plist["CFBundlePackageType"] as? String,
           !packageType.isEmpty,
           packageType != "APPL" {
            return nil
        }
        let macOSDir = stdURL.appending(path: "Contents/MacOS", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: macOSDir.path(percentEncoded: false)) else {
            return nil
        }

        let lowerBundleID = rawBundleID.lowercased()
        if isProtectedBundleID(lowerBundleID) {
            return nil
        }

        let bundleStem = stdURL.deletingPathExtension().lastPathComponent
        let displayName = (plist["CFBundleDisplayName"] as? String)
            ?? (plist["CFBundleName"] as? String)
            ?? bundleStem
        let version = (plist["CFBundleShortVersionString"] as? String)
            ?? (plist["CFBundleVersion"] as? String)
            ?? "1.0"

        let bundleMetrics = CleanRuleEngine.directoryMetrics(at: stdURL, cancelToken: cancelToken)
        guard cancelToken?.isCancelled != true, bundleMetrics.bytes > 0 else { return nil }

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
            libraryIndex: libraryIndex,
            cancelToken: cancelToken
        )
        guard cancelToken?.isCancelled != true else { return nil }

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
        allowedApplicationDirectories: [URL]? = nil,
        allowRunning: Bool = false
    ) -> Bool {
        let fm = FileManager.default
        let targetPath = CleanRuleEngine.canonicalPath(item.url)
        let resolvedTargetPath = CleanRuleEngine.canonicalResolvedPath(item.url)
        guard fm.fileExists(atPath: targetPath),
              !CleanRuleEngine.isSymbolicLink(item.url) else {
            return false
        }

        if isProtectedSystemOrTrashPath(targetPath, homeDirectory: homeDirectory)
            || isProtectedSystemOrTrashPath(resolvedTargetPath, homeDirectory: homeDirectory) {
            return false
        }

        let lowerID = app.bundleID.lowercased()
        if isProtectedBundleID(lowerID) {
            return false
        }
        if resolvedTargetPath == CleanRuleEngine.canonicalResolvedPath(Bundle.main.bundleURL) {
            return false
        }

        if !allowRunning && !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty {
            return false
        }

        if item.kind == .appBundle {
            let resolvedAppBundlePath = CleanRuleEngine.canonicalResolvedPath(app.bundleURL)
            guard resolvedTargetPath == resolvedAppBundlePath && resolvedTargetPath.lowercased().hasSuffix(".app") else {
                return false
            }
            if let allowedApplicationDirectories {
                return CleanRuleEngine.isStrictDescendant(item.url, ofAnyRoot: allowedApplicationDirectories)
            }
            return true
        }

        let stdHome = homeDirectory.standardizedFileURL
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
            stdHome.appending(path: $0, directoryHint: .isDirectory)
        }

        return CleanRuleEngine.isStrictDescendant(item.url, ofAnyRoot: allowedLibraryDirs)
    }

    private static func isProtectedBundleID(_ lowerBundleID: String) -> Bool {
        if lowerBundleID.hasPrefix("com.apple.") || lowerBundleID == "dev.softlive.softlive" {
            return true
        }
        if let mainID = Bundle.main.bundleIdentifier?.lowercased(), lowerBundleID == mainID {
            return true
        }
        return false
    }

    private static func isProtectedSystemOrTrashPath(_ path: String, homeDirectory: URL) -> Bool {
        if path == "/System" || path.hasPrefix("/System/")
            || path == "/Library/Apple" || path.hasPrefix("/Library/Apple/")
            || path == "/usr" || path.hasPrefix("/usr/")
            || path == "/bin" || path.hasPrefix("/bin/")
            || path == "/sbin" || path.hasPrefix("/sbin/") {
            return true
        }
        let trashPath = CleanRuleEngine.canonicalResolvedPath(
            homeDirectory.appending(path: ".Trash", directoryHint: .isDirectory)
        )
        return path == trashPath || path.hasPrefix(trashPath + "/")
    }

    // MARK: - Heuristic Residual Discovery

    private static func findAssociatedResiduals(
        bundleID: String,
        displayName: String,
        bundleStem: String,
        libraryIndex: UserLibraryIndex,
        cancelToken: CleanCancellationToken? = nil
    ) -> [AppResidualItem] {
        var found: [AppResidualItem] = []
        var seenPaths = Set<String>()

        let nameKeys = candidateNameKeys(bundleID: bundleID, displayName: displayName, bundleStem: bundleStem)

        func addEntry(
            _ entry: UserLibraryIndex.Entry,
            kind: AppResidualKind,
            tier: CleanSafetyTier
        ) {
            guard cancelToken?.isCancelled != true else { return }
            let path = CleanRuleEngine.canonicalPath(entry.url)
            guard seenPaths.insert(path).inserted else { return }
            let metrics = CleanRuleEngine.directoryMetrics(at: entry.url, cancelToken: cancelToken)
            guard cancelToken?.isCancelled != true, metrics.bytes > 0 else { return }
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
            guard cancelToken?.isCancelled != true else { return [] }
            if matchesBundleIDOrName(entry.lowerName, bundleID: bundleID, nameKeys: nameKeys) {
                addEntry(entry, kind: .appSupport, tier: .safe)
            }
        }

        // 2. Caches
        for entry in libraryIndex.caches {
            guard cancelToken?.isCancelled != true else { return [] }
            if matchesBundleIDOrName(entry.lowerName, bundleID: bundleID, nameKeys: nameKeys) {
                addEntry(entry, kind: .caches, tier: .safe)
            }
        }

        // 3. Sandbox Containers
        for entry in libraryIndex.containers {
            guard cancelToken?.isCancelled != true else { return [] }
            if matchesBundleIDPrefix(entry.lowerName, bundleID: bundleID) {
                addEntry(entry, kind: .containers, tier: .safe)
            }
        }

        // 4. Preferences & ByHost Preferences
        for entry in libraryIndex.preferences where entry.lowerName.hasSuffix(".plist") {
            guard cancelToken?.isCancelled != true else { return [] }
            let stem = String(entry.lowerName.dropLast(".plist".count))
            if matchesBundleIDPrefix(stem, bundleID: bundleID) {
                addEntry(entry, kind: .preferences, tier: .safe)
            }
        }
        for entry in libraryIndex.byHostPreferences where entry.lowerName.hasSuffix(".plist") {
            guard cancelToken?.isCancelled != true else { return [] }
            if entry.lowerName.hasPrefix(bundleID + ".") {
                addEntry(entry, kind: .preferences, tier: .safe)
            }
        }

        // 5. Saved Application State, HTTPStorages, WebKit
        for entry in libraryIndex.savedStates where entry.lowerName.hasSuffix(".savedstate") {
            guard cancelToken?.isCancelled != true else { return [] }
            let stem = String(entry.lowerName.dropLast(".savedstate".count))
            if matchesBundleIDPrefix(stem, bundleID: bundleID) {
                addEntry(entry, kind: .stateAndWeb, tier: .safe)
            }
        }
        for entry in libraryIndex.httpStorages {
            guard cancelToken?.isCancelled != true else { return [] }
            let stem = entry.lowerName.hasSuffix(".binarycookies")
                ? String(entry.lowerName.dropLast(".binarycookies".count))
                : entry.lowerName
            if matchesBundleIDPrefix(stem, bundleID: bundleID) {
                addEntry(entry, kind: .stateAndWeb, tier: .safe)
            }
        }
        for entry in libraryIndex.webKit {
            guard cancelToken?.isCancelled != true else { return [] }
            if matchesBundleIDPrefix(entry.lowerName, bundleID: bundleID) {
                addEntry(entry, kind: .stateAndWeb, tier: .safe)
            }
        }

        // 6. Logs
        for entry in libraryIndex.logs {
            guard cancelToken?.isCancelled != true else { return [] }
            if matchesBundleIDOrName(entry.lowerName, bundleID: bundleID, nameKeys: nameKeys) {
                addEntry(entry, kind: .logs, tier: .safe)
            }
        }

        // 7. Group Containers & LaunchAgents (`.checkFirst` so shared vendor containers require manual review)
        for entry in libraryIndex.groupContainers {
            guard cancelToken?.isCancelled != true else { return [] }
            if matchesBoundaryDelimitedBundleID(entry.lowerName, bundleID: bundleID) {
                addEntry(entry, kind: .sharedAndAgents, tier: .checkFirst)
            }
        }
        for entry in libraryIndex.launchAgents where entry.lowerName.hasSuffix(".plist") {
            guard cancelToken?.isCancelled != true else { return [] }
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

    private static func matchesBoundaryDelimitedBundleID(_ candidate: String, bundleID: String) -> Bool {
        candidate == bundleID
            || candidate.hasSuffix("." + bundleID)
            || candidate.hasPrefix(bundleID + ".")
            || candidate.contains("." + bundleID + ".")
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
        // Require a word/delimiter boundary after `key` so short names like "Fork" or "Dash"
        // never false-match unrelated apps like "ForkLift" or "Dashlane".
        for key in nameKeys where key.count >= 4 {
            if candidate.hasPrefix(key), candidate.count > key.count {
                let nextIndex = candidate.index(candidate.startIndex, offsetBy: key.count)
                let nextChar = candidate[nextIndex]
                if nextChar == " " || nextChar == "-" || nextChar == "_" || nextChar == "." || nextChar.isNumber {
                    return true
                }
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
            } else if last.count >= 4 && !genericAppNames.contains(last) {
                keys.insert(last)
            }
        }
        return keys
    }

    private static func discoverAppBundles(
        in roots: [URL],
        cancelToken: CleanCancellationToken? = nil
    ) -> [URL] {
        var urls: [URL] = []
        var seen = Set<String>()
        let fm = FileManager.default
        let options: FileManager.DirectoryEnumerationOptions = [
            .skipsHiddenFiles,
            .skipsPackageDescendants,
            .skipsSubdirectoryDescendants
        ]

        for root in roots {
            guard cancelToken?.isCancelled != true else { return [] }
            guard !CleanRuleEngine.isSymbolicLink(root),
                  let items = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: options
            ) else { continue }

            for item in items where !CleanRuleEngine.isSymbolicLink(item) {
                guard cancelToken?.isCancelled != true else { return [] }
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
