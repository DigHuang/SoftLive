# 空间清理与应用卸载

## 职责与事实来源

[`DiskCleaner`](../../Sources/SoftLive/Cleaner/DiskCleaner.swift)、[`CleanRuleEngine`](../../Sources/SoftLive/Cleaner/CleanRuleEngine.swift) 与 [`AppUninstallEngine`](../../Sources/SoftLive/Cleaner/AppUninstallEngine.swift) 构成独立的按需空间清理与应用卸载子系统（数据模型定义在 [`CleanModels.swift`](../../Sources/SoftLive/Cleaner/CleanModels.swift)，界面承载于配置中心的 [`CleanerPaneView`](../../Sources/SoftLive/UI/Cleaner/CleanerPaneView.swift)）。

全部运行在当前用户普通权限下，**不需要**完全磁盘访问权限（Full Disk Access）或常驻 `root` 特权守护进程，平时后台无定时器、无文件系统监听（0% CPU 开销）。

### 模式一：缓存与残留（`CleanerMode.junkClean`）

| 分类 (`CleanCategory`) | 白名单扫描路径 | 安全级别 (`CleanSafetyTier`) | 过滤与保护规则 |
| --- | --- | --- | --- |
| 应用缓存与日志 (`appCaches`) | `~/Library/Caches/*`、`~/Library/Logs/*`、`~/Library/DiagnosticReports/*`、`~/Library/Application Support/CrashReporter/*` | `.safe`（默认勾选） | 自动跳过 `com.apple.*` 与系统关键守护进程缓存、跳过已归入 `devCaches` 的同名目录（避免重复计费），并根据 `NSWorkspace.shared.runningApplications` 的 `bundleIdentifier`、应用名与产品词根（如 `com.electron.lark` → `LarkShell`、`com.google.Chrome` → `Google`）跳过正在运行的应用 |
| 开发工具与包缓存 (`devCaches`) | Xcode（`DerivedData/*`、`CoreSimulator/Caches/*`、`*DeviceSupport/*`、`Archives/*`）、`Homebrew`、`npm`、`pnpm`、`Yarn`、`Bun`、`mise`、`SwiftPM`、`Cargo`、`pip`、`uv`、`Poetry`、`CocoaPods`、`go-build`、`TypeScript`、`Playwright`、`Cypress`、`Gradle`、`Maven`、`Hugging Face Hub` | `DerivedData`、模拟器缓存与包下载缓存为 `.safe`；`DeviceSupport`、`Archives`、`Playwright`、`Cypress`、`Maven` 与 `Hugging Face Models` 为 `.checkFirst`（默认不勾选） | 检测到 Xcode（`com.apple.dt.Xcode`）或 Simulator 正在运行时，自动跳过 `DerivedData` 与模拟器缓存 |
| 闲置项目构建产物 (`staleArtifacts`) | `~/Documents/GitHub`、`~/Developer`、`~/Projects`、`~/Code`、`~/Work`（限深 3 层）下的 `.build`、`node_modules`、`target`（需同级含 `Cargo.toml` 或 `pom.xml`）、`dist`、`.next`、`.turbo` | `.safe`（默认勾选） | 在 Git 仓库根目录（`.git/index`、`.git/HEAD`、`.git/FETCH_HEAD` 及一级子项）判定仓库最近活跃时间；若主仓库在 `Preferences.cleanStaleThreshold`（`7 / 14 / 30 天`）内有活动，直接跳过整个仓库及其 monorepo 子包，且始终跳过 `excludedPaths`（含当前工作目录） |
| 卸载残留与安装包 (`leftoversAndInstallers`) | `~/Library/Saved Application State/*.savedState`、`~/Library/HTTPStorages/*`、`~/Library/Application Support/*`（仅扫描反域名 `com.*` / `org.*` / `io.*` 等三段式目录并比对 `/Applications`、`~/Applications` 已安装应用）及 `~/Downloads` 下的 `.dmg` / `.pkg` / `.mpkg` / `.xip` / `.iso` / `.zip` / `.tar.gz` / `.tgz` / `.crdownload` / `.part` | `Saved Application State` 与孤立 `HTTPStorages` 为 `.safe`；已卸载应用的 `Application Support` 残留与下载区超过闲置天数的安装包（`>= 20 MB`）为 `.checkFirst`（默认不勾选） | 比对已安装应用 Bundle ID 与产品词根，保留任何已安装或正在运行应用的数据目录 |

### 模式二：应用卸载与数据重置（`CleanerMode.appUninstall`）

[`AppUninstallEngine`](../../Sources/SoftLive/Cleaner/AppUninstallEngine.swift) 扫描 `/Applications` 与 `~/Applications`（自动跳过 `/System/Applications`、`com.apple.*` 系统应用及 `SoftLive` 自身），并通过单次预索引 `UserLibraryIndex` 关联每个 `.app` 在 `~/Library` 下的 8 类文件（[`AppResidualKind`](../../Sources/SoftLive/Cleaner/CleanModels.swift)）：

| 关联类型 (`AppResidualKind`) | 扫描位置 | 默认安全级别 |
| --- | --- | --- |
| 应用本体 (`appBundle`) | `/Applications/*.app`、`~/Applications/*.app` 或拖入的 `.app` | `.safe`（完整卸载勾选；切换「仅清数据」时自动取消勾选以保留应用本体） |
| 应用支持 (`appSupport`) | `~/Library/Application Support/*`（匹配 Bundle ID、应用名与产品词根前缀） | `.safe` |
| 缓存数据 (`caches`) | `~/Library/Caches/*` | `.safe` |
| 沙盒容器 (`containers`) | `~/Library/Containers/*` | `.safe` |
| 偏好设置 (`preferences`) | `~/Library/Preferences/*.plist`、`~/Library/Preferences/ByHost/*.plist` | `.safe` |
| 状态与网络 (`stateAndWeb`) | `~/Library/Saved Application State/*.savedState`、`~/Library/HTTPStorages/*`、`~/Library/WebKit/*` | `.safe` |
| 诊断日志 (`logs`) | `~/Library/Logs/*` | `.safe` |
| 共享与启动项 (`sharedAndAgents`) | `~/Library/Group Containers/*`、`~/Library/LaunchAgents/*.plist` | `.checkFirst`（默认不勾选，防止同厂商其他应用共用容器被误删） |

## 运行路径

1. **打开自动扫描与多核并发统计**：首次切换到「清理」页或切换顶部「缓存与残留 / 应用卸载」模式时，自动在后台通过 `DispatchQueue.concurrentPerform` 并行扫描。
   - **POSIX `fts_open` 物理块统计与硬链接去重**：`CleanRuleEngine.directoryMetrics(at:)` 使用 `fts_open(..., FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil)` 遍历目录，按 `st_blocks * 512` 统计真实物理分配字节，并对 `st_nlink > 1` 的硬链接文件（如 pnpm / Bun 虚拟存储）按 `st_ino` 去重。
2. **Finder `.app` 拖拽直达（`.onDrop`）**：在「清理」页任意区域拖入 `.app` 应用包，自动切换至「应用卸载」模式并调用 `DiskCleaner.handleDroppedAppURL(_:)` 实时拆解该应用的本体与关联文件。
3. **完整卸载 vs 仅重置应用数据**：
   - 在「应用卸载」右侧面板可一键切换 **「完整卸载」**（勾选 `.app` 本体 + 安全关联项）或 **「仅清数据」**（取消勾选 `.app` 本体，仅清理 `~/Library` 关联缓存与数据，保留应用本身）。
   - 执行时若目标应用正在运行，先通过 `NSRunningApplication.terminate()` 请求优雅退出；随后经 `AppUninstallEngine.canSafelyTrash` 二次校验后调用 `FileManager.default.trashItem` 移入系统废纸篓。

## 约束与失败行为

- **符号链接隔离（不使用 `NSDirectoryEnumerator.skipDescendants()`）**：`fts_open` 启用 `FTS_PHYSICAL` 从内核/C 库层保证绝不穿透符号链接；不能在 `FileManager.default.enumerator` 遇到叶子符号链接（如 `node_modules/.bin/*`）时调用 `skipDescendants()`，否则 `NSDirectoryEnumerator` 会直接跳过父目录的剩余兄弟节点导致整个 `node_modules` 统计为 `0 KB`。
- **单次计费原则**：`~/Library/Caches` 下的 `Homebrew`、`pnpm`、`Yarn`、`bun`、`mise`、`org.swift.swiftpm`、`pip`、`uv`、`pypoetry`、`CocoaPods`、`go-build`、`typescript`、`ms-playwright`、`Cypress` 仅归入 `devCaches`，在 `appCaches` 扫描中显式跳过。
- **权限或占用失败回退**：若个别目录因系统保护或瞬间文件锁导致 `trashItem` 抛出错误，计入 `CleanSummaryReport.skippedCount` 并继续处理其余勾选项，不中断整批回收入篓。

## 验证

- `swift test --filter DiskCleanerTests`
