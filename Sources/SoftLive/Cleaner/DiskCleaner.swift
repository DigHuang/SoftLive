import AppKit
import Foundation
import Observation

/// On-demand disk space, cache cleanup, and application uninstaller coordinator.
/// Runs zero background timers or file watchers; scans only when triggered by the user in Control Center.
@Observable
final class DiskCleaner {
    var mode: CleanerMode = .junkClean

    // MARK: - Junk & Cache Clean State

    private(set) var diskSpace: DiskSpaceSummary
    private(set) var isScanning = false
    private(set) var isCleaning = false
    private(set) var candidates: [CleanCandidate] = []
    private(set) var selectedIDs: Set<String> = []
    private(set) var lastScanDate: Date?
    private(set) var lastReport: CleanSummaryReport?

    // MARK: - App Uninstaller State

    private(set) var isScanningApps = false
    private(set) var isInspectingDrop = false
    private(set) var installedApps: [InstalledAppTarget] = []
    private(set) var runningBundleIDs: Set<String> = []
    private(set) var selectedAppID: String?
    private(set) var selectedResidualIDs: Set<String> = []
    private(set) var lastAppScanDate: Date?
    private(set) var lastUninstallReport: CleanSummaryReport?
    private(set) var dropErrorMessage: String?

    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var scanCancelToken: CleanCancellationToken?
    @ObservationIgnored private var scanGeneration: UInt64 = 0
    @ObservationIgnored private var appScanTask: Task<Void, Never>?
    @ObservationIgnored private var appScanCancelToken: CleanCancellationToken?
    @ObservationIgnored private var appScanGeneration: UInt64 = 0
    @ObservationIgnored private var dropInspectTask: Task<Void, Never>?
    @ObservationIgnored private var trashTask: Task<Void, Never>?
    @ObservationIgnored private var droppedAppTargets: [String: InstalledAppTarget] = [:]
    @ObservationIgnored private var appIconCache: [String: NSImage] = [:]

    init(preferences: Preferences) {
        self.preferences = preferences
        self.diskSpace = DiskSpaceSummary.current()
        if let rawMode = ProcessInfo.processInfo.environment["SOFTLIVE_INITIAL_CLEANER_MODE"],
           let initialMode = CleanerMode(rawValue: rawMode) {
            self.mode = initialMode
        }
        refreshRunningApps()
    }

    isolated deinit {
        scanCancelToken?.cancel()
        scanTask?.cancel()
        appScanCancelToken?.cancel()
        appScanTask?.cancel()
        dropInspectTask?.cancel()
        trashTask?.cancel()
    }

    // MARK: - Junk & Cache Derived Metrics

    var totalScanBytes: UInt64 {
        candidates.reduce(0) { $0 &+ $1.sizeBytes }
    }

    var selectedBytes: UInt64 {
        candidates.reduce(0) { sum, item in
            selectedIDs.contains(item.id) ? (sum &+ item.sizeBytes) : sum
        }
    }

    var selectedCount: Int {
        candidates.reduce(0) { count, item in
            selectedIDs.contains(item.id) ? (count + 1) : count
        }
    }

    func candidates(for category: CleanCategory) -> [CleanCandidate] {
        candidates.filter { $0.category == category }
    }

    func categoryBytes(_ category: CleanCategory) -> UInt64 {
        candidates.reduce(0) { sum, item in
            item.category == category ? (sum &+ item.sizeBytes) : sum
        }
    }

    func selectedCategoryBytes(_ category: CleanCategory) -> UInt64 {
        candidates.reduce(0) { sum, item in
            (item.category == category && selectedIDs.contains(item.id)) ? (sum &+ item.sizeBytes) : sum
        }
    }

    func categoryCandidateCount(_ category: CleanCategory) -> Int {
        candidates.reduce(0) { count, item in
            item.category == category ? (count + 1) : count
        }
    }

    func selectedCategoryCandidateCount(_ category: CleanCategory) -> Int {
        candidates.reduce(0) { count, item in
            (item.category == category && selectedIDs.contains(item.id)) ? (count + 1) : count
        }
    }

    func isCategorySelected(_ category: CleanCategory) -> Bool {
        let items = candidates(for: category)
        guard !items.isEmpty else { return false }
        return items.contains { selectedIDs.contains($0.id) }
    }

    // MARK: - Junk Selection Controls

    func toggleCategory(_ category: CleanCategory) {
        let items = candidates(for: category)
        guard !items.isEmpty else { return }
        lastReport = nil
        let anySelected = items.contains { selectedIDs.contains($0.id) }
        if anySelected {
            for item in items {
                selectedIDs.remove(item.id)
            }
        } else {
            let safeItems = items.filter { $0.safetyTier == .safe }
            let targets = safeItems.isEmpty ? items : safeItems
            for item in targets {
                selectedIDs.insert(item.id)
            }
        }
    }

    func toggleCandidate(_ id: String) {
        lastReport = nil
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    func selectSafeDefaults() {
        lastReport = nil
        selectedIDs = Set(
            candidates
                .filter { $0.safetyTier.defaultSelected }
                .map(\.id)
        )
    }

    func deselectAll() {
        lastReport = nil
        selectedIDs.removeAll()
    }

    // MARK: - App Uninstaller Derived Metrics & Controls

    var totalInstalledAppsBytes: UInt64 {
        installedApps.reduce(0) { $0 &+ $1.totalSizeBytes }
    }

    var selectedApp: InstalledAppTarget? {
        guard let selectedAppID else { return installedApps.first }
        return installedApps.first { $0.id == selectedAppID } ?? installedApps.first
    }

    var selectedAppBytes: UInt64 {
        guard let app = selectedApp else { return 0 }
        return app.residuals.reduce(0) { sum, item in
            selectedResidualIDs.contains(item.id) ? (sum &+ item.sizeBytes) : sum
        }
    }

    var selectedAppItemCount: Int {
        guard let app = selectedApp else { return 0 }
        return app.residuals.reduce(0) { count, item in
            selectedResidualIDs.contains(item.id) ? (count + 1) : count
        }
    }

    /// Returns `true` when the `.app` bundle itself is checked (full uninstall),
    /// or `false` when only `~/Library` residuals are checked (app data reset).
    var isSelectedAppBundleChecked: Bool {
        guard let app = selectedApp,
              let bundleItem = app.residuals.first(where: { $0.kind == .appBundle }) else {
            return false
        }
        return selectedResidualIDs.contains(bundleItem.id)
    }

    func selectApp(_ id: String) {
        guard let app = installedApps.first(where: { $0.id == id }) else { return }
        selectedAppID = app.id
        selectedResidualIDs = Set(
            app.residuals
                .filter { $0.safetyTier.defaultSelected }
                .map(\.id)
        )
        lastUninstallReport = nil
    }

    func toggleResidual(_ id: String) {
        lastUninstallReport = nil
        if selectedResidualIDs.contains(id) {
            selectedResidualIDs.remove(id)
        } else {
            selectedResidualIDs.insert(id)
        }
    }

    func selectAllSafeAppResiduals() {
        guard let app = selectedApp else { return }
        lastUninstallReport = nil
        selectedResidualIDs = Set(
            app.residuals
                .filter { $0.safetyTier.defaultSelected }
                .map(\.id)
        )
    }

    /// Unchecks the `.app` bundle itself and selects only `~/Library` safe residuals ("重置应用数据 / Reset App Data").
    func selectAppResidualsOnly() {
        guard let app = selectedApp else { return }
        lastUninstallReport = nil
        selectedResidualIDs = Set(
            app.residuals
                .filter { $0.kind != .appBundle && $0.safetyTier.defaultSelected }
                .map(\.id)
        )
    }

    func deselectAllAppResiduals() {
        lastUninstallReport = nil
        selectedResidualIDs.removeAll()
    }

    func refreshRunningApps() {
        let updated = Set(
            NSWorkspace.shared.runningApplications
                .compactMap { $0.bundleIdentifier?.lowercased() }
        )
        if runningBundleIDs != updated {
            runningBundleIDs = updated
        }
    }

    func clearDropError() {
        dropErrorMessage = nil
    }

    func isAppRunning(_ app: InstalledAppTarget) -> Bool {
        runningBundleIDs.contains(app.bundleID.lowercased())
    }

    func icon(for app: InstalledAppTarget) -> NSImage {
        if let cached = appIconCache[app.id] {
            return cached
        }
        let img = NSWorkspace.shared.icon(forFile: app.bundleURL.path(percentEncoded: false))
        appIconCache[app.id] = img
        return img
    }

    // MARK: - Junk Scanning & Trashing

    func refreshDiskSpace() {
        diskSpace = DiskSpaceSummary.current()
    }

    /// Starts an asynchronous allowlist scan on a background thread.
    func scan() {
        scanCancelToken?.cancel()
        scanTask?.cancel()
        scanTask = nil
        scanGeneration &+= 1
        let currentGen = scanGeneration
        let cancelToken = CleanCancellationToken()
        scanCancelToken = cancelToken

        isScanning = true
        lastReport = nil

        let staleDays = preferences.cleanStaleThreshold.rawValue
        let runningSnapshot = RunningAppsSnapshot.current()
        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            let space = DiskSpaceSummary.current()
            guard !cancelToken.isCancelled else { return }
            let environment = CleanEnvironment(
                staleDays: staleDays,
                runningSnapshot: runningSnapshot
            )
            let discovered = CleanRuleEngine.scan(environment: environment, cancelToken: cancelToken)
            guard !cancelToken.isCancelled else { return }
            await MainActor.run {
                guard let self, self.scanGeneration == currentGen, !cancelToken.isCancelled else { return }
                self.scanTask = nil
                self.scanCancelToken = nil
                self.diskSpace = space
                self.applyScanResults(discovered)
            }
        }
    }

    /// Synchronous scan entry point for deterministic unit tests.
    func performSynchronousScan(environment: CleanEnvironment? = nil) {
        scanCancelToken?.cancel()
        scanCancelToken = nil
        scanTask?.cancel()
        scanTask = nil
        scanGeneration &+= 1
        lastReport = nil
        let env = environment ?? CleanEnvironment(
            staleDays: preferences.cleanStaleThreshold.rawValue,
            runningSnapshot: RunningAppsSnapshot.current()
        )
        let discovered = CleanRuleEngine.scan(environment: env)
        applyScanResults(discovered)
    }

    private func applyScanResults(_ discovered: [CleanCandidate]) {
        candidates = discovered
        selectedIDs = Set(
            discovered
                .filter { $0.safetyTier.defaultSelected }
                .map(\.id)
        )
        lastScanDate = .now
        isScanning = false
    }

    /// Moves selected junk candidates to the macOS Trash asynchronously off MainActor.
    func trashSelectedAsync() {
        guard !isCleaning, !isScanning else { return }
        let chosen = candidates.filter { selectedIDs.contains($0.id) }
        guard !chosen.isEmpty else { return }

        isCleaning = true
        lastReport = nil
        let staleDays = preferences.cleanStaleThreshold.rawValue
        let runningSnapshot = RunningAppsSnapshot.current()

        trashTask?.cancel()
        trashTask = Task.detached(priority: .userInitiated) { [weak self] in
            let env = CleanEnvironment(
                staleDays: staleDays,
                runningSnapshot: runningSnapshot
            )
            let outcome = Self.performTrashCandidates(chosen, environment: env, trashHandler: nil)
            let space = DiskSpaceSummary.current()
            await MainActor.run {
                guard let self else { return }
                self.trashTask = nil
                self.applyTrashCandidatesOutcome(outcome, diskSpace: space)
                self.isCleaning = false
            }
        }
    }

    /// Moves all currently selected candidates to the macOS Trash after re-verifying safety invariants.
    @discardableResult
    func trashSelected(
        environment: CleanEnvironment? = nil,
        trashHandler: ((URL) throws -> Void)? = nil
    ) -> CleanSummaryReport {
        guard !isCleaning else {
            return CleanSummaryReport(trashedCount: 0, freedBytes: 0, skippedCount: 0, completedAt: .now)
        }
        isCleaning = true
        defer { isCleaning = false }

        let env = environment ?? CleanEnvironment(
            staleDays: preferences.cleanStaleThreshold.rawValue,
            runningSnapshot: RunningAppsSnapshot.current()
        )
        let chosen = candidates.filter { selectedIDs.contains($0.id) }
        let outcome = Self.performTrashCandidates(chosen, environment: env, trashHandler: trashHandler)
        return applyTrashCandidatesOutcome(outcome, diskSpace: DiskSpaceSummary.current())
    }

    nonisolated private static func performTrashCandidates(
        _ chosen: [CleanCandidate],
        environment: CleanEnvironment,
        trashHandler: ((URL) throws -> Void)?
    ) -> (trashedIDs: Set<String>, freedBytes: UInt64, skippedCount: Int) {
        var trashedIDs: Set<String> = []
        var freedBytes: UInt64 = 0
        var skippedCount = 0

        for item in chosen {
            guard CleanRuleEngine.canSafelyTrash(item, environment: environment) else {
                skippedCount += 1
                continue
            }
            do {
                if let trashHandler {
                    try trashHandler(item.url)
                } else {
                    try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
                }
                trashedIDs.insert(item.id)
                freedBytes &+= item.sizeBytes
            } catch {
                skippedCount += 1
            }
        }

        return (trashedIDs, freedBytes, skippedCount)
    }

    @discardableResult
    private func applyTrashCandidatesOutcome(
        _ outcome: (trashedIDs: Set<String>, freedBytes: UInt64, skippedCount: Int),
        diskSpace newSpace: DiskSpaceSummary
    ) -> CleanSummaryReport {
        if !outcome.trashedIDs.isEmpty {
            candidates.removeAll { outcome.trashedIDs.contains($0.id) }
            selectedIDs.subtract(outcome.trashedIDs)
        }
        diskSpace = newSpace

        let report = CleanSummaryReport(
            trashedCount: outcome.trashedIDs.count,
            freedBytes: outcome.freedBytes,
            skippedCount: outcome.skippedCount,
            completedAt: .now
        )
        lastReport = report
        return report
    }

    // MARK: - App Uninstaller Scanning, Drop & Trashing

    func scanApps() {
        appScanCancelToken?.cancel()
        appScanTask?.cancel()
        appScanTask = nil
        appScanGeneration &+= 1
        let currentGen = appScanGeneration
        let cancelToken = CleanCancellationToken()
        appScanCancelToken = cancelToken

        isScanningApps = true
        lastUninstallReport = nil

        appScanTask = Task.detached(priority: .userInitiated) { [weak self] in
            let space = DiskSpaceSummary.current()
            guard !cancelToken.isCancelled else { return }
            let apps = AppUninstallEngine.scanInstalledApps(cancelToken: cancelToken)
            guard !cancelToken.isCancelled else { return }
            await MainActor.run {
                guard let self, self.appScanGeneration == currentGen, !cancelToken.isCancelled else { return }
                self.appScanTask = nil
                self.appScanCancelToken = nil
                self.diskSpace = space
                self.refreshRunningApps()
                self.applyAppScanResults(apps)
            }
        }
    }

    /// Synchronous app scan entry point for deterministic unit tests.
    func performSynchronousAppScan(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationDirectories: [URL]? = nil
    ) {
        appScanCancelToken?.cancel()
        appScanCancelToken = nil
        appScanTask?.cancel()
        appScanTask = nil
        appScanGeneration &+= 1
        lastUninstallReport = nil
        refreshRunningApps()
        let apps = AppUninstallEngine.scanInstalledApps(
            homeDirectory: homeDirectory,
            applicationDirectories: applicationDirectories
        )
        applyAppScanResults(apps)
    }

    private func applyAppScanResults(_ apps: [InstalledAppTarget]) {
        let scannedIDs = Set(apps.map(\.id))
        var merged = apps
        // Preserve valid externally dropped `.app` bundles (e.g. Desktop/Downloads) across scans.
        for (id, dropped) in droppedAppTargets {
            if scannedIDs.contains(id) {
                droppedAppTargets.removeValue(forKey: id)
            } else if FileManager.default.fileExists(atPath: dropped.bundleURL.path(percentEncoded: false)) {
                merged.insert(dropped, at: 0)
            } else {
                droppedAppTargets.removeValue(forKey: id)
            }
        }
        installedApps = merged
        appIconCache = appIconCache.filter { key, _ in merged.contains { $0.id == key } }

        if let currentID = selectedAppID,
           let stillPresent = merged.first(where: { $0.id == currentID }) {
            selectApp(stillPresent.id)
        } else if let first = merged.first {
            selectApp(first.id)
        } else {
            selectedAppID = nil
            selectedResidualIDs.removeAll()
        }
        lastAppScanDate = .now
        isScanningApps = false
    }

    /// Inspects a `.app` bundle dropped from Finder off MainActor and surfaces explicit feedback if rejected.
    func inspectDroppedAppURL(
        _ url: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        dropInspectTask?.cancel()
        dropErrorMessage = nil
        let stdURL = url.standardizedFileURL
        guard stdURL.isFileURL, stdURL.pathExtension.lowercased() == "app" else {
            dropErrorMessage = L10n.tr(
                "仅支持拖入有效的 .app 应用程序包",
                "Only valid .app application bundles can be inspected"
            )
            return
        }

        isInspectingDrop = true
        dropInspectTask = Task.detached(priority: .userInitiated) { [weak self] in
            let target = AppUninstallEngine.inspectApp(at: stdURL, homeDirectory: homeDirectory)
            await MainActor.run {
                guard let self, !Task.isCancelled else { return }
                self.dropInspectTask = nil
                self.isInspectingDrop = false
                guard let target else {
                    self.dropErrorMessage = L10n.tr(
                        "无法移除系统应用、SoftLive 本身或无效安装包",
                        "System apps, SoftLive itself, and invalid bundles are protected"
                    )
                    return
                }
                self.applyDroppedTarget(target)
            }
        }
    }

    /// Synchronous `.app` drop inspection entry point for deterministic unit tests.
    @discardableResult
    func handleDroppedAppURL(
        _ url: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        let stdURL = url.standardizedFileURL
        guard stdURL.isFileURL,
              stdURL.pathExtension.lowercased() == "app",
              let target = AppUninstallEngine.inspectApp(at: stdURL, homeDirectory: homeDirectory) else {
            return false
        }
        applyDroppedTarget(target)
        return true
    }

    private func applyDroppedTarget(_ target: InstalledAppTarget) {
        dropErrorMessage = nil
        refreshRunningApps()
        droppedAppTargets[target.id] = target
        mode = .appUninstall
        if let existingIdx = installedApps.firstIndex(where: { $0.id == target.id }) {
            installedApps[existingIdx] = target
        } else {
            installedApps.insert(target, at: 0)
        }
        selectApp(target.id)
    }

    /// Moves the currently selected items of `selectedApp` to the macOS Trash asynchronously off MainActor.
    func trashSelectedAppItemsAsync(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        allowedApplicationDirectories: [URL]? = nil
    ) {
        guard !isCleaning, !isScanningApps, let app = selectedApp else { return }
        let chosen = Self.orderedResidualsToTrash(app: app, selectedResidualIDs: selectedResidualIDs)
        guard !chosen.isEmpty else { return }

        isCleaning = true
        lastUninstallReport = nil
        let shouldTerminate = isAppRunning(app)
        if shouldTerminate {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID)
            for proc in running {
                _ = proc.terminate()
            }
        }

        trashTask?.cancel()
        trashTask = Task.detached(priority: .userInitiated) { [weak self] in
            if shouldTerminate {
                await Self.waitForAppTermination(bundleID: app.bundleID)
            }
            let outcome = Self.performTrashAppItems(
                chosen,
                app: app,
                homeDirectory: homeDirectory,
                allowedApplicationDirectories: allowedApplicationDirectories,
                trashHandler: nil
            )
            let space = DiskSpaceSummary.current()
            await MainActor.run {
                guard let self else { return }
                self.trashTask = nil
                self.refreshRunningApps()
                self.applyTrashAppItemsOutcome(outcome, app: app, diskSpace: space)
                self.isCleaning = false
            }
        }
    }

    /// Moves the currently selected items of `selectedApp` to the macOS Trash.
    /// If the `.app` bundle is trashed, removes the app from `installedApps`; if only residuals are trashed,
    /// updates the app's remaining residuals in place ("App Data Reset").
    @discardableResult
    func trashSelectedAppItems(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        allowedApplicationDirectories: [URL]? = nil,
        trashHandler: ((URL) throws -> Void)? = nil
    ) -> CleanSummaryReport {
        guard !isCleaning, let app = selectedApp else {
            return CleanSummaryReport(trashedCount: 0, freedBytes: 0, skippedCount: 0, completedAt: .now)
        }
        isCleaning = true
        defer { isCleaning = false }

        // If the app is currently running, ask it to terminate gracefully first when trashing via Finder.
        if trashHandler == nil && isAppRunning(app) {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID)
            for proc in running {
                _ = proc.terminate()
            }
            let deadline = Date.now.addingTimeInterval(2.0)
            while !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty,
                  Date.now < deadline {
                RunLoop.current.run(mode: .default, before: Date.now.addingTimeInterval(0.05))
            }
        }

        let chosen = Self.orderedResidualsToTrash(app: app, selectedResidualIDs: selectedResidualIDs)
        let outcome = Self.performTrashAppItems(
            chosen,
            app: app,
            homeDirectory: homeDirectory,
            allowedApplicationDirectories: allowedApplicationDirectories,
            trashHandler: trashHandler
        )
        refreshRunningApps()
        return applyTrashAppItemsOutcome(outcome, app: app, diskSpace: DiskSpaceSummary.current())
    }

    nonisolated private static func orderedResidualsToTrash(
        app: InstalledAppTarget,
        selectedResidualIDs: Set<String>
    ) -> [AppResidualItem] {
        app.residuals
            .filter { selectedResidualIDs.contains($0.id) }
            .sorted { lhs, rhs in
                if lhs.kind == .appBundle { return false }
                if rhs.kind == .appBundle { return true }
                return lhs.sizeBytes > rhs.sizeBytes
            }
    }

    private static func waitForAppTermination(bundleID: String) async {
        for _ in 0..<20 {
            let stillRunning = await MainActor.run {
                !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
            }
            if !stillRunning {
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    nonisolated private static func performTrashAppItems(
        _ chosen: [AppResidualItem],
        app: InstalledAppTarget,
        homeDirectory: URL,
        allowedApplicationDirectories: [URL]?,
        trashHandler: ((URL) throws -> Void)?
    ) -> (trashedIDs: Set<String>, trashedAppBundle: Bool, freedBytes: UInt64, skippedCount: Int) {
        var trashedIDs: Set<String> = []
        var trashedAppBundle = false
        var freedBytes: UInt64 = 0
        var skippedCount = 0

        for item in chosen {
            guard AppUninstallEngine.canSafelyTrash(
                item,
                app: app,
                homeDirectory: homeDirectory,
                allowedApplicationDirectories: allowedApplicationDirectories,
                allowRunning: trashHandler != nil
            ) else {
                skippedCount += 1
                continue
            }
            do {
                if let trashHandler {
                    try trashHandler(item.url)
                } else {
                    try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
                }
                trashedIDs.insert(item.id)
                freedBytes &+= item.sizeBytes
                if item.kind == .appBundle {
                    trashedAppBundle = true
                }
            } catch {
                skippedCount += 1
            }
        }

        return (trashedIDs, trashedAppBundle, freedBytes, skippedCount)
    }

    @discardableResult
    private func applyTrashAppItemsOutcome(
        _ outcome: (trashedIDs: Set<String>, trashedAppBundle: Bool, freedBytes: UInt64, skippedCount: Int),
        app: InstalledAppTarget,
        diskSpace newSpace: DiskSpaceSummary
    ) -> CleanSummaryReport {
        if outcome.trashedAppBundle {
            droppedAppTargets.removeValue(forKey: app.id)
            appIconCache.removeValue(forKey: app.id)
            installedApps.removeAll { $0.id == app.id }
            if let nextApp = installedApps.first {
                selectApp(nextApp.id)
            } else {
                selectedAppID = nil
                selectedResidualIDs.removeAll()
            }
        } else if !outcome.trashedIDs.isEmpty,
                  let idx = installedApps.firstIndex(where: { $0.id == app.id }) {
            let remaining = app.residuals.filter { !outcome.trashedIDs.contains($0.id) }
            let updated = InstalledAppTarget(
                bundleURL: app.bundleURL,
                bundleID: app.bundleID,
                displayName: app.displayName,
                version: app.version,
                bundleSizeBytes: app.bundleSizeBytes,
                residuals: remaining,
                lastModified: app.lastModified
            )
            installedApps[idx] = updated
            if droppedAppTargets[app.id] != nil {
                droppedAppTargets[app.id] = updated
            }
            selectedResidualIDs.subtract(outcome.trashedIDs)
        }

        diskSpace = newSpace
        let report = CleanSummaryReport(
            trashedCount: outcome.trashedIDs.count,
            freedBytes: outcome.freedBytes,
            skippedCount: outcome.skippedCount,
            completedAt: .now
        )
        lastUninstallReport = report
        return report
    }

    /// Cancels any active scan when the Control Center window closes so background work stops immediately.
    func cancelInFlightScan() {
        if isScanning {
            scanCancelToken?.cancel()
            scanCancelToken = nil
            scanTask?.cancel()
            scanTask = nil
            scanGeneration &+= 1
            isScanning = false
        }
        if isScanningApps {
            appScanCancelToken?.cancel()
            appScanCancelToken = nil
            appScanTask?.cancel()
            appScanTask = nil
            appScanGeneration &+= 1
            isScanningApps = false
        }
        if isInspectingDrop {
            dropInspectTask?.cancel()
            dropInspectTask = nil
            isInspectingDrop = false
        }
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openTrashInFinder() {
        let trashURL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".Trash", directoryHint: .isDirectory)
        NSWorkspace.shared.open(trashURL)
    }

    func copyPath(_ url: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url.path(percentEncoded: false), forType: .string)
    }
}
