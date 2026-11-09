# 空间清理

## 职责与事实来源

[`DiskCleaner`](../../Sources/SoftLive/Cleaner/DiskCleaner.swift) 与 [`CleanRuleEngine`](../../Sources/SoftLive/Cleaner/CleanRuleEngine.swift) 构成独立的按需空间清理子系统（数据模型定义在 [`CleanModels.swift`](../../Sources/SoftLive/Cleaner/CleanModels.swift)，界面承载于配置中心的 [`CleanerPaneView`](../../Sources/SoftLive/UI/Cleaner/CleanerPaneView.swift)）。

全部运行在当前用户普通权限下，**不需要**完全磁盘访问权限（Full Disk Access）或常驻 `root` 特权守护进程，平时后台无定时器、无文件系统监听（0% CPU 开销）。

| 分类 (`CleanCategory`) | 白名单扫描路径 | 安全级别 (`CleanSafetyTier`) | 过滤与保护规则 |
| --- | --- | --- | --- |
| 应用缓存与日志 (`appCaches`) | `~/Library/Caches/*`、`~/Library/Logs/*`、`~/Library/DiagnosticReports/*`、`~/Library/Application Support/CrashReporter/*` | `.safe`（默认勾选） | 自动跳过 `com.apple.*` 与系统关键守护进程缓存、跳过已归入 `devCaches` 的同名目录（避免重复计费），并根据 `NSWorkspace.shared.runningApplications` 的 `bundleIdentifier`、应用名与产品词根（如 `com.electron.lark` → `LarkShell`、`com.google.Chrome` → `Google`）跳过正在运行的应用 |
| 开发工具与包缓存 (`devCaches`) | Xcode（`DerivedData/*`、`CoreSimulator/Caches/*`、`*DeviceSupport/*`、`Archives/*`）、`Homebrew`、`npm`、`pnpm`、`Yarn`、`Bun`、`mise`、`SwiftPM`、`Cargo`、`pip`、`uv`、`Poetry`、`CocoaPods`、`go-build`、`TypeScript`、`Playwright`、`Cypress`、`Gradle`、`Maven`、`Hugging Face Hub` | `DerivedData`、模拟器缓存与包下载缓存为 `.safe`；`DeviceSupport`、`Archives`、`Playwright`、`Cypress`、`Maven` 与 `Hugging Face Models` 为 `.checkFirst`（默认不勾选） | 检测到 Xcode（`com.apple.dt.Xcode`）或 Simulator 正在运行时，自动跳过 `DerivedData` 与模拟器缓存 |
| 闲置项目构建产物 (`staleArtifacts`) | `~/Documents/GitHub`、`~/Developer`、`~/Projects`、`~/Code`、`~/Work`（限深 3 层）下的 `.build`、`node_modules`、`target`（需同级含 `Cargo.toml` 或 `pom.xml`）、`dist`、`.next`、`.turbo` | `.safe`（默认勾选） | 在 Git 仓库根目录（`.git/index`、`.git/HEAD`、`.git/FETCH_HEAD` 及一级子项）判定仓库最近活跃时间；若主仓库在 `Preferences.cleanStaleThreshold`（`7 / 14 / 30 天`）内有活动，直接跳过整个仓库及其 monorepo 子包，且始终跳过 `excludedPaths`（含当前工作目录） |
| 卸载残留与安装包 (`leftoversAndInstallers`) | `~/Library/Saved Application State/*.savedState`、`~/Library/HTTPStorages/*`、`~/Library/Application Support/*`（仅扫描反域名 `com.*` / `org.*` / `io.*` 等三段式目录并比对 `/Applications`、`~/Applications` 已安装应用）及 `~/Downloads` 下的 `.dmg` / `.pkg` / `.mpkg` / `.xip` / `.iso` / `.zip` / `.tar.gz` / `.tgz` / `.crdownload` / `.part` | `Saved Application State` 与孤立 `HTTPStorages` 为 `.safe`；已卸载应用的 `Application Support` 残留与下载区超过闲置天数的安装包（`>= 20 MB`）为 `.checkFirst`（默认不勾选） | 比对已安装应用 Bundle ID 与产品词根，保留任何已安装或正在运行应用的数据目录 |

## 运行路径

1. **打开自动扫描与多核并发统计**：首次切换到配置中心「清理」页、点击「重扫」或切换闲置天数阈值（`7 / 14 / 30 天`）时，在主线程拍摄运行中与已安装应用快照 [`CleanEnvironment`](../../Sources/SoftLive/Cleaner/CleanRuleEngine.swift)，随后在后台通过 `DispatchQueue.concurrentPerform` 并行扫描四大分类。
   - **POSIX `fts_open` 物理块统计与硬链接去重**：`CleanRuleEngine.directoryMetrics(at:)` 使用 `fts_open(..., FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil)` 遍历目录，按 `st_blocks * 512` 统计真实物理分配字节，并对 `st_nlink > 1` 的硬链接文件（如 pnpm / Bun 虚拟存储）按 `st_ino` 去重。
   - 扫描完成后按体积降序排列，自动勾选所有 `.safe` 项，保留 `.checkFirst` 项为未勾选状态；关闭配置中心窗口时调用 `DiskCleaner.cancelInFlightScan()` 立即取消未完成扫描。
2. **筛选、搜索与排序**：界面支持按 Bento 分类卡片筛选、按安全等级（`全部 / 安全项 / 核对项`）筛选、按关键字实时搜索名称或路径，以及切换排序方式（`按体积 / 按时间 / 按名称`）。
3. **二次校验与移入废纸篓**：用户点击「移入废纸篓 → 确认移入」后，`DiskCleaner.trashSelected()` 对每个勾选项调用 `CleanRuleEngine.canSafelyTrash(_:environment:)` 重新核对路径白名单、非符号链接与运行态，通过后调用 `FileManager.default.trashItem(at:resultingItemURL:)` 移入系统废纸篓，并提供一键打开系统废纸篓入口。

## 约束与失败行为

- **符号链接隔离（不使用 `NSDirectoryEnumerator.skipDescendants()`）**：`fts_open` 启用 `FTS_PHYSICAL` 从内核/C 库层保证绝不穿透符号链接；不能在 `FileManager.default.enumerator` 遇到叶子符号链接（如 `node_modules/.bin/*`）时调用 `skipDescendants()`，否则 `NSDirectoryEnumerator` 会直接跳过父目录的剩余兄弟节点导致整个 `node_modules` 统计为 `0 KB`。
- **单次计费原则**：`~/Library/Caches` 下的 `Homebrew`、`pnpm`、`Yarn`、`bun`、`mise`、`org.swift.swiftpm`、`pip`、`uv`、`pypoetry`、`CocoaPods`、`go-build`、`typescript`、`ms-playwright`、`Cypress` 仅归入 `devCaches`，在 `appCaches` 扫描中显式跳过。
- **权限或占用失败回退**：若个别目录因系统保护或瞬间文件锁导致 `trashItem` 抛出错误，计入 `CleanSummaryReport.skippedCount` 并继续处理其余勾选项，不中断整批回收入篓。

## 验证

- `swift test --filter DiskCleanerTests`
