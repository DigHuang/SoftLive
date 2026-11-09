import AppKit
import Foundation
import Observation

/// On-demand disk space and cache cleanup coordinator.
/// Runs zero background timers or file watchers; scans only when triggered by the user in Control Center.
@Observable
final class DiskCleaner {
    private(set) var diskSpace: DiskSpaceSummary
    private(set) var isScanning = false
    private(set) var isCleaning = false
    private(set) var candidates: [CleanCandidate] = []
    private(set) var selectedIDs: Set<String> = []
    private(set) var lastScanDate: Date?
    private(set) var lastReport: CleanSummaryReport?

    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var scanGeneration: UInt64 = 0

    init(preferences: Preferences) {
        self.preferences = preferences
        self.diskSpace = DiskSpaceSummary.current()
    }

    isolated deinit {
        scanTask?.cancel()
    }

    // MARK: - Derived Metrics

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

    // MARK: - Selection Controls

    func toggleCategory(_ category: CleanCategory) {
        let items = candidates(for: category)
        guard !items.isEmpty else { return }
        let anySelected = items.contains { selectedIDs.contains($0.id) }
        if anySelected {
            for item in items {
                selectedIDs.remove(item.id)
            }
        } else {
            // Turning a category on selects all safe items first; if the category only has `.checkFirst` items, selects those.
            let safeItems = items.filter { $0.safetyTier == .safe }
            let targets = safeItems.isEmpty ? items : safeItems
            for item in targets {
                selectedIDs.insert(item.id)
            }
        }
    }

    func toggleCandidate(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    func selectSafeDefaults() {
        selectedIDs = Set(
            candidates
                .filter { $0.safetyTier.defaultSelected }
                .map(\.id)
        )
    }

    func deselectAll() {
        selectedIDs.removeAll()
    }

    // MARK: - Scanning & Trashing

    func refreshDiskSpace() {
        diskSpace = DiskSpaceSummary.current()
    }

    /// Starts an asynchronous allowlist scan on a background thread.
    func scan() {
        scanTask?.cancel()
        scanTask = nil
        scanGeneration &+= 1
        let currentGen = scanGeneration

        isScanning = true
        lastReport = nil
        refreshDiskSpace()

        let environment = CleanEnvironment(staleDays: preferences.cleanStaleThreshold.rawValue)
        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            let discovered = CleanRuleEngine.scan(environment: environment)
            await MainActor.run {
                guard let self, self.scanGeneration == currentGen else { return }
                self.scanTask = nil
                self.applyScanResults(discovered)
            }
        }
    }

    /// Synchronous scan entry point for deterministic unit tests.
    func performSynchronousScan(environment: CleanEnvironment? = nil) {
        scanTask?.cancel()
        scanTask = nil
        scanGeneration &+= 1
        lastReport = nil
        let env = environment ?? CleanEnvironment(staleDays: preferences.cleanStaleThreshold.rawValue)
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

        let env = environment ?? CleanEnvironment(staleDays: preferences.cleanStaleThreshold.rawValue)
        let chosen = candidates.filter { selectedIDs.contains($0.id) }

        var trashedIDs: Set<String> = []
        var freedBytes: UInt64 = 0
        var skippedCount = 0

        for item in chosen {
            guard CleanRuleEngine.canSafelyTrash(item, environment: env) else {
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

        if !trashedIDs.isEmpty {
            candidates.removeAll { trashedIDs.contains($0.id) }
            selectedIDs.subtract(trashedIDs)
        }
        refreshDiskSpace()

        let report = CleanSummaryReport(
            trashedCount: trashedIDs.count,
            freedBytes: freedBytes,
            skippedCount: skippedCount,
            completedAt: .now
        )
        lastReport = report
        return report
    }

    /// Cancels any active scan when the Control Center window closes so background work is strictly zero.
    func cancelInFlightScan() {
        guard isScanning else { return }
        scanTask?.cancel()
        scanTask = nil
        scanGeneration &+= 1
        isScanning = false
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
