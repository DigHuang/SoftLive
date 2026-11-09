# Changelog

**English** | [简体中文](CHANGELOG.zh-CN.md)

All notable user-facing changes to this project are documented in this file.

The format is based on [Keep a Changelog 2.0.0](https://keepachangelog.com/en/2.0.0/), and this project adheres to [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Lightweight Allowlist Disk Cleaner & App Uninstaller (`Cleaner` Subsystem)**: Added a standalone `Cleaner` subsystem (`CleanModels`, `CleanRuleEngine`, `AppUninstallEngine`, `DiskCleaner`) and a dual-mode `Cleaner` workspace (`CleanerPaneView`) in Control Center, and upgraded `ControlCenterWindow` to a larger, user-resizable window (`780 × 680 pt` default, `740 × 640 pt` minimum) with `⌘1–⌘4` section shortcuts:
  - **Junk & Caches Mode**: Scans 4 allowlisted categories in parallel via POSIX `fts_open(FTS_PHYSICAL)` with hard-link inode deduplication (App Caches & Logs, Dev Tools & Packages, Stale Project Builds with monorepo-aware `.git` activity checks, and Orphaned App Leftovers & Installers) without requiring Full Disk Access or a privileged helper.
  - **App Uninstaller & Reset Mode**: Discovers installed applications in `/Applications` and `~/Applications` (and accepts `.app` bundles dropped from Finder), correlates 8 categories of associated `~/Library` files (`Application Support`, `Caches`, `Containers`, `Preferences`, `Saved State`, `HTTPStorages`, `Logs`, `Group Containers` & `LaunchAgents`), and supports both **Full Uninstall** and **Reset Data Only** (keeping the `.app` bundle while moving its data to the macOS Trash).

## [0.0.2] - 2026-11-08

### Added

- **Sync Frost Brand Icon**: Added editable ribbon SVG assets, a native macOS 26 `.icon` project, and preview assets; `Scripts/build-app.sh` compiles the app icon bundle via `actool`. ([#14])
- **Desktop Configuration Center**: Added a `640 × 636 pt` split-view configuration window (`播放器` / `监听` tabs plus a bottom-left `SoftLive` product overview entry), accessible by reopening the app, pressing `⌘,` from the menu, or clicking the settings button in the monitor popover footer; unloads its SwiftUI subtree when closed for zero background overhead, and mounts `NSApp.mainMenu` so `⌘Q`, `⌘W`, `⌘M`, `⌘,`, and `⌘H` work natively when windows are focused. ([#16], [#19])
- **Customizable Lyrics & Monitor Preferences**: Added user preferences for menu bar lyrics max-width (`180 / 260 / 340 pt`), desktop floating lyrics font size (`22 / 26 / 30 pt`) and subline mode (`翻译优先 / 仅翻译 / 单行`), menu bar monitor display style (`52 × 22 pt` rate + bars or `20 × 22 pt` bars-only), colored vs. monochrome template monitor bars, default monitor popover tab, background sampling interval (`1s / 2s / 5s`), and `CPU / RAM / TMP` alert thresholds. ([#16], [#17])
- **Bilingual Localization (`zh-Hans` / `en`)**: Added compile-time safe Chinese and English localization across all windows, menus, overlays, and the monitor popover with instant in-app switching (`System / 简体中文 / English`), plus localized `InfoPlist.strings` for the macOS Automation permission prompt. ([#18])
- **Bilingual Documentation & Community Standards**: Added bilingual README/CHANGELOG switchers, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `SECURITY.md`, and GitHub Issue / PR templates. ([#15])

### Changed

- **Menu Bar Mark & Streamlined Right-Click Menu**: Displays an 18 pt monochrome Sync template icon (adapting to light/dark system appearance) when no lyric text is shown, and streamlines the status item right-click menu to keep only concise playback status, high-frequency desktop panel toggles, a compact `Lyrics Offset` submenu, `Control Center… (⌘,)`, and `Quit SoftLive (⌘Q)`. ([#14], [#19])
- **Desktop Widget & Stage Placeholders**: Displays the monochrome Sync mark when no album artwork is available across both the desktop widget and Stage Mode, sharing the brand template with the menu bar. ([#14], [#16])
- **Desktop Widget, Floating Lyrics & Stage HUD Refinement**: Added cached artwork-derived ambient aura lighting (`StagePalette.cached(for:)`) and adaptive Light/Dark controls to the desktop widget; upgraded the `⌘`-awake bar in desktop lyrics with track title and inline `±0.5s` offset pills; switched Stage Mode to a `darkAqua` four-corner HUD layout with double-click to skip tracks. ([#16])

### Fixed

- **Control Center Cross-Tab Top & Group Alignment**: Fixed a `5 pt` vertical header shift and `2 pt` group spacing discrepancy when switching between `Player`, `Monitor`, and `About` tabs in `ControlCenterWindow`, aligning the top edge of the first card (`y = 50 pt`) flush with the first sidebar navigation item across all tabs. ([#19])
- **Status Bar Monitor Second-Click Dismissal**: Prevented outside-click event monitors from racing with `NSStatusBarButton` action delivery and reopening the monitor popover on a second click, and restricted popover hit-testing to the inner card bounds. ([#16])

## [0.0.1] - 2026-11-06

Initial release of SoftLive: real-time word-by-word synced lyrics for Apple Music and NetEase Cloud Music across the macOS menu bar, floating desktop overlay, desktop widget, and standalone kinetic Stage Mode window, paired with a zero-permission menu bar system monitor and Liquid Glass popover.

### Added

- **Dual-Player Lyrics Sync**: Native support for **Apple Music** (`ScriptingBridge` + `playerInfo` distributed notifications) and **NetEase Cloud Music** (read-only monitoring of streaming `.info` cache files, SQLite `historyTracks`, and Chromium LevelDB records) — following track changes, play/pause, and seeks in the background without Accessibility permissions. ([#1])
- **Multi-Source Lyrics & Word-by-Word Highlighting**: Supports NetEase word-timed lyrics (YRC), line-timed lyrics (LRC), bilingual translation alignment, breathing three-dot interlude indicators (for intros, post-credit gaps, and instrumental breaks), LRCLIB fallback search, local disk caching, and `±0.5s` manual offset adjustment. ([#9])
- **Three Persistent Lyrics Surfaces**:
  - **Menu Bar Lyrics**: Adaptive width truncation; automatically hides its status bar item when lyrics are disabled and the system monitor is active.
  - **Desktop Floating Lyrics**: Always-on-top across spaces and full-screen apps, dual-layer soft shadows, and click-through by default; hold `⌘` and hover to wake the Liquid Glass backdrop and mini control bar, supporting drag positioning and double-click to skip tracks. ([#2])
  - **Desktop Widget**: Liquid Glass card pinned above desktop icons and below normal windows; collapses into a compact player selector when idle and expands with album artwork, progress bar, playback controls, and two-line karaoke lyrics when playing. ([#2])
- **Standalone Stage Mode**: Resizable and maximizable window featuring artwork-extracted aurora palette backgrounds, **Luminous** and **Ink Trace** Core Animation kinetic typography styles, optional spark particles, and a spinning vinyl interlude animation. ([#10])
- **Menu Bar System Monitor**: Dedicated `52 × 22 pt` status item displaying live upload/download throughput and semantic `CPU / RAM / TMP` bars; click to open a macOS 26+ Liquid Glass popover with 60-second trend graphs, E/P-core and GPU load matrices, **Top 10 CPU/Memory process rankings** with two-step process termination, memory pressure & swap, SoC/SSD/battery temperatures, and AppleSMC system power (Watts) & fan speed (RPM). ([#5])

### Changed

- **Core Animation Word Fill**: Rasterizes each lyric line once via CoreText and drives word-by-word highlight clipping with a single `CAKeyframeAnimation` instead of 30 fps layout passes, reducing CPU usage with both desktop lyrics and desktop widget active to `0–0.8%`. ([#1], [#6])
- **Zero Background Overhead & On-Demand Sampling**: Short-circuits bitmap rasterization, animation construction, global modifier key monitors, and `TimelineView` schedules when panels are hidden; keeps the monitor popover view tree resident while sampling detail metrics on demand for the active tab (`CPU / RAM / TMP` only), eliminating popover-open CPU spikes. ([#6], [#7])
- **Low-Overhead Seek Calibration**: Routes same-track NetEase progress reports directly into `ProgressCalibration` interval intersection without rescanning SQLite or the streaming cache directory; Apple Music seek checks read only `playerPosition`. ([#6])

### Fixed

- **LevelDB Cross-Block Parsing & Log Rotation**: Skips 7-byte LevelDB block continuation headers at 32 KiB boundaries so multi-kilobyte `playingInfo` records decode reliably, and drains the tail of the previous `.log` file before switching to a newly rotated log. ([#8])
- **Pause/Resume & Calibration Convergence**: Narrowed the `ProgressCalibration` window to `1.2s` based on measured audio buffering lead times; fixed false session expiration after long pauses, stale artwork carry-over on track changes, and missing artwork retries after transient failures. ([#2], [#8])
- **YRC Inter-Word Spaces & Cursor Alignment**: Merged standalone whitespace tokens into preceding words while keeping line text and word token UTF-16 lengths identical, fixing highlight drift on lines with leading spaces or English words. ([#8], [#9])
- **System Sampler Edge Cases**: Added explicit 3-byte alignment padding to the 80-byte `AppleSMC` `SMCKeyData_t` struct, resolved `KERN_PROCARGS2` + working directory names to distinguish generic host processes (`node` / `next-server`), excluded `utun*` tunnel interfaces from physical network rates, and filtered fixed `tcal` calibration sensors. ([#5], [#7], [#8])

[Unreleased]: https://github.com/DigHuang/SoftLive/compare/v0.0.2...HEAD
[0.0.2]: https://github.com/DigHuang/SoftLive/compare/v0.0.1...v0.0.2
[0.0.1]: https://github.com/DigHuang/SoftLive/releases/tag/v0.0.1
[#1]: https://github.com/DigHuang/SoftLive/pull/1
[#2]: https://github.com/DigHuang/SoftLive/pull/2
[#5]: https://github.com/DigHuang/SoftLive/pull/5
[#6]: https://github.com/DigHuang/SoftLive/pull/6
[#7]: https://github.com/DigHuang/SoftLive/pull/7
[#8]: https://github.com/DigHuang/SoftLive/pull/8
[#9]: https://github.com/DigHuang/SoftLive/pull/9
[#10]: https://github.com/DigHuang/SoftLive/pull/10
[#14]: https://github.com/DigHuang/SoftLive/pull/14
[#15]: https://github.com/DigHuang/SoftLive/pull/15
[#16]: https://github.com/DigHuang/SoftLive/pull/16
[#17]: https://github.com/DigHuang/SoftLive/pull/17
[#18]: https://github.com/DigHuang/SoftLive/pull/18
[#19]: https://github.com/DigHuang/SoftLive/pull/19
