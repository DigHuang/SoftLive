import AppKit
import Foundation
import SwiftUI
import Testing
@testable import SoftLive

@Suite struct DiskCleanerTests {
    @Test func scansAllowlistedCategoriesSkipsRunningAppsAndAvoidsDoubleCounting() throws {
        let fm = FileManager.default
        let tempHome = fm.temporaryDirectory
            .appending(path: "SoftLiveCleanHome-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: tempHome, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempHome) }

        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let tenDaysAgo = now.addingTimeInterval(-10 * 86_400)
        let twoDaysAgo = now.addingTimeInterval(-2 * 86_400)

        // 1. App Caches:
        // - Inactive app cache (should be found as `.safe`)
        let inactiveCache = tempHome.appending(path: "Library/Caches/com.spotify.client", directoryHint: .isDirectory)
        try writeSizedFile(in: inactiveCache, name: "cache.bin", bytes: 128 * 1024, mtime: twoDaysAgo)

        // - Running app cache (must be skipped, including product-token folders like `LarkShell` for `com.electron.lark`!)
        let runningCache = tempHome.appending(path: "Library/Caches/com.netease.163music", directoryHint: .isDirectory)
        try writeSizedFile(in: runningCache, name: "live.bin", bytes: 256 * 1024, mtime: twoDaysAgo)
        let runningLarkShell = tempHome.appending(path: "Library/Caches/LarkShell", directoryHint: .isDirectory)
        try writeSizedFile(in: runningLarkShell, name: "lark.bin", bytes: 512 * 1024, mtime: twoDaysAgo)

        // - Protected Apple system cache (must be skipped!)
        let appleCache = tempHome.appending(path: "Library/Caches/com.apple.Safari", directoryHint: .isDirectory)
        try writeSizedFile(in: appleCache, name: "safari.bin", bytes: 256 * 1024, mtime: twoDaysAgo)

        // 2. Package Caches inside ~/Library/Caches (must appear in `.packageCaches` ONLY, never duplicated in `.appCaches`)
        let brewCache = tempHome.appending(path: "Library/Caches/Homebrew", directoryHint: .isDirectory)
        try writeSizedFile(in: brewCache, name: "formula. bottle.tar.gz", bytes: 200 * 1024, mtime: twoDaysAgo)

        // 3. Xcode Junk:
        // - DerivedData (`.safe`)
        let derivedData = tempHome.appending(path: "Library/Developer/Xcode/DerivedData/DemoApp-abcdef", directoryHint: .isDirectory)
        try writeSizedFile(in: derivedData, name: "index.db", bytes: 180 * 1024, mtime: twoDaysAgo)

        // - Archives (`.checkFirst`, NOT pre-selected by default)
        let archive = tempHome.appending(path: "Library/Developer/Xcode/Archives/2026-11-01", directoryHint: .isDirectory)
        try writeSizedFile(in: archive, name: "Demo.xcarchive", bytes: 300 * 1024, mtime: tenDaysAgo)

        // 4. Stale vs Active Project Build Artifacts:
        // - Stale project (> 7 days old -> `.safe`), including a leaf symlink inside `node_modules/.bin`
        //   to verify `fts_open(FTS_PHYSICAL)` does not abort parent enumeration when encountering symlinks.
        let staleProject = tempHome.appending(path: "Documents/GitHub/OldRepo", directoryHint: .isDirectory)
        let staleNodeModules = staleProject.appending(path: "node_modules", directoryHint: .isDirectory)
        let binDir = staleNodeModules.appending(path: ".bin", directoryHint: .isDirectory)
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        let pkgDir = staleNodeModules.appending(path: ".bun/pkg", directoryHint: .isDirectory)
        try writeSizedFile(in: pkgDir, name: "index.js", bytes: 150 * 1024, mtime: tenDaysAgo)
        try fm.createSymbolicLink(
            at: binDir.appending(path: "cli"),
            withDestinationURL: pkgDir.appending(path: "index.js")
        )
        try setMTime(binDir, tenDaysAgo)
        try setMTime(staleNodeModules, tenDaysAgo)
        try setMTime(staleProject, tenDaysAgo)

        // - Active project (2 days old -> must be skipped!)
        let activeProject = tempHome.appending(path: "Documents/GitHub/ActiveRepo", directoryHint: .isDirectory)
        let activeNodeModules = activeProject.appending(path: "node_modules", directoryHint: .isDirectory)
        try writeSizedFile(in: activeNodeModules, name: "bundle.js", bytes: 150 * 1024, mtime: twoDaysAgo)
        try setMTime(activeProject, twoDaysAgo)

        // - Leftover DMG installer in ~/Downloads (> 7 days old -> `.checkFirst`)
        let downloadsDir = tempHome.appending(path: "Downloads", directoryHint: .isDirectory)
        try fm.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        let oldDMG = downloadsDir.appending(path: "InstallerOld.dmg")
        try Data(repeating: 0xAA, count: 256 * 1024).write(to: oldDMG)
        try setMTime(oldDMG, tenDaysAgo)

        // - Orphaned app support folder (not in `installedBundleIDs` -> `.checkFirst` under `.leftoversAndInstallers`)
        let orphanSupport = tempHome.appending(path: "Library/Application Support/com.deleted.oldapp", directoryHint: .isDirectory)
        try writeSizedFile(in: orphanSupport, name: "state.db", bytes: 128 * 1024, mtime: tenDaysAgo)

        // - Installed app support folder (in `installedBundleIDs` -> must NOT be flagged as orphan!)
        let installedSupport = tempHome.appending(path: "Library/Application Support/com.spotify.client", directoryHint: .isDirectory)
        try writeSizedFile(in: installedSupport, name: "prefs.db", bytes: 128 * 1024, mtime: tenDaysAgo)

        let env = CleanEnvironment(
            homeDirectory: tempHome,
            runningBundleIDs: ["com.netease.163music", "com.electron.lark", "dev.softlive.softlive"],
            runningProcessNames: ["NetEaseMusic", "Feishu", "Lark Helper"],
            installedBundleIDs: ["com.spotify.client"],
            excludedPaths: [],
            staleDays: 7,
            minimumCacheEntryBytes: 1024,
            minimumInstallerBytes: 64 * 1024,
            now: now
        )

        let suiteName = "SoftLiveCleanTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = Preferences(defaults: defaults)
        let cleaner = DiskCleaner(preferences: preferences)

        cleaner.performSynchronousScan(environment: env)

        // Verify discovered items
        let titles = Set(cleaner.candidates.map(\.title))
        #expect(titles.contains("Spotify (com.spotify.client)"))
        #expect(!titles.contains(where: { $0.contains("163music") }))
        #expect(!titles.contains(where: { $0.contains("LarkShell") }))
        #expect(!titles.contains(where: { $0.contains("Safari") }))
        #expect(titles.contains("Homebrew Cache"))
        #expect(titles.contains("DerivedData · DemoApp"))
        #expect(titles.contains("Xcode Archive · 2026-11-01"))
        #expect(titles.contains("OldRepo · node_modules"))
        #expect(!titles.contains("ActiveRepo · node_modules"))
        #expect(titles.contains("InstallerOld.dmg"))
        #expect(titles.contains("卸载残留 · Oldapp"))
        #expect(!titles.contains(where: { $0.contains("卸载残留") && $0.contains("Spotify") }))

        // Homebrew must only appear under `.devCaches`, never duplicated in `.appCaches`
        let appCacheItems = cleaner.candidates(for: .appCaches)
        #expect(appCacheItems.count == 1)
        let devItems = cleaner.candidates(for: .devCaches)
        #expect(devItems.count == 3)
        let leftoverItems = cleaner.candidates(for: .leftoversAndInstallers)
        #expect(leftoverItems.count == 2)

        // Default selection must include `.safe` items and exclude `.checkFirst` items (`Archive` and `InstallerOld.dmg`)
        for candidate in cleaner.candidates {
            if candidate.safetyTier == .safe {
                #expect(cleaner.selectedIDs.contains(candidate.id))
            } else {
                #expect(!cleaner.selectedIDs.contains(candidate.id))
            }
        }
    }

    @Test func skipsSymbolicLinksAndBlocksTOCTOURunningAppOrSymlinkTrashing() throws {
        let fm = FileManager.default
        let tempHome = fm.temporaryDirectory
            .appending(path: "SoftLiveSymlinkClean-\(UUID().uuidString)", directoryHint: .isDirectory)
        let outsideDir = fm.temporaryDirectory
            .appending(path: "SoftLiveOutsideTarget-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: tempHome, withIntermediateDirectories: true)
        try fm.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: tempHome)
            try? fm.removeItem(at: outsideDir)
        }

        let outsideImportantFile = outsideDir.appending(path: "important.txt")
        try Data(repeating: 0x42, count: 64 * 1024).write(to: outsideImportantFile)

        let cachesDir = tempHome.appending(path: "Library/Caches", directoryHint: .isDirectory)
        try fm.createDirectory(at: cachesDir, withIntermediateDirectories: true)

        // Create a symlink inside ~/Library/Caches pointing to `outsideDir`
        let symlinkCache = cachesDir.appending(path: "com.evil.symlink")
        try fm.createSymbolicLink(at: symlinkCache, withDestinationURL: outsideDir)

        // Create a valid cache directory
        let validCache = cachesDir.appending(path: "com.acme.tool", directoryHint: .isDirectory)
        try writeSizedFile(in: validCache, name: "blob.dat", bytes: 64 * 1024, mtime: .now)

        let env = CleanEnvironment(
            homeDirectory: tempHome,
            runningBundleIDs: [],
            runningProcessNames: [],
            excludedPaths: [],
            staleDays: 7,
            minimumCacheEntryBytes: 1024,
            minimumInstallerBytes: 1024
        )

        let discovered = CleanRuleEngine.scan(environment: env)
        #expect(discovered.count == 1)
        #expect(discovered.first?.url == validCache.standardizedFileURL)

        // Even if a symlink candidate were constructed manually, `canSafelyTrash` must reject it.
        let forgedSymlinkCandidate = CleanCandidate(
            url: symlinkCache,
            category: .appCaches,
            title: "Forged",
            subtitle: "~/Library/Caches/com.evil.symlink",
            sizeBytes: 64 * 1024,
            safetyTier: .safe
        )
        #expect(!CleanRuleEngine.canSafelyTrash(forgedSymlinkCandidate, environment: env))

        // If `com.acme.tool` launches before `trashSelected` runs, `canSafelyTrash` must skip it!
        let envAfterLaunch = CleanEnvironment(
            homeDirectory: tempHome,
            runningBundleIDs: ["com.acme.tool"],
            runningProcessNames: [],
            excludedPaths: [],
            staleDays: 7,
            minimumCacheEntryBytes: 1024,
            minimumInstallerBytes: 1024
        )

        let suiteName = "SoftLiveTOCTOU.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cleaner = DiskCleaner(preferences: Preferences(defaults: defaults))
        cleaner.performSynchronousScan(environment: env)
        #expect(cleaner.selectedCount == 1)

        var trashedURLs: [URL] = []
        let blockedReport = cleaner.trashSelected(environment: envAfterLaunch) { url in
            trashedURLs.append(url)
        }
        #expect(blockedReport.trashedCount == 0)
        #expect(blockedReport.skippedCount == 1)
        #expect(trashedURLs.isEmpty)

        // Once the app quits (`env`), trashing succeeds and removes the candidate from the list.
        let okReport = cleaner.trashSelected(environment: env) { url in
            trashedURLs.append(url)
            try fm.removeItem(at: url)
        }
        #expect(okReport.trashedCount == 1)
        #expect(okReport.skippedCount == 0)
        #expect(okReport.freedBytes >= 64 * 1024)
        #expect(cleaner.candidates.isEmpty)
        #expect(fm.fileExists(atPath: outsideImportantFile.path(percentEncoded: false)))
    }

    @Test func rendersCleanerPaneInIdleAndScannedStatesAcrossLanguages() throws {
        let fm = FileManager.default
        let tempHome = fm.temporaryDirectory
            .appending(path: "SoftLiveCleanerRender-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: tempHome, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: tempHome)
            L10n.language = .system
        }

        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let oldDate = now.addingTimeInterval(-12 * 86_400)
        try writeSizedFile(
            in: tempHome.appending(path: "Library/Caches/com.spotify.client", directoryHint: .isDirectory),
            name: "audio.cache",
            bytes: 256 * 1024,
            mtime: oldDate
        )
        try writeSizedFile(
            in: tempHome.appending(path: "Library/Developer/Xcode/DerivedData/SoftLive-abcd", directoryHint: .isDirectory),
            name: "build.db",
            bytes: 512 * 1024,
            mtime: oldDate
        )
        try writeSizedFile(
            in: tempHome.appending(path: "Library/Developer/Xcode/Archives/2026-11-01", directoryHint: .isDirectory),
            name: "App.xcarchive",
            bytes: 384 * 1024,
            mtime: oldDate
        )
        try writeSizedFile(
            in: tempHome.appending(path: "Library/Caches/Homebrew", directoryHint: .isDirectory),
            name: "pkg.tar.gz",
            bytes: 192 * 1024,
            mtime: oldDate
        )
        let staleProj = tempHome.appending(path: "Documents/GitHub/FastGPT-Workspace", directoryHint: .isDirectory)
        try writeSizedFile(
            in: staleProj.appending(path: "node_modules", directoryHint: .isDirectory),
            name: "vendor.js",
            bytes: 640 * 1024,
            mtime: oldDate
        )
        try setMTime(staleProj, oldDate)

        let suiteName = "SoftLiveCleanerRenderSuite.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = Preferences(defaults: defaults)
        let model = PlaybackModel(sources: [])
        let monitor = SystemMonitor(preferences: preferences)
        let cleaner = DiskCleaner(preferences: preferences)
        let state = ControlCenterState()
        state.isOpen = true
        state.selectedSection = .cleaner

        let env = CleanEnvironment(
            homeDirectory: tempHome,
            runningBundleIDs: [],
            runningProcessNames: [],
            installedBundleIDs: ["com.spotify.client"],
            excludedPaths: [],
            staleDays: 7,
            minimumCacheEntryBytes: 1024,
            minimumInstallerBytes: 1024,
            now: now
        )

        // Render idle state (Chinese) at minimum window size (680 x 636) to guarantee zero clipping
        preferences.language = .zhHans
        try assertCleanerPaneRenders(
            model: model,
            monitor: monitor,
            cleaner: cleaner,
            preferences: preferences,
            state: state,
            size: ControlCenterWindow.minWindowSize
        )

        // Scan and render populated state (Chinese & English, default & resized)
        cleaner.performSynchronousScan(environment: env)
        #expect(cleaner.candidates.count == 5)
        #expect(cleaner.selectedCount == 4)

        try assertCleanerPaneRenders(
            model: model,
            monitor: monitor,
            cleaner: cleaner,
            preferences: preferences,
            state: state,
            size: ControlCenterWindow.defaultSize
        )

        preferences.language = .en
        try assertCleanerPaneRenders(
            model: model,
            monitor: monitor,
            cleaner: cleaner,
            preferences: preferences,
            state: state,
            size: NSSize(width: 900, height: 760)
        )

        // Verify ControlCenterWindow strictly preserves its minimum size even after NSHostingView layout passes.
        let ccWindow = ControlCenterWindow(
            model: model,
            monitor: monitor,
            cleaner: cleaner,
            preferences: preferences
        )
        ccWindow.contentView?.layoutSubtreeIfNeeded()
        #expect(ccWindow.minSize == ControlCenterWindow.minWindowSize)
        #expect(ccWindow.contentMinSize == ControlCenterWindow.minWindowSize)
        let clamped = ccWindow.windowWillResize(ccWindow, to: NSSize(width: 400, height: 300))
        #expect(clamped == ControlCenterWindow.minWindowSize)
    }

    private func assertCleanerPaneRenders(
        model: PlaybackModel,
        monitor: SystemMonitor,
        cleaner: DiskCleaner,
        preferences: Preferences,
        state: ControlCenterState,
        size: NSSize = ControlCenterWindow.defaultSize
    ) throws {
        state.windowSize = size
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        let host = NSHostingView(
            rootView: ControlCenterView(
                model: model,
                monitor: monitor,
                cleaner: cleaner,
                preferences: preferences,
                state: state
            )
        )
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        #expect(rep.pixelsWide >= Int(size.width))
        #expect(rep.pixelsHigh >= Int(size.height))
    }

    // MARK: - Test Helpers

    private func writeSizedFile(in directory: URL, name: String, bytes: Int, mtime: Date) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appending(path: name)
        try Data(repeating: 0x5A, count: bytes).write(to: fileURL)
        try setMTime(fileURL, mtime)
        try setMTime(directory, mtime)
    }

    private func setMTime(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path(percentEncoded: false))
    }
}
