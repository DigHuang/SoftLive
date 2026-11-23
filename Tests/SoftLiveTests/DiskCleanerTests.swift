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
        defer {
            try? fm.removeItem(at: tempHome)
            L10n.language = .system
        }

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
        try setMTime(staleNodeModules.appending(path: ".bun"), tenDaysAgo)
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

        // - Orphaned app support folders (including `.cc` reverse-DNS TLD)
        let orphanSupport = tempHome.appending(path: "Library/Application Support/com.deleted.oldapp", directoryHint: .isDirectory)
        try writeSizedFile(in: orphanSupport, name: "state.db", bytes: 128 * 1024, mtime: tenDaysAgo)
        let ccOrphanSupport = tempHome.appending(path: "Library/Application Support/cc.demo.client", directoryHint: .isDirectory)
        try writeSizedFile(in: ccOrphanSupport, name: "prefs.db", bytes: 128 * 1024, mtime: tenDaysAgo)

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

        // Verify discovered items across both Chinese and English runtime languages (`displayTitle`)
        preferences.language = .zhHans
        let zhTitles = Set(cleaner.candidates.map(\.displayTitle))
        #expect(zhTitles.contains("Spotify (com.spotify.client)"))
        #expect(!zhTitles.contains(where: { $0.contains("163music") }))
        #expect(!zhTitles.contains(where: { $0.contains("LarkShell") }))
        #expect(!zhTitles.contains(where: { $0.contains("Safari") }))
        #expect(zhTitles.contains("Homebrew 缓存"))
        #expect(zhTitles.contains("DerivedData · DemoApp"))
        #expect(zhTitles.contains("Xcode 归档 · 2026-11-01"))
        #expect(zhTitles.contains("OldRepo · node_modules"))
        #expect(!zhTitles.contains("ActiveRepo · node_modules"))
        #expect(zhTitles.contains("InstallerOld.dmg"))
        #expect(zhTitles.contains("卸载残留 · Oldapp"))
        #expect(zhTitles.contains("卸载残留 · Demo (cc.demo.client)"))
        #expect(!zhTitles.contains(where: { $0.contains("卸载残留") && $0.contains("Spotify") }))

        preferences.language = .en
        let enTitles = Set(cleaner.candidates.map(\.displayTitle))
        #expect(enTitles.contains("Homebrew Cache"))
        #expect(enTitles.contains("Xcode Archive · 2026-11-01"))
        #expect(enTitles.contains("App Leftover · Oldapp"))
        #expect(enTitles.contains("App Leftover · Demo (cc.demo.client)"))

        // Homebrew must only appear under `.devCaches`, never duplicated in `.appCaches`
        let appCacheItems = cleaner.candidates(for: .appCaches)
        #expect(appCacheItems.count == 1)
        let devItems = cleaner.candidates(for: .devCaches)
        #expect(devItems.count == 3)
        let leftoverItems = cleaner.candidates(for: .leftoversAndInstallers)
        #expect(leftoverItems.count == 3)

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

        // Render idle state (Chinese & English, Light & Dark) at minimum window size (740 x 640) to guarantee zero clipping
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for lang in [AppLanguage.zhHans, .en] {
                preferences.language = lang
                try assertCleanerPaneRenders(
                    model: model,
                    monitor: monitor,
                    cleaner: cleaner,
                    preferences: preferences,
                    state: state,
                    size: ControlCenterWindow.minWindowSize,
                    appearanceName: appearance
                )
            }
        }

        // Scan and render populated state across 740x640, 780x680, 900x760 in ZH & EN, Light & Dark
        cleaner.performSynchronousScan(environment: env)
        #expect(cleaner.candidates.count == 5)
        #expect(cleaner.selectedCount == 4)

        for size in [ControlCenterWindow.minWindowSize, ControlCenterWindow.defaultSize, NSSize(width: 900, height: 760)] {
            for lang in [AppLanguage.zhHans, .en] {
                preferences.language = lang
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    try assertCleanerPaneRenders(
                        model: model,
                        monitor: monitor,
                        cleaner: cleaner,
                        preferences: preferences,
                        state: state,
                        size: size,
                        appearanceName: appearance
                    )
                }
            }
        }

        // Render invalid-drop error banner in Mode 1 at minimum size
        cleaner.inspectDroppedAppURL(tempHome.appending(path: "NotAnApp.txt"))
        #expect(cleaner.dropErrorMessage != nil)
        try assertCleanerPaneRenders(
            model: model,
            monitor: monitor,
            cleaner: cleaner,
            preferences: preferences,
            state: state,
            size: ControlCenterWindow.minWindowSize
        )
        cleaner.clearDropError()

        // Render partial-trash failure banner (`skippedCount > 0`) at minimum window size across languages
        struct MockTrashError: Error {}
        var calls = 0
        let partialReport = cleaner.trashSelected(environment: env) { url in
            calls += 1
            if calls == 1 {
                throw MockTrashError()
            }
            try fm.removeItem(at: url)
        }
        #expect(partialReport.trashedCount >= 1)
        #expect(partialReport.skippedCount == 1)
        try assertCleanerPaneRenders(
            model: model,
            monitor: monitor,
            cleaner: cleaner,
            preferences: preferences,
            state: state,
            size: ControlCenterWindow.minWindowSize
        )
        preferences.language = .zhHans
        try assertCleanerPaneRenders(
            model: model,
            monitor: monitor,
            cleaner: cleaner,
            preferences: preferences,
            state: state,
            size: ControlCenterWindow.minWindowSize
        )

        // Render "All Clear" empty state after trashing remaining candidates
        cleaner.selectSafeDefaults()
        if cleaner.selectedCount > 0 {
            cleaner.trashSelected(environment: env) { url in try fm.removeItem(at: url) }
        }
        for remaining in cleaner.candidates where !cleaner.selectedIDs.contains(remaining.id) {
            cleaner.toggleCandidate(remaining.id)
        }
        if cleaner.selectedCount > 0 {
            cleaner.trashSelected(environment: env) { url in try fm.removeItem(at: url) }
        }
        #expect(cleaner.candidates.isEmpty)
        try assertCleanerPaneRenders(
            model: model,
            monitor: monitor,
            cleaner: cleaner,
            preferences: preferences,
            state: state,
            size: ControlCenterWindow.minWindowSize
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

    @Test func discoversInstalledAppsMatchesLibraryResidualsSupportsAppResetAndFullUninstall() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory
            .appending(path: "SoftLiveAppUninstall-\(UUID().uuidString)", directoryHint: .isDirectory)
        let tempHome = tempRoot.appending(path: "Home", directoryHint: .isDirectory)
        let tempApps = tempRoot.appending(path: "Applications", directoryHint: .isDirectory)
        let externalDir = tempRoot.appending(path: "External", directoryHint: .isDirectory)
        try fm.createDirectory(at: tempHome, withIntermediateDirectories: true)
        try fm.createDirectory(at: tempApps, withIntermediateDirectories: true)
        try fm.createDirectory(at: externalDir, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: tempRoot)
            L10n.language = .system
        }

        // 1. Create a mock installed app (`AcmeStudio.app`, bundleID `com.acme.studio`)
        let acmeApp = try createMockAppBundle(
            in: tempApps,
            bundleName: "AcmeStudio.app",
            bundleID: "com.acme.studio",
            displayName: "Acme Studio",
            version: "2.4.0",
            binaryBytes: 512 * 1024
        )
        // System app (`com.apple.Safari`) must be ignored
        _ = try createMockAppBundle(
            in: tempApps,
            bundleName: "Safari.app",
            bundleID: "com.apple.Safari",
            displayName: "Safari",
            version: "26.0",
            binaryBytes: 256 * 1024
        )

        // 2. Create associated ~/Library residuals for `com.acme.studio`
        let appSupportDir = tempHome.appending(path: "Library/Application Support/Acme Studio", directoryHint: .isDirectory)
        try writeSizedFile(in: appSupportDir, name: "workspace.db", bytes: 256 * 1024, mtime: .now)

        let cacheDir = tempHome.appending(path: "Library/Caches/com.acme.studio", directoryHint: .isDirectory)
        try writeSizedFile(in: cacheDir, name: "shader.cache", bytes: 128 * 1024, mtime: .now)

        let prefsDir = tempHome.appending(path: "Library/Preferences", directoryHint: .isDirectory)
        try writeSizedFile(in: prefsDir, name: "com.acme.studio.plist", bytes: 16 * 1024, mtime: .now)

        let savedStateDir = tempHome.appending(path: "Library/Saved Application State/com.acme.studio.savedState", directoryHint: .isDirectory)
        try writeSizedFile(in: savedStateDir, name: "windows.data", bytes: 32 * 1024, mtime: .now)

        let groupContainerDir = tempHome.appending(path: "Library/Group Containers/group.com.acme.studio.shared", directoryHint: .isDirectory)
        try writeSizedFile(in: groupContainerDir, name: "shared.sqlite", bytes: 64 * 1024, mtime: .now)

        let suiteName = "SoftLiveAppUninstallSuite.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = Preferences(defaults: defaults)
        let cleaner = DiskCleaner(preferences: preferences)

        cleaner.performSynchronousAppScan(
            homeDirectory: tempHome,
            applicationDirectories: [tempApps]
        )

        #expect(cleaner.installedApps.count == 1)
        let target = try #require(cleaner.selectedApp)
        #expect(target.displayName == "Acme Studio")
        #expect(target.bundleID == "com.acme.studio")
        #expect(target.version == "2.4.0")
        // 1 (.app bundle) + 5 (Application Support, Caches, Preferences, Saved State, Group Container) = 6 items
        #expect(target.residuals.count == 6)
        #expect(cleaner.isSelectedAppBundleChecked)

        // Group Container is `.checkFirst`, so 5 `.safe` items are pre-selected by default
        #expect(cleaner.selectedAppItemCount == 5)

        // Render App Uninstaller workspace across sizes, languages, and Light/Dark modes
        cleaner.mode = .appUninstall
        let model = PlaybackModel(sources: [])
        let monitor = SystemMonitor(preferences: preferences)
        let state = ControlCenterState()
        state.isOpen = true
        state.selectedSection = .cleaner

        for size in [ControlCenterWindow.minWindowSize, ControlCenterWindow.defaultSize, NSSize(width: 900, height: 760)] {
            for lang in [AppLanguage.zhHans, .en] {
                preferences.language = lang
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    try assertCleanerPaneRenders(
                        model: model,
                        monitor: monitor,
                        cleaner: cleaner,
                        preferences: preferences,
                        state: state,
                        size: size,
                        appearanceName: appearance
                    )
                }
            }
        }

        // Step A: Test "Reset Data Only" (`selectAppResidualsOnly`) — unchecks `.appBundle`, trashes 4 safe Library items
        cleaner.selectAppResidualsOnly()
        #expect(!cleaner.isSelectedAppBundleChecked)
        #expect(cleaner.selectedAppItemCount == 4)
        try assertCleanerPaneRenders(
            model: model,
            monitor: monitor,
            cleaner: cleaner,
            preferences: preferences,
            state: state,
            size: ControlCenterWindow.minWindowSize
        )

        let resetReport = cleaner.trashSelectedAppItems(
            homeDirectory: tempHome,
            allowedApplicationDirectories: [tempApps]
        ) { url in
            try fm.removeItem(at: url)
        }
        #expect(resetReport.trashedCount == 4)
        #expect(fm.fileExists(atPath: acmeApp.path(percentEncoded: false)))
        // App remains installed, with only `.appBundle` and unchecked `Group Container` left
        #expect(cleaner.installedApps.count == 1)
        #expect(cleaner.selectedApp?.residuals.count == 2)

        // Step B: Test "Full Uninstall" — selects `.appBundle` and trashes the app itself
        cleaner.selectAllSafeAppResiduals()
        #expect(cleaner.isSelectedAppBundleChecked)
        let uninstallReport = cleaner.trashSelectedAppItems(
            homeDirectory: tempHome,
            allowedApplicationDirectories: [tempApps]
        ) { url in
            try fm.removeItem(at: url)
        }
        #expect(uninstallReport.trashedCount == 1)
        #expect(!fm.fileExists(atPath: acmeApp.path(percentEncoded: false)))
        #expect(cleaner.installedApps.isEmpty)

        // Step C: Test Finder `.app` Drag & Drop (`handleDroppedAppURL`) and preservation across scans
        cleaner.mode = .junkClean
        let droppedApp = try createMockAppBundle(
            in: externalDir,
            bundleName: "DroppedTool.app",
            bundleID: "io.dropped.tool",
            displayName: "Dropped Tool",
            version: "1.2.0",
            binaryBytes: 192 * 1024
        )
        let droppedAccepted = cleaner.handleDroppedAppURL(droppedApp, homeDirectory: tempHome)
        #expect(droppedAccepted)
        #expect(cleaner.mode == .appUninstall)
        #expect(cleaner.selectedApp?.displayName == "Dropped Tool")

        cleaner.performSynchronousAppScan(homeDirectory: tempHome, applicationDirectories: [tempApps])
        #expect(cleaner.installedApps.contains { $0.id == CleanRuleEngine.canonicalPath(droppedApp) })
        #expect(cleaner.selectedApp?.displayName == "Dropped Tool")
    }

    @Test func skipsActiveMonorepoSubpackagesFreshArtifactsAndGitWorktreeActivity() throws {
        let fm = FileManager.default
        let tempHome = fm.temporaryDirectory
            .appending(path: "SoftLiveMonorepoTest-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: tempHome, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempHome) }

        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let tenDaysAgo = now.addingTimeInterval(-10 * 86_400)
        let twoDaysAgo = now.addingTimeInterval(-2 * 86_400)

        // Monorepo with an older Git index/HEAD (> 7 days), one actively modified subpackage, and one stale subpackage.
        let monoRepo = tempHome.appending(path: "Documents/GitHub/MonoRepo", directoryHint: .isDirectory)
        try writeSizedFile(in: monoRepo.appending(path: ".git", directoryHint: .isDirectory), name: "index", bytes: 4096, mtime: tenDaysAgo)
        try writeSizedFile(in: monoRepo.appending(path: ".git", directoryHint: .isDirectory), name: "HEAD", bytes: 32, mtime: tenDaysAgo)

        let activeWeb = monoRepo.appending(path: "packages/web", directoryHint: .isDirectory)
        try writeSizedFile(in: activeWeb.appending(path: "node_modules", directoryHint: .isDirectory), name: "react.js", bytes: 128 * 1024, mtime: twoDaysAgo)
        try writeSizedFile(in: activeWeb, name: "package.json", bytes: 1024, mtime: twoDaysAgo)

        let staleLegacy = monoRepo.appending(path: "packages/legacy", directoryHint: .isDirectory)
        try writeSizedFile(in: staleLegacy.appending(path: "node_modules", directoryHint: .isDirectory), name: "old.js", bytes: 128 * 1024, mtime: tenDaysAgo)
        try setMTime(staleLegacy, tenDaysAgo)
        try setMTime(monoRepo.appending(path: "packages", directoryHint: .isDirectory), tenDaysAgo)
        try setMTime(monoRepo, tenDaysAgo)

        // Git worktree with `.git` file (`gitdir: ...`) whose external `logs/HEAD` was updated recently.
        let externalGitDir = tempHome.appending(path: "GitMeta/worktree-1", directoryHint: .isDirectory)
        try writeSizedFile(in: externalGitDir.appending(path: "logs", directoryHint: .isDirectory), name: "HEAD", bytes: 256, mtime: twoDaysAgo)
        let worktreeRepo = tempHome.appending(path: "Documents/GitHub/WorktreeRepo", directoryHint: .isDirectory)
        try fm.createDirectory(at: worktreeRepo, withIntermediateDirectories: true)
        let dotGitFile = worktreeRepo.appending(path: ".git")
        try "gitdir: \(externalGitDir.path(percentEncoded: false))\n".write(to: dotGitFile, atomically: true, encoding: .utf8)
        try writeSizedFile(in: worktreeRepo.appending(path: ".build", directoryHint: .isDirectory), name: "app.o", bytes: 128 * 1024, mtime: tenDaysAgo)
        try setMTime(dotGitFile, tenDaysAgo)
        try setMTime(worktreeRepo, tenDaysAgo)

        let env = CleanEnvironment(
            homeDirectory: tempHome,
            runningBundleIDs: [],
            runningProcessNames: [],
            installedBundleIDs: [],
            excludedPaths: [],
            staleDays: 7,
            minimumCacheEntryBytes: 1024,
            minimumInstallerBytes: 64 * 1024,
            now: now
        )

        let results = CleanRuleEngine.scan(environment: env)
        let titles = Set(results.map(\.title))
        #expect(!titles.contains("MonoRepo/web · node_modules"))
        #expect(!titles.contains("WorktreeRepo · .build"))
        #expect(titles.contains("MonoRepo/legacy · node_modules"))
    }

    @Test func blocksSymlinkAncestorsInvalidAppsTrashAndAllowsDownloadsWhileRunning() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory
            .appending(path: "SoftLiveSecurityTest-\(UUID().uuidString)", directoryHint: .isDirectory)
        let tempHome = tempRoot.appending(path: "Home", directoryHint: .isDirectory)
        let outsideDir = tempRoot.appending(path: "Outside", directoryHint: .isDirectory)
        try fm.createDirectory(at: tempHome, withIntermediateDirectories: true)
        try fm.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        // 1. Ancestor symlink escape under ~/Library/Caches
        let subOutside = outsideDir.appending(path: "SubCache", directoryHint: .isDirectory)
        try writeSizedFile(in: subOutside, name: "secret.dat", bytes: 64 * 1024, mtime: .now)
        let cachesDir = tempHome.appending(path: "Library/Caches", directoryHint: .isDirectory)
        try fm.createDirectory(at: cachesDir, withIntermediateDirectories: true)
        let evilParentLink = cachesDir.appending(path: "EvilParent")
        try fm.createSymbolicLink(at: evilParentLink, withDestinationURL: outsideDir)

        let forgedDescendant = CleanCandidate(
            url: evilParentLink.appending(path: "SubCache", directoryHint: .isDirectory),
            category: .appCaches,
            title: "Evil",
            subtitle: "~/Library/Caches/EvilParent/SubCache",
            sizeBytes: 64 * 1024,
            safetyTier: .safe
        )
        let env = CleanEnvironment(
            homeDirectory: tempHome,
            runningBundleIDs: ["com.google.chrome"],
            runningProcessNames: ["Google Chrome"],
            excludedPaths: [],
            staleDays: 7,
            minimumCacheEntryBytes: 1024,
            minimumInstallerBytes: 1024
        )
        #expect(!CleanRuleEngine.canSafelyTrash(forgedDescendant, environment: env))

        // 2. Downloads installer matching a running app must remain trashable when scanned as `.leftoversAndInstallers`
        let downloadsDir = tempHome.appending(path: "Downloads", directoryHint: .isDirectory)
        let chromeDMG = downloadsDir.appending(path: "GoogleChrome.dmg")
        try writeSizedFile(in: downloadsDir, name: "GoogleChrome.dmg", bytes: 128 * 1024, mtime: Date.now.addingTimeInterval(-10 * 86_400))
        let dmgCandidate = CleanCandidate(
            url: chromeDMG,
            category: .leftoversAndInstallers,
            title: "GoogleChrome.dmg",
            subtitle: "~/Downloads/GoogleChrome.dmg",
            sizeBytes: 128 * 1024,
            safetyTier: .checkFirst
        )
        #expect(CleanRuleEngine.canSafelyTrash(dmgCandidate, environment: env))

        // 3. Invalid .app bundles, SoftLive itself, and bundles inside ~/.Trash must be rejected
        let fakeFileApp = outsideDir.appending(path: "FakeFile.app")
        try Data(repeating: 0x11, count: 8192).write(to: fakeFileApp)
        #expect(AppUninstallEngine.inspectApp(at: fakeFileApp, homeDirectory: tempHome) == nil)

        let noMacOSApp = outsideDir.appending(path: "NoMacOS.app", directoryHint: .isDirectory)
        let noMacOSContents = noMacOSApp.appending(path: "Contents", directoryHint: .isDirectory)
        try fm.createDirectory(at: noMacOSContents, withIntermediateDirectories: true)
        try (["CFBundleIdentifier": "com.fake.nomacos"] as NSDictionary).write(to: noMacOSContents.appending(path: "Info.plist"))
        #expect(AppUninstallEngine.inspectApp(at: noMacOSApp, homeDirectory: tempHome) == nil)

        let selfApp = try createMockAppBundle(
            in: outsideDir,
            bundleName: "SoftLive.app",
            bundleID: "dev.softlive.SoftLive",
            displayName: "SoftLive",
            version: "0.0.2",
            binaryBytes: 32 * 1024
        )
        #expect(AppUninstallEngine.inspectApp(at: selfApp, homeDirectory: tempHome) == nil)

        let trashDir = tempHome.appending(path: ".Trash", directoryHint: .isDirectory)
        let trashedApp = try createMockAppBundle(
            in: trashDir,
            bundleName: "AlreadyTrashed.app",
            bundleID: "com.old.trashed",
            displayName: "AlreadyTrashed",
            version: "1.0",
            binaryBytes: 32 * 1024
        )
        #expect(AppUninstallEngine.inspectApp(at: trashedApp, homeDirectory: tempHome) == nil)
    }

    @Test func avoidsShortNamePrefixFalsePositivesInAppResiduals() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory
            .appending(path: "SoftLiveResidualMatch-\(UUID().uuidString)", directoryHint: .isDirectory)
        let tempHome = tempRoot.appending(path: "Home", directoryHint: .isDirectory)
        let tempApps = tempRoot.appending(path: "Applications", directoryHint: .isDirectory)
        try fm.createDirectory(at: tempHome, withIntermediateDirectories: true)
        try fm.createDirectory(at: tempApps, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let forkApp = try createMockAppBundle(
            in: tempApps,
            bundleName: "Fork.app",
            bundleID: "com.DanPristupov.Fork",
            displayName: "Fork",
            version: "2.40",
            binaryBytes: 64 * 1024
        )
        try writeSizedFile(in: tempHome.appending(path: "Library/Application Support/Fork", directoryHint: .isDirectory), name: "repos.json", bytes: 16 * 1024, mtime: .now)
        try writeSizedFile(in: tempHome.appending(path: "Library/Caches/Fork-Updater", directoryHint: .isDirectory), name: "update.zip", bytes: 16 * 1024, mtime: .now)
        try writeSizedFile(in: tempHome.appending(path: "Library/Application Support/ForkLift", directoryHint: .isDirectory), name: "workspaces.db", bytes: 64 * 1024, mtime: .now)
        try writeSizedFile(in: tempHome.appending(path: "Library/Group Containers/group.com.DanPristupov.Fork.shared", directoryHint: .isDirectory), name: "g.db", bytes: 8192, mtime: .now)
        try writeSizedFile(in: tempHome.appending(path: "Library/Group Containers/group.com.DanPristupov.Fork2", directoryHint: .isDirectory), name: "g2.db", bytes: 8192, mtime: .now)

        let target = try #require(AppUninstallEngine.inspectApp(at: forkApp, homeDirectory: tempHome))
        let residualTitles = Set(target.residuals.map(\.title))
        #expect(residualTitles.contains("Fork"))
        #expect(residualTitles.contains("Fork-Updater"))
        #expect(!residualTitles.contains("ForkLift"))
        #expect(residualTitles.contains("group.com.DanPristupov.Fork.shared"))
        #expect(!residualTitles.contains("group.com.DanPristupov.Fork2"))
    }

    @Test func cancelsInFlightScanAndDoesNotOvercountSparseFiles() throws {
        let fm = FileManager.default
        let tempHome = fm.temporaryDirectory
            .appending(path: "SoftLiveCancelSparse-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: tempHome, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempHome) }

        // 1. Sparse file with 0 allocated blocks must report 0 physical bytes, not logical st_size.
        let sparseDir = tempHome.appending(path: "Library/Caches/com.sparse.test", directoryHint: .isDirectory)
        try fm.createDirectory(at: sparseDir, withIntermediateDirectories: true)
        let sparseFile = sparseDir.appending(path: "sparse.img")
        fm.createFile(atPath: sparseFile.path(percentEncoded: false), contents: nil)
        let fh = try FileHandle(forWritingTo: sparseFile)
        try fh.truncate(atOffset: 2 * 1_048_576)
        try fh.close()
        let sparseMetrics = CleanRuleEngine.directoryMetrics(at: sparseDir)
        #expect(sparseMetrics.bytes == 0)

        // 2. Real non-empty file respects cancellation token immediately.
        try writeSizedFile(in: sparseDir, name: "real.bin", bytes: 64 * 1024, mtime: .now)
        let cancelToken = CleanCancellationToken()
        cancelToken.cancel()
        #expect(CleanRuleEngine.directoryMetrics(at: sparseDir, cancelToken: cancelToken).bytes == 0)

        let env = CleanEnvironment(
            homeDirectory: tempHome,
            runningBundleIDs: [],
            runningProcessNames: [],
            excludedPaths: [],
            minimumCacheEntryBytes: 1024
        )
        #expect(CleanRuleEngine.scan(environment: env, cancelToken: cancelToken).isEmpty)
        #expect(AppUninstallEngine.scanInstalledApps(homeDirectory: tempHome, applicationDirectories: [tempHome], cancelToken: cancelToken).isEmpty)

        // 3. DiskCleaner.cancelInFlightScan resets active scan state cleanly.
        let suiteName = "SoftLiveCancelSuite.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cleaner = DiskCleaner(preferences: Preferences(defaults: defaults))
        cleaner.scan()
        cleaner.cancelInFlightScan()
        #expect(!cleaner.isScanning)
        #expect(!cleaner.isScanningProtectedFolders)
        #expect(!cleaner.isScanningApps)
    }

    @Test func progressiveScanSplitsProtectedFoldersPreservesManualSelectionsAndRendersLongBundleID() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory
            .appending(path: "SoftLiveProgressive-\(UUID().uuidString)", directoryHint: .isDirectory)
        let tempHome = tempRoot.appending(path: "Home", directoryHint: .isDirectory)
        let tempApps = tempRoot.appending(path: "Applications", directoryHint: .isDirectory)
        try fm.createDirectory(at: tempHome, withIntermediateDirectories: true)
        try fm.createDirectory(at: tempApps, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: tempRoot)
            L10n.language = .system
        }

        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let tenDaysAgo = now.addingTimeInterval(-10 * 86_400)

        // Zero-TCC caches and non-TCC project root (`~/Developer`)
        let appCache = tempHome.appending(path: "Library/Caches/com.example.cached", directoryHint: .isDirectory)
        try writeSizedFile(in: appCache, name: "blob.dat", bytes: 128 * 1024, mtime: tenDaysAgo)
        let devProj = tempHome.appending(path: "Developer/LocalTool", directoryHint: .isDirectory)
        try writeSizedFile(in: devProj.appending(path: ".build", directoryHint: .isDirectory), name: "obj.o", bytes: 128 * 1024, mtime: tenDaysAgo)
        try setMTime(devProj, tenDaysAgo)

        let env = CleanEnvironment(
            homeDirectory: tempHome,
            runningBundleIDs: [],
            runningProcessNames: [],
            installedBundleIDs: [],
            excludedPaths: [],
            staleDays: 7,
            minimumCacheEntryBytes: 1024,
            minimumInstallerBytes: 64 * 1024,
            now: now
        )

        let suiteName = "SoftLiveProgressiveSuite.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = Preferences(defaults: defaults)
        let cleaner = DiskCleaner(preferences: preferences)

        // Populate Stage 1 before adding Documents/GitHub and Downloads fixtures
        cleaner.performSynchronousScan(environment: env)
        #expect(cleaner.candidates.count == 2)
        let cachedCandidate = try #require(cleaner.candidates.first { $0.title == "Cached" })
        cleaner.toggleCandidate(cachedCandidate.id) // user manually deselected Stage 1 safe item
        #expect(!cleaner.selectedIDs.contains(cachedCandidate.id))

        // Add TCC-gated locations (`~/Documents/GitHub` and `~/Downloads`)
        let docsProj = tempHome.appending(path: "Documents/GitHub/DocsRepo", directoryHint: .isDirectory)
        try writeSizedFile(in: docsProj.appending(path: "node_modules", directoryHint: .isDirectory), name: "pkg.js", bytes: 256 * 1024, mtime: tenDaysAgo)
        try setMTime(docsProj, tenDaysAgo)
        let downloadsDir = tempHome.appending(path: "Downloads", directoryHint: .isDirectory)
        try writeSizedFile(in: downloadsDir, name: "OldApp.dmg", bytes: 256 * 1024, mtime: tenDaysAgo)

        // 1. Stage 1 non-protected scan must skip Documents/GitHub and Downloads
        let stage1 = CleanRuleEngine.scanNonProtected(environment: env)
        let stage1Titles = Set(stage1.map(\.title))
        #expect(stage1Titles.contains("Cached"))
        #expect(stage1Titles.contains("LocalTool · .build"))
        #expect(!stage1Titles.contains("DocsRepo · node_modules"))
        #expect(!stage1Titles.contains("OldApp.dmg"))

        // 2. Stage 2 protected-folder helpers find only their respective directories
        let docsResults = CleanRuleEngine.scanDocumentsGitHub(environment: env)
        #expect(docsResults.map(\.title) == ["DocsRepo · node_modules"])
        let downloadResults = CleanRuleEngine.scanDownloadsInstallers(environment: env)
        #expect(downloadResults.map(\.title) == ["OldApp.dmg"])

        // 3. Merging Stage 2 results preserves existing manual selection changes and deduplicates
        cleaner.mergeProtectedScanResults(docsResults + downloadResults + stage1)
        #expect(cleaner.candidates.count == 4) // no duplicates from re-merging stage1
        #expect(!cleaner.selectedIDs.contains(cachedCandidate.id)) // user toggle preserved
        let docsItem = try #require(cleaner.candidates.first { $0.title == "DocsRepo · node_modules" })
        let dmgItem = try #require(cleaner.candidates.first { $0.title == "OldApp.dmg" })
        #expect(cleaner.selectedIDs.contains(docsItem.id)) // newly arrived .safe item selected
        #expect(!cleaner.selectedIDs.contains(dmgItem.id)) // newly arrived .checkFirst item stays unchecked

        // 4. VER-10: Long bundleID in App Uninstaller hero header renders cleanly alongside all 8 residual groups
        let claudeBundleID = "com.anthropic.claudefordesktop.helper.very.long.identifier"
        _ = try createMockAppBundle(
            in: tempApps,
            bundleName: "Claude.app",
            bundleID: claudeBundleID,
            displayName: "Claude",
            version: "1.2.3",
            binaryBytes: 128 * 1024
        )
        try writeSizedFile(in: tempHome.appending(path: "Library/Application Support/Claude", directoryHint: .isDirectory), name: "db.sqlite", bytes: 64 * 1024, mtime: now)
        try writeSizedFile(in: tempHome.appending(path: "Library/Caches/\(claudeBundleID)", directoryHint: .isDirectory), name: "c.bin", bytes: 32 * 1024, mtime: now)
        try writeSizedFile(in: tempHome.appending(path: "Library/Containers/\(claudeBundleID)", directoryHint: .isDirectory), name: "box.dat", bytes: 32 * 1024, mtime: now)
        try writeSizedFile(in: tempHome.appending(path: "Library/Preferences", directoryHint: .isDirectory), name: "\(claudeBundleID).plist", bytes: 4096, mtime: now)
        try writeSizedFile(in: tempHome.appending(path: "Library/Saved Application State/\(claudeBundleID).savedState", directoryHint: .isDirectory), name: "win.data", bytes: 8192, mtime: now)
        try writeSizedFile(in: tempHome.appending(path: "Library/Logs/Claude", directoryHint: .isDirectory), name: "main.log", bytes: 8192, mtime: now)
        try writeSizedFile(in: tempHome.appending(path: "Library/Group Containers/group.\(claudeBundleID)", directoryHint: .isDirectory), name: "g.db", bytes: 16 * 1024, mtime: now)

        cleaner.performSynchronousAppScan(homeDirectory: tempHome, applicationDirectories: [tempApps])
        cleaner.mode = .appUninstall
        let claudeTarget = try #require(cleaner.selectedApp)
        #expect(Set(claudeTarget.residuals.map(\.kind)).count == AppResidualKind.allCases.count)

        let model = PlaybackModel(sources: [])
        let monitor = SystemMonitor(preferences: preferences)
        let state = ControlCenterState()
        state.isOpen = true
        state.selectedSection = .cleaner

        preferences.language = .en
        #expect(CleanSafetyTier.checkFirst.badgeTitle == "Check First")
        #expect(CleanSortOrder.ageDesc.displayName == "Oldest")
        for size in [ControlCenterWindow.minWindowSize, ControlCenterWindow.defaultSize, NSSize(width: 900, height: 760)] {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                try assertCleanerPaneRenders(
                    model: model,
                    monitor: monitor,
                    cleaner: cleaner,
                    preferences: preferences,
                    state: state,
                    size: size,
                    appearanceName: appearance
                )
            }
        }
        preferences.language = .zhHans
        #expect(CleanSafetyTier.checkFirst.badgeTitle == "需核对")
        #expect(CleanSortOrder.ageDesc.displayName == "最久未动")
        for size in [ControlCenterWindow.minWindowSize, ControlCenterWindow.defaultSize, NSSize(width: 900, height: 760)] {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                try assertCleanerPaneRenders(
                    model: model,
                    monitor: monitor,
                    cleaner: cleaner,
                    preferences: preferences,
                    state: state,
                    size: size,
                    appearanceName: appearance
                )
            }
        }
    }

    private func assertCleanerPaneRenders(
        model: PlaybackModel,
        monitor: SystemMonitor,
        cleaner: DiskCleaner,
        preferences: Preferences,
        state: ControlCenterState,
        size: NSSize = ControlCenterWindow.defaultSize,
        appearanceName: NSAppearance.Name = .aqua
    ) throws {
        state.windowSize = size
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: appearanceName)
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

    private func createMockAppBundle(
        in directory: URL,
        bundleName: String,
        bundleID: String,
        displayName: String,
        version: String,
        binaryBytes: Int
    ) throws -> URL {
        let appURL = directory.appending(path: bundleName, directoryHint: .isDirectory)
        let contentsURL = appURL.appending(path: "Contents", directoryHint: .isDirectory)
        let macOSURL = contentsURL.appending(path: "MacOS", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: macOSURL, withIntermediateDirectories: true)

        let plist: NSDictionary = [
            "CFBundleIdentifier": bundleID,
            "CFBundleDisplayName": displayName,
            "CFBundleName": displayName,
            "CFBundleShortVersionString": version
        ]
        let plistURL = contentsURL.appending(path: "Info.plist")
        try plist.write(to: plistURL)

        let execURL = macOSURL.appending(path: displayName)
        try Data(repeating: 0x7F, count: binaryBytes).write(to: execURL)
        return appURL
    }

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
