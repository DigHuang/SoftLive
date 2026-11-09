import AppKit
import Darwin
import Foundation

/// Immutable snapshot of the local environment used by `CleanRuleEngine` during a scan or pre-trash check.
struct CleanEnvironment: Sendable {
    let homeDirectory: URL
    let runningBundleIDs: Set<String>
    let runningProcessNames: Set<String>
    let runningProductTokens: Set<String>
    let installedBundleIDs: Set<String>
    let installedProductTokens: Set<String>
    let excludedPaths: Set<String>
    let staleDays: Int
    let minimumCacheEntryBytes: UInt64
    let minimumInstallerBytes: UInt64
    let now: Date

    private static let genericBundleSegments: Set<String> = [
        "com", "org", "net", "io", "dev", "me", "co", "app", "apps",
        "mac", "macos", "osx", "darwin", "desktop", "client", "helper",
        "agent", "service", "daemon", "renderer", "notifier", "xpc",
        "extension", "electron", "apple", "github", "google", "microsoft",
        "tencent", "netease", "anthropic", "jetbrains", "adobe"
    ]

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        runningBundleIDs: Set<String>? = nil,
        runningProcessNames: Set<String>? = nil,
        installedBundleIDs: Set<String>? = nil,
        excludedPaths: Set<String>? = nil,
        staleDays: Int = CleanStaleThreshold.sevenDays.rawValue,
        minimumCacheEntryBytes: UInt64 = 64 * 1024,
        minimumInstallerBytes: UInt64 = 20 * 1_048_576,
        now: Date = .now
    ) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        let resolvedBundleIDs: Set<String>
        if let runningBundleIDs {
            resolvedBundleIDs = Set(runningBundleIDs.map { $0.lowercased() })
        } else {
            var ids = Set(
                NSWorkspace.shared.runningApplications
                    .compactMap { $0.bundleIdentifier?.lowercased() }
            )
            ids.insert("dev.softlive.softlive")
            if let mainID = Bundle.main.bundleIdentifier?.lowercased() {
                ids.insert(mainID)
            }
            resolvedBundleIDs = ids
        }
        self.runningBundleIDs = resolvedBundleIDs

        let resolvedProcessNames: Set<String>
        if let runningProcessNames {
            resolvedProcessNames = Set(runningProcessNames.map { $0.lowercased() })
        } else {
            var names = Set<String>()
            for app in NSWorkspace.shared.runningApplications {
                if let loc = app.localizedName?.lowercased(), !loc.isEmpty {
                    names.insert(loc)
                }
                if let bundleName = app.bundleURL?.deletingPathExtension().lastPathComponent.lowercased(),
                   !bundleName.isEmpty {
                    names.insert(bundleName)
                }
            }
            resolvedProcessNames = names
        }
        self.runningProcessNames = resolvedProcessNames
        self.runningProductTokens = Self.extractProductTokens(
            bundleIDs: resolvedBundleIDs,
            names: resolvedProcessNames
        )

        if let installedBundleIDs {
            let lowerInstalled = Set(installedBundleIDs.map { $0.lowercased() }).union(resolvedBundleIDs)
            self.installedBundleIDs = lowerInstalled
            self.installedProductTokens = Self.extractProductTokens(bundleIDs: lowerInstalled, names: [])
        } else {
            let discovered = Self.discoverInstalledApps(homeDirectory: self.homeDirectory)
            let allInstalledIDs = discovered.bundleIDs.union(resolvedBundleIDs)
            self.installedBundleIDs = allInstalledIDs
            self.installedProductTokens = Self.extractProductTokens(
                bundleIDs: allInstalledIDs,
                names: discovered.appNames.union(resolvedProcessNames)
            )
        }

        if let excludedPaths {
            self.excludedPaths = Set(
                excludedPaths.map { CleanRuleEngine.canonicalPath(URL(fileURLWithPath: $0)) }
            )
        } else {
            let cwd = CleanRuleEngine.canonicalPath(URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            self.excludedPaths = [cwd]
        }

        self.staleDays = max(staleDays, 1)
        self.minimumCacheEntryBytes = minimumCacheEntryBytes
        self.minimumInstallerBytes = minimumInstallerBytes
        self.now = now
    }

    private static func extractProductTokens(bundleIDs: Set<String>, names: Set<String>) -> Set<String> {
        var tokens = Set<String>()
        for bid in bundleIDs where !bid.hasPrefix("com.apple.") {
            for part in bid.split(separator: ".").map(String.init) {
                let clean = part.split(separator: "-").first.map(String.init) ?? part
                if clean.count >= 4 && !genericBundleSegments.contains(clean) {
                    tokens.insert(clean)
                }
            }
            if bid.hasPrefix("com.google.chrome") {
                tokens.insert("google")
            }
        }
        for name in names {
            if name.count >= 4 && !genericBundleSegments.contains(name) {
                tokens.insert(name)
            }
            if let firstWord = name.split(whereSeparator: { $0.isWhitespace || $0 == "·" || $0 == "-" }).first.map(String.init),
               firstWord.count >= 4,
               !genericBundleSegments.contains(firstWord) {
                tokens.insert(firstWord)
            }
        }
        return tokens
    }

    private static func discoverInstalledApps(homeDirectory: URL) -> (bundleIDs: Set<String>, appNames: Set<String>) {
        var bundleIDs = Set<String>()
        var appNames = Set<String>()
        let appDirs: [URL] = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
            homeDirectory.appending(path: "Applications", directoryHint: .isDirectory)
        ]

        let fm = FileManager.default
        for root in appDirs {
            guard let items = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for item in items {
                if item.pathExtension.lowercased() == "app" {
                    recordAppBundle(at: item, bundleIDs: &bundleIDs, appNames: &appNames)
                } else if let subItems = try? fm.contentsOfDirectory(
                    at: item,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) {
                    for sub in subItems where sub.pathExtension.lowercased() == "app" {
                        recordAppBundle(at: sub, bundleIDs: &bundleIDs, appNames: &appNames)
                    }
                }
            }
        }
        return (bundleIDs, appNames)
    }

    private static func recordAppBundle(at appURL: URL, bundleIDs: inout Set<String>, appNames: inout Set<String>) {
        let name = appURL.deletingPathExtension().lastPathComponent.lowercased()
        if !name.isEmpty {
            appNames.insert(name)
        }
        let plistURL = appURL.appending(path: "Contents/Info.plist")
        if let dict = NSDictionary(contentsOf: plistURL),
           let bid = (dict["CFBundleIdentifier"] as? String)?.lowercased(),
           !bid.isEmpty {
            bundleIDs.insert(bid)
        }
    }

    nonisolated var isXcodeRunning: Bool {
        runningBundleIDs.contains("com.apple.dt.xcode")
            || runningProcessNames.contains("xcode")
    }

    nonisolated var isSimulatorRunning: Bool {
        runningBundleIDs.contains("com.apple.iphonesimulator")
            || runningProcessNames.contains("simulator")
    }
}

nonisolated private final class LockedCollector<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Element] = []

    init() {}

    func append(_ element: Element) {
        lock.lock()
        storage.append(element)
        lock.unlock()
    }

    func append(contentsOf elements: [Element]) {
        lock.lock()
        storage.append(contentsOf: elements)
        lock.unlock()
    }

    var elements: [Element] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// Allowlist-only scan and validation engine.
/// Never touches TCC-protected privacy containers, never follows symlinks outside scan roots,
/// and skips currently running applications.
nonisolated enum CleanRuleEngine {
    /// System and Apple-managed cache directory names under `~/Library/Caches` that must never be offered.
    private static let protectedCacheEntryNames: Set<String> = [
        "cloudkit",
        "com.apple.ap.adprivacyd",
        "com.apple.appleaccountd",
        "com.apple.bird",
        "com.apple.cache_delete",
        "com.apple.cloudd",
        "com.apple.containermanagerd",
        "com.apple.coreservices.iconservices",
        "com.apple.findmy",
        "com.apple.gamed",
        "com.apple.helpd",
        "com.apple.homed",
        "com.apple.icloud.fmfd",
        "com.apple.nsurlsessiond",
        "com.apple.parsecd",
        "com.apple.passkit",
        "com.apple.safari",
        "com.apple.spotlight",
        "com.apple.touristd",
        "familycircle",
        "geoservices",
        "passkit",
        "dev.softlive.softlive",
        "softlive"
    ]

    /// Cache directories under `~/Library/Caches` that are categorized under `.devCaches` so each byte is counted once.
    private static let devCacheNamesInLibraryCaches: Set<String> = [
        "homebrew",
        "pnpm",
        "yarn",
        "bun",
        "mise",
        "org.swift.swiftpm",
        "pip",
        "uv",
        "pypoetry",
        "cocoapods",
        "go-build",
        "typescript",
        "ms-playwright",
        "cypress"
    ]

    private static let installerExtensions: Set<String> = [
        "dmg", "pkg", "mpkg", "xip", "iso", "zip", "tgz", "crdownload", "part"
    ]

    private static let projectArtifactNames: Set<String> = [
        ".build", "node_modules", "target", "dist", ".next", ".turbo"
    ]

    nonisolated static func canonicalPath(_ url: URL) -> String {
        let raw = url.standardizedFileURL.path(percentEncoded: false)
        if raw.count > 1 && raw.hasSuffix("/") {
            return String(raw.dropLast())
        }
        return raw
    }

    /// Performs a full allowlist scan across all 4 categories in parallel across CPU cores.
    nonisolated static func scan(environment: CleanEnvironment) -> [CleanCandidate] {
        let collector = LockedCollector<CleanCandidate>()

        DispatchQueue.concurrentPerform(iterations: 4) { index in
            let partial: [CleanCandidate]
            switch index {
            case 0:
                partial = scanAppCachesAndLogs(environment: environment)
            case 1:
                partial = scanDevAndPackageCaches(environment: environment)
            case 2:
                partial = scanStaleProjectArtifacts(environment: environment)
            default:
                partial = scanLeftoversAndInstallers(environment: environment)
            }
            collector.append(contentsOf: partial)
        }

        return collector.elements.sorted { lhs, rhs in
            if lhs.sizeBytes != rhs.sizeBytes {
                return lhs.sizeBytes > rhs.sizeBytes
            }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    /// Re-verifies right before trashing that the candidate still exists, is not a symlink escaping allowlisted roots,
    /// is not inside an excluded path, and does not belong to an application that launched since the scan.
    nonisolated static func canSafelyTrash(_ candidate: CleanCandidate, environment: CleanEnvironment) -> Bool {
        let fm = FileManager.default
        let targetURL = candidate.url.standardizedFileURL
        let targetPath = canonicalPath(targetURL)

        guard fm.fileExists(atPath: targetPath) else { return false }
        guard !isSymbolicLink(targetURL) else { return false }

        for excluded in environment.excludedPaths {
            if targetPath == excluded || targetPath.hasPrefix(excluded + "/") {
                return false
            }
        }

        let allowedRoots = allowlistedRootPaths(for: candidate.category, home: environment.homeDirectory)
        guard allowedRoots.contains(where: { root in
            targetPath.hasPrefix(root + "/") && targetPath != root
        }) else {
            return false
        }

        let entryName = targetURL.lastPathComponent.lowercased()
        switch candidate.category {
        case .appCaches:
            if isProtectedOrRunningAppEntry(entryName, environment: environment) {
                return false
            }
        case .devCaches:
            if targetPath.contains("/DerivedData/") && environment.isXcodeRunning {
                return false
            }
            if targetPath.contains("/CoreSimulator/Caches/") && (environment.isXcodeRunning || environment.isSimulatorRunning) {
                return false
            }
        case .staleArtifacts:
            break
        case .leftoversAndInstallers:
            let baseName = entryName.hasSuffix(".savedstate")
                ? String(entryName.dropLast(".savedstate".count))
                : entryName
            if isProtectedOrRunningAppEntry(baseName, environment: environment) {
                return false
            }
        }

        return true
    }

    // MARK: - Category 1: App Caches & Logs

    nonisolated private static func scanAppCachesAndLogs(environment: CleanEnvironment) -> [CleanCandidate] {
        let home = environment.homeDirectory
        let scanRoots: [(url: URL, labelPrefix: String)] = [
            (home.appending(path: "Library/Caches", directoryHint: .isDirectory), "~/Library/Caches"),
            (home.appending(path: "Library/Logs", directoryHint: .isDirectory), "~/Library/Logs"),
            (home.appending(path: "Library/DiagnosticReports", directoryHint: .isDirectory), "~/Library/DiagnosticReports"),
            (home.appending(path: "Library/Application Support/CrashReporter", directoryHint: .isDirectory), "~/Library/Application Support/CrashReporter")
        ]

        var workItems: [(child: URL, rawName: String, labelPrefix: String)] = []
        for root in scanRoots {
            for child in immediateChildren(of: root.url) {
                guard !isSymbolicLink(child) else { continue }
                let rawName = child.lastPathComponent
                let normalized = rawName.lowercased()

                if root.labelPrefix == "~/Library/Caches",
                   devCacheNamesInLibraryCaches.contains(normalized) {
                    continue
                }

                if isProtectedOrRunningAppEntry(normalized, environment: environment) {
                    continue
                }
                workItems.append((child, rawName, root.labelPrefix))
            }
        }

        let items = workItems
        let collector = LockedCollector<CleanCandidate>()
        DispatchQueue.concurrentPerform(iterations: items.count) { idx in
            let item = items[idx]
            let metrics = directoryMetrics(at: item.child)
            guard metrics.bytes >= environment.minimumCacheEntryBytes else { return }
            let displayName = readableEntryTitle(from: item.rawName, stripSuffix: nil)
            let candidate = CleanCandidate(
                url: item.child,
                category: .appCaches,
                title: displayName,
                subtitle: "\(item.labelPrefix)/\(item.rawName)",
                sizeBytes: metrics.bytes,
                safetyTier: .safe,
                lastModified: metrics.lastModified
            )
            collector.append(candidate)
        }

        return collector.elements
    }

    // MARK: - Category 2: Dev Tools, Xcode & Package Caches

    nonisolated private static func scanDevAndPackageCaches(environment: CleanEnvironment) -> [CleanCandidate] {
        var candidates: [CleanCandidate] = []
        let home = environment.homeDirectory

        // 2A. Xcode & Simulator
        if !environment.isXcodeRunning {
            let derivedData = home.appending(path: "Library/Developer/Xcode/DerivedData", directoryHint: .isDirectory)
            for child in immediateChildren(of: derivedData) where !isSymbolicLink(child) {
                let metrics = directoryMetrics(at: child)
                guard metrics.bytes >= environment.minimumCacheEntryBytes else { continue }
                let name = child.lastPathComponent
                let projectTitle = name.split(separator: "-", maxSplits: 1).first.map(String.init) ?? name
                candidates.append(
                    CleanCandidate(
                        url: child,
                        category: .devCaches,
                        title: "DerivedData · \(projectTitle)",
                        subtitle: "~/Library/Developer/Xcode/DerivedData/\(name)",
                        sizeBytes: metrics.bytes,
                        safetyTier: .safe,
                        lastModified: metrics.lastModified
                    )
                )
            }
        }

        if !environment.isXcodeRunning && !environment.isSimulatorRunning {
            let simCaches = home.appending(path: "Library/Developer/CoreSimulator/Caches", directoryHint: .isDirectory)
            for child in immediateChildren(of: simCaches) where !isSymbolicLink(child) {
                let metrics = directoryMetrics(at: child)
                guard metrics.bytes >= environment.minimumCacheEntryBytes else { continue }
                let name = child.lastPathComponent
                candidates.append(
                    CleanCandidate(
                        url: child,
                        category: .devCaches,
                        title: "Simulator Cache · \(name)",
                        subtitle: "~/Library/Developer/CoreSimulator/Caches/\(name)",
                        sizeBytes: metrics.bytes,
                        safetyTier: .safe,
                        lastModified: metrics.lastModified
                    )
                )
            }
        }

        let xcodeCheckFirstRoots: [(relPath: String, label: String)] = [
            ("Library/Developer/Xcode/iOS DeviceSupport", "iOS DeviceSupport"),
            ("Library/Developer/Xcode/watchOS DeviceSupport", "watchOS DeviceSupport"),
            ("Library/Developer/Xcode/tvOS DeviceSupport", "tvOS DeviceSupport"),
            ("Library/Developer/Xcode/Archives", "Xcode Archive")
        ]

        for spec in xcodeCheckFirstRoots {
            let rootURL = home.appending(path: spec.relPath, directoryHint: .isDirectory)
            for child in immediateChildren(of: rootURL) where !isSymbolicLink(child) {
                let metrics = directoryMetrics(at: child)
                guard metrics.bytes >= environment.minimumCacheEntryBytes else { continue }
                let name = child.lastPathComponent
                candidates.append(
                    CleanCandidate(
                        url: child,
                        category: .devCaches,
                        title: "\(spec.label) · \(name)",
                        subtitle: "~/\(spec.relPath)/\(name)",
                        sizeBytes: metrics.bytes,
                        safetyTier: .checkFirst,
                        lastModified: metrics.lastModified
                    )
                )
            }
        }

        // 2B. Package Managers, Build Toolchains & Local AI Caches
        let pkgSpecs: [(relPath: String, title: String, tier: CleanSafetyTier)] = [
            ("Library/Caches/Homebrew", "Homebrew Cache", .safe),
            (".npm/_cacache", "npm (_cacache)", .safe),
            ("Library/Caches/pnpm", "pnpm Cache", .safe),
            (".local/share/pnpm/store", "pnpm Store", .safe),
            ("Library/Caches/Yarn", "Yarn Cache", .safe),
            ("Library/Caches/bun", "Bun Cache", .safe),
            (".bun/install/cache", "Bun Install Cache", .safe),
            ("Library/Caches/mise", "mise Toolchain Cache", .safe),
            ("Library/Caches/org.swift.swiftpm", "SwiftPM Package Cache", .safe),
            (".cargo/registry/cache", "Cargo Registry Cache", .safe),
            (".cargo/git/db", "Cargo Git Cache", .safe),
            ("Library/Caches/pip", "pip Cache", .safe),
            ("Library/Caches/uv", "uv Cache", .safe),
            ("Library/Caches/pypoetry", "Poetry Cache", .safe),
            ("Library/Caches/CocoaPods", "CocoaPods Cache", .safe),
            ("Library/Caches/go-build", "Go Build Cache", .safe),
            ("Library/Caches/typescript", "TypeScript Cache", .safe),
            ("Library/Caches/ms-playwright", "Playwright Browsers", .checkFirst),
            ("Library/Caches/Cypress", "Cypress Cache", .checkFirst),
            (".gradle/caches", "Gradle Build Cache", .safe),
            (".m2/repository", "Maven Local Repo", .checkFirst),
            (".cache/huggingface/hub", "Hugging Face Models", .checkFirst)
        ]

        for spec in pkgSpecs {
            let targetURL = home.appending(path: spec.relPath, directoryHint: .isDirectory)
            guard FileManager.default.fileExists(atPath: targetURL.path(percentEncoded: false)),
                  !isSymbolicLink(targetURL) else {
                continue
            }
            let metrics = directoryMetrics(at: targetURL)
            guard metrics.bytes >= environment.minimumCacheEntryBytes else { continue }
            candidates.append(
                CleanCandidate(
                    url: targetURL,
                    category: .devCaches,
                    title: spec.title,
                    subtitle: "~/\(spec.relPath)",
                    sizeBytes: metrics.bytes,
                    safetyTier: spec.tier,
                    lastModified: metrics.lastModified
                )
            )
        }

        return candidates
    }

    // MARK: - Category 3: Stale Project Build Artifacts

    nonisolated private static func scanStaleProjectArtifacts(environment: CleanEnvironment) -> [CleanCandidate] {
        var candidates: [CleanCandidate] = []
        let home = environment.homeDirectory
        let staleCutoff = environment.now.addingTimeInterval(-TimeInterval(environment.staleDays) * 86_400)

        let workspaceRelPaths = [
            "Documents/GitHub",
            "Developer",
            "Projects",
            "Code",
            "Work"
        ]

        for relPath in workspaceRelPaths {
            let rootURL = home.appending(path: relPath, directoryHint: .isDirectory)
            guard FileManager.default.fileExists(atPath: rootURL.path(percentEncoded: false)),
                  !isSymbolicLink(rootURL) else {
                continue
            }
            candidates.append(
                contentsOf: scanProjectWorkspace(
                    at: rootURL,
                    displayPrefix: "~/\(relPath)",
                    staleCutoff: staleCutoff,
                    environment: environment
                )
            )
        }

        return candidates
    }

    nonisolated private static func scanProjectWorkspace(
        at workspaceRoot: URL,
        displayPrefix: String,
        staleCutoff: Date,
        environment: CleanEnvironment
    ) -> [CleanCandidate] {
        var found: [CleanCandidate] = []

        func walkDirectory(
            _ dir: URL,
            relativeComponents: [String],
            depth: Int,
            inheritedRepoDate: Date?
        ) {
            guard depth <= 3 else { return }
            let stdPath = canonicalPath(dir)
            for excluded in environment.excludedPaths {
                if stdPath == excluded || stdPath.hasPrefix(excluded + "/") {
                    return
                }
            }

            let children = immediateChildren(of: dir, includeHidden: true)
            let hasGit = children.contains { $0.lastPathComponent == ".git" }
            let effectiveRepoDate: Date?
            if hasGit {
                let repoDate = latestRepositoryActivityDate(in: dir, children: children)
                // If this Git repository has been active within the threshold window, skip the entire repository
                // (including all monorepo subpackages under `projects/` or `packages/`).
                if let repoDate, repoDate > staleCutoff {
                    return
                }
                effectiveRepoDate = repoDate
            } else {
                effectiveRepoDate = inheritedRepoDate
            }

            for child in children where !isSymbolicLink(child) {
                let name = child.lastPathComponent
                if name == ".git" || name == ".svn" || name == ".hg" || name == ".DS_Store" {
                    continue
                }

                if projectArtifactNames.contains(name) {
                    guard isDirectory(child) else { continue }
                    if name == "target" && !isRustOrMavenProject(dir) {
                        continue
                    }
                    let projectLastActive = effectiveRepoDate ?? latestProjectActivityDate(in: dir, artifactURL: child)
                    if let projectLastActive, projectLastActive > staleCutoff {
                        continue
                    }
                    let metrics = directoryMetrics(at: child)
                    guard metrics.bytes >= environment.minimumCacheEntryBytes else { continue }
                    let fullRelPath = relativeComponents.isEmpty ? dir.lastPathComponent : relativeComponents.joined(separator: "/")
                    let compactLabel: String
                    if relativeComponents.count >= 3,
                       let first = relativeComponents.first,
                       let last = relativeComponents.last {
                        compactLabel = "\(first)/\(last)"
                    } else {
                        compactLabel = fullRelPath
                    }
                    found.append(
                        CleanCandidate(
                            url: child,
                            category: .staleArtifacts,
                            title: "\(compactLabel) · \(name)",
                            subtitle: "\(displayPrefix)/\(fullRelPath)/\(name)",
                            sizeBytes: metrics.bytes,
                            safetyTier: .safe,
                            lastModified: projectLastActive ?? metrics.lastModified
                        )
                    )
                } else if depth < 3 && !name.hasPrefix(".") && isDirectory(child) {
                    walkDirectory(
                        child,
                        relativeComponents: relativeComponents + [name],
                        depth: depth + 1,
                        inheritedRepoDate: effectiveRepoDate
                    )
                }
            }
        }

        walkDirectory(workspaceRoot, relativeComponents: [], depth: 0, inheritedRepoDate: nil)
        return found
    }

    // MARK: - Category 4: Orphaned App Leftovers & Leftover Installers

    nonisolated private static func scanLeftoversAndInstallers(environment: CleanEnvironment) -> [CleanCandidate] {
        var candidates: [CleanCandidate] = []
        let home = environment.homeDirectory
        let staleCutoff = environment.now.addingTimeInterval(-TimeInterval(environment.staleDays) * 86_400)

        // 4A. Saved Application State (*.savedState)
        let savedStateRoot = home.appending(path: "Library/Saved Application State", directoryHint: .isDirectory)
        for child in immediateChildren(of: savedStateRoot) where !isSymbolicLink(child) {
            let rawName = child.lastPathComponent
            let lower = rawName.lowercased()
            let baseID = lower.hasSuffix(".savedstate")
                ? String(lower.dropLast(".savedstate".count))
                : lower
            guard !isProtectedOrRunningAppEntry(baseID, environment: environment) else { continue }
            let metrics = directoryMetrics(at: child)
            guard metrics.bytes >= environment.minimumCacheEntryBytes else { continue }
            let isOrphan = !isInstalledAppBundleID(baseID, environment: environment)
            let label = readableEntryTitle(from: rawName, stripSuffix: ".savedState")
            candidates.append(
                CleanCandidate(
                    url: child,
                    category: .leftoversAndInstallers,
                    title: isOrphan ? "残留状态 · \(label)" : "窗口状态 · \(label)",
                    subtitle: "~/Library/Saved Application State/\(rawName)",
                    sizeBytes: metrics.bytes,
                    safetyTier: .safe,
                    lastModified: metrics.lastModified
                )
            )
        }

        // 4B. Orphaned reverse-DNS directories in Application Support & HTTPStorages
        let orphanRoots: [(relPath: String, label: String, tier: CleanSafetyTier)] = [
            ("Library/HTTPStorages", "HTTP 残留", .safe),
            ("Library/Application Support", "卸载残留", .checkFirst)
        ]

        for rootSpec in orphanRoots {
            let rootURL = home.appending(path: rootSpec.relPath, directoryHint: .isDirectory)
            for child in immediateChildren(of: rootURL) where !isSymbolicLink(child) {
                let rawName = child.lastPathComponent
                let lower = rawName.lowercased()
                guard looksLikeReverseDNSBundleID(lower) else { continue }
                guard !isProtectedOrRunningAppEntry(lower, environment: environment) else { continue }
                guard !isInstalledAppBundleID(lower, environment: environment) else { continue }

                let metrics = directoryMetrics(at: child)
                guard metrics.bytes >= environment.minimumCacheEntryBytes else { continue }
                let label = readableEntryTitle(from: rawName, stripSuffix: nil)
                candidates.append(
                    CleanCandidate(
                        url: child,
                        category: .leftoversAndInstallers,
                        title: "\(rootSpec.label) · \(label)",
                        subtitle: "~/\(rootSpec.relPath)/\(rawName)",
                        sizeBytes: metrics.bytes,
                        safetyTier: rootSpec.tier,
                        lastModified: metrics.lastModified
                    )
                )
            }
        }

        // 4C. Leftover Installers & Large Archives in ~/Downloads
        let downloadsURL = home.appending(path: "Downloads", directoryHint: .isDirectory)
        for item in immediateChildren(of: downloadsURL) where !isSymbolicLink(item) {
            let fileName = item.lastPathComponent
            let lowerName = fileName.lowercased()
            let ext = item.pathExtension.lowercased()
            let isTarGz = lowerName.hasSuffix(".tar.gz")
            guard installerExtensions.contains(ext) || isTarGz else { continue }
            let metrics = directoryMetrics(at: item)
            guard metrics.bytes >= environment.minimumInstallerBytes else { continue }
            if let modified = metrics.lastModified, modified > staleCutoff {
                continue
            }
            candidates.append(
                CleanCandidate(
                    url: item,
                    category: .leftoversAndInstallers,
                    title: fileName,
                    subtitle: "~/Downloads/\(fileName)",
                    sizeBytes: metrics.bytes,
                    safetyTier: .checkFirst,
                    lastModified: metrics.lastModified
                )
            )
        }

        return candidates
    }

    // MARK: - Helpers

    nonisolated private static func allowlistedRootPaths(for category: CleanCategory, home: URL) -> [String] {
        let rels: [String]
        switch category {
        case .appCaches:
            rels = [
                "Library/Caches",
                "Library/Logs",
                "Library/DiagnosticReports",
                "Library/Application Support/CrashReporter"
            ]
        case .devCaches:
            rels = [
                "Library/Developer/Xcode/DerivedData",
                "Library/Developer/CoreSimulator/Caches",
                "Library/Developer/Xcode/iOS DeviceSupport",
                "Library/Developer/Xcode/watchOS DeviceSupport",
                "Library/Developer/Xcode/tvOS DeviceSupport",
                "Library/Developer/Xcode/Archives",
                "Library/Caches",
                ".npm",
                ".local/share/pnpm",
                ".bun/install",
                ".cargo/registry",
                ".cargo/git",
                ".gradle",
                ".m2",
                ".cache/huggingface"
            ]
        case .staleArtifacts:
            rels = [
                "Documents/GitHub",
                "Developer",
                "Projects",
                "Code",
                "Work"
            ]
        case .leftoversAndInstallers:
            rels = [
                "Library/Saved Application State",
                "Library/HTTPStorages",
                "Library/Application Support",
                "Downloads"
            ]
        }
        return rels.map {
            canonicalPath(home.appending(path: $0, directoryHint: .isDirectory))
        }
    }

    nonisolated private static func looksLikeReverseDNSBundleID(_ lower: String) -> Bool {
        let parts = lower.split(separator: ".")
        guard parts.count >= 3, let first = parts.first else { return false }
        let validTLDs: Set<Substring> = ["com", "org", "net", "io", "dev", "me", "app", "co", "ai", " cc"]
        return validTLDs.contains(first) && !lower.hasPrefix("com.apple.")
    }

    nonisolated static func isInstalledAppBundleID(_ lower: String, environment: CleanEnvironment) -> Bool {
        if environment.installedBundleIDs.contains(lower) {
            return true
        }
        for installedID in environment.installedBundleIDs {
            if lower.hasPrefix(installedID + ".") || installedID.hasPrefix(lower + ".") {
                return true
            }
        }
        for token in environment.installedProductTokens {
            if lower == token || lower.contains("." + token) {
                return true
            }
        }
        return false
    }

    nonisolated static func isProtectedOrRunningAppEntry(_ rawName: String, environment: CleanEnvironment) -> Bool {
        let lower = rawName.lowercased()
        if protectedCacheEntryNames.contains(lower) || lower.hasPrefix("com.apple.") {
            return true
        }
        for runningID in environment.runningBundleIDs {
            if lower == runningID
                || lower.hasPrefix(runningID + ".")
                || runningID.hasPrefix(lower + ".") {
                return true
            }
        }
        for procName in environment.runningProcessNames where !procName.isEmpty {
            if lower == procName {
                return true
            }
        }
        for token in environment.runningProductTokens {
            if lower == token || lower.hasPrefix(token) {
                return true
            }
        }
        return false
    }

    nonisolated private static func readableEntryTitle(from rawName: String, stripSuffix: String?) -> String {
        var cleaned = rawName
        if let suffix = stripSuffix, cleaned.lowercased().hasSuffix(suffix.lowercased()) {
            cleaned = String(cleaned.dropLast(suffix.count))
        }
        let segments = cleaned.split(separator: ".").map(String.init)
        if segments.count >= 3 {
            let genericTail: Set<String> = ["client", "desktop", "app", "mac", "macos", "helper", "shipit"]
            let last = segments[segments.count - 1]
            let prev = segments[segments.count - 2]
            if genericTail.contains(last.lowercased()), prev.count >= 2 {
                return "\( capitalizedProductName(prev) ) (\(cleaned))"
            }
            if last.count >= 3 {
                return capitalizedProductName(last)
            }
        }
        return cleaned
    }

    nonisolated private static func capitalizedProductName(_ raw: String) -> String {
        guard let first = raw.first else { return raw }
        if raw.contains(where: { $0.isUppercase }) {
            return raw
        }
        return String(first).uppercased() + raw.dropFirst()
    }

    nonisolated private static func isRustOrMavenProject(_ projectDir: URL) -> Bool {
        let fm = FileManager.default
        let cargo = projectDir.appending(path: "Cargo.toml").path(percentEncoded: false)
        let pom = projectDir.appending(path: "pom.xml").path(percentEncoded: false)
        return fm.fileExists(atPath: cargo) || fm.fileExists(atPath: pom)
    }

    nonisolated private static func latestRepositoryActivityDate(in repoRoot: URL, children: [URL]) -> Date? {
        var latest = modificationDate(of: repoRoot)
        for gitProbe in [".git/index", ".git/HEAD", ".git/FETCH_HEAD", ".git/ORIG_HEAD"] {
            let url = repoRoot.appending(path: gitProbe)
            if let d = modificationDate(of: url), d > (latest ?? .distantPast) {
                latest = d
            }
        }
        for child in children {
            let name = child.lastPathComponent
            if name == ".git" || projectArtifactNames.contains(name) { continue }
            if let d = modificationDate(of: child), d > (latest ?? .distantPast) {
                latest = d
            }
        }
        return latest
    }

    nonisolated private static func latestProjectActivityDate(in projectDir: URL, artifactURL: URL) -> Date? {
        var latest = modificationDate(of: projectDir)
        let gitIndex = projectDir.appending(path: ".git/index")
        if let gitDate = modificationDate(of: gitIndex), gitDate > (latest ?? .distantPast) {
            latest = gitDate
        }
        let gitHead = projectDir.appending(path: ".git/HEAD")
        if let headDate = modificationDate(of: gitHead), headDate > (latest ?? .distantPast) {
            latest = headDate
        }
        if let artifactDate = modificationDate(of: artifactURL), artifactDate > (latest ?? .distantPast) {
            latest = artifactDate
        }
        for child in immediateChildren(of: projectDir, includeHidden: false) {
            guard child.standardizedFileURL != artifactURL.standardizedFileURL else { continue }
            if let childDate = modificationDate(of: child), childDate > (latest ?? .distantPast) {
                latest = childDate
            }
        }
        return latest
    }

    nonisolated private static func immediateChildren(of directory: URL, includeHidden: Bool = false) -> [URL] {
        var options: FileManager.DirectoryEnumerationOptions = [.skipsSubdirectoryDescendants, .skipsPackageDescendants]
        if !includeHidden {
            options.insert(.skipsHiddenFiles)
        }
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey, .contentModificationDateKey]
        return (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: options
        )) ?? []
    }

    nonisolated static func isSymbolicLink(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]) else {
            return false
        }
        return values.isSymbolicLink == true
    }

    nonisolated private static func isDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isSymbolicLink != true else {
            return false
        }
        return values.isDirectory == true
    }

    nonisolated private static func modificationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// Computes physical allocated bytes (with hard-link inode deduplication) without traversing into symbolic links.
    /// Uses POSIX `fts_open(FTS_PHYSICAL | FTS_NOCHDIR)` rather than `NSDirectoryEnumerator.skipDescendants()`,
    /// because calling `skipDescendants()` on a leaf symlink inside `node_modules/.bin` aborts enumeration of the parent directory.
    nonisolated static func directoryMetrics(at rootURL: URL) -> (bytes: UInt64, lastModified: Date?) {
        let path = canonicalPath(rootURL)
        var rootStat = stat()
        guard lstat(path, &rootStat) == 0 else { return (0, nil) }
        let mode = rootStat.st_mode & S_IFMT
        if mode == S_IFLNK {
            return (0, nil)
        }

        let rootMTime = Date(
            timeIntervalSince1970: Double(rootStat.st_mtimespec.tv_sec)
                + Double(rootStat.st_mtimespec.tv_nsec) / 1_000_000_000
        )
        if mode == S_IFREG {
            let blocks = UInt64(max(rootStat.st_blocks, 0)) &* 512
            let size = blocks > 0 ? blocks : UInt64(max(rootStat.st_size, 0))
            return (size, rootMTime)
        }
        guard mode == S_IFDIR else {
            return (0, rootMTime)
        }

        guard let cPath = strdup(path) else {
            return (0, rootMTime)
        }
        defer { free(cPath) }

        var paths: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
            return (0, rootMTime)
        }
        defer { fts_close(fts) }

        var totalBytes: UInt64 = 0
        var maxSec = rootStat.st_mtimespec.tv_sec
        var seenHardlinkInodes = Set<UInt64>()

        while let entry = fts_read(fts) {
            let info = Int32(entry.pointee.fts_info)
            guard info == FTS_F || info == FTS_D else { continue }
            guard let st = entry.pointee.fts_statp else { continue }
            if st.pointee.st_mtimespec.tv_sec > maxSec {
                maxSec = st.pointee.st_mtimespec.tv_sec
            }
            if info == FTS_F {
                if st.pointee.st_nlink > 1 {
                    if !seenHardlinkInodes.insert(st.pointee.st_ino).inserted {
                        continue
                    }
                }
                let blocks = UInt64(max(st.pointee.st_blocks, 0)) &* 512
                let size = blocks > 0 ? blocks : UInt64(max(st.pointee.st_size, 0))
                totalBytes &+= size
            }
        }

        return (totalBytes, Date(timeIntervalSince1970: Double(maxSec)))
    }
}
