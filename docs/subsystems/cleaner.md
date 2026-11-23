# 空间清理与应用卸载

## 职责与事实来源

[`DiskCleaner`](../../Sources/SoftLive/Cleaner/DiskCleaner.swift)、[`CleanRuleEngine`](../../Sources/SoftLive/Cleaner/CleanRuleEngine.swift) 与 [`AppUninstallEngine`](../../Sources/SoftLive/Cleaner/AppUninstallEngine.swift) 构成独立的按需空间清理与应用卸载子系统（数据模型定义在 [`CleanModels.swift`](../../Sources/SoftLive/Cleaner/CleanModels.swift)，界面承载于配置中心的 [`CleanerPaneView`](../../Sources/SoftLive/UI/Cleaner/CleanerPaneView.swift)）。

全部运行在当前用户普通权限下，**不需要**完全磁盘访问权限（Full Disk Access）或常驻 `root` 特权守护进程，平时后台无定时器、无文件系统监听（0% CPU 开销）。

### 模式一：缓存与残留（`CleanerMode.junkClean`）

| 分类 (`CleanCategory`) | 白名单扫描路径 | 安全级别 (`CleanSafetyTier`) | 过滤与保护规则 |
| --- | --- | --- | --- |
| 应用缓存与日志 (`appCaches`) | `~/Library/Caches/*`、`~/Library/Logs/*`、`~/Library/DiagnosticReports/*`、`~/Library/Application Support/CrashReporter/*` | `.safe`（默认勾选） | 自动跳过 `com.apple.*` 与系统关键守护进程缓存、跳过已归入 `devCaches` 的同名目录（避免重复计费），并根据 `NSWorkspace.shared.runningApplications` 的 `bundleIdentifier`、应用名与产品词根（如 `com.electron.lark` → `LarkShell`、`com.google.Chrome` → `Google`）跳过正在运行的应用 |
| 开发工具与包缓存 (`devCaches`) | Xcode（`DerivedData/*`、`CoreSimulator/Caches/*`、`*DeviceSupport/*`、`Archives/*`）、`Homebrew`、`npm`、`pnpm`、`Yarn`、`Bun`、`mise`、`SwiftPM`、`Cargo`、`pip`、`uv`、`Poetry`、`CocoaPods`、`go-build`、`TypeScript`、`Playwright`、`Cypress`、`Gradle`、`Maven`、`Hugging Face Hub` | `DerivedData`、模拟器缓存与包下载缓存为 `.safe`；`DeviceSupport`、`Archives`、`Playwright`、`Cypress`、`Maven` 与 `Hugging Face Models` 为 `.checkFirst`（默认不勾选） | 检测到 Xcode（`com.apple.dt.Xcode`）或 Simulator 正在运行时，自动跳过 `DerivedData` 与模拟器缓存 |
| 闲置项目构建产物 (`staleArtifacts`) | `~/Documents/GitHub`、`~/Developer`、`~/Projects`、`~/Code`、`~/Work`（限深 3 层）下的 `.build`、`node_modules`、`target`（需同级含 `Cargo.toml` 或 `pom.xml`）、`dist`、`.next`、`.turbo` | `.safe`（默认勾选） | 在 Git 仓库根目录（含 `.git` 目录及 worktree `gitdir:` 指向的 `index`、`HEAD`、`FETCH_HEAD`、`ORIG_HEAD`、`logs/HEAD`、`COMMIT_EDITMSG` 及一级子项）判定仓库最近活跃时间，并取子项目目录及构建产物自身最近修改时间的最大值；若仓库或构建产物在 `Preferences.cleanStaleThreshold`（`7 / 14 / 30 天`）内有活动则跳过，且始终跳过 `excludedPaths`（含当前工作目录） |
| 卸载残留与安装包 (`leftoversAndInstallers`) | `~/Library/Saved Application State/*.savedState`、`~/Library/HTTPStorages/*`、`~/Library/Application Support/*`（仅扫描反域名 `com.*` / `org.*` / `io.*` / `cc.*` 等三段式目录并比对 `/Applications`、`~/Applications` 已安装应用）及 `~/Downloads` 下的 `.dmg` / `.pkg` / `.mpkg` / `.xip` / `.iso` / `.zip` / `.tar.gz` / `.tgz` / `.crdownload` / `.part` | `Saved Application State` 与孤立 `HTTPStorages` 为 `.safe`；已卸载应用的 `Application Support` 残留与下载区超过闲置天数的安装包（`>= 20 MB`）为 `.checkFirst`（默认不勾选） | 比对已安装应用 Bundle ID 与产品词根，保留任何已安装或正在运行应用的数据目录（`~/Downloads` 下的安装包不按运行中应用名拦截） |

### 模式二：应用卸载与数据重置（`CleanerMode.appUninstall`）

[`AppUninstallEngine`](../../Sources/SoftLive/Cleaner/AppUninstallEngine.swift) 扫描 `/Applications` 与 `~/Applications`（自动跳过 `/System/`、`/Library/Apple/`、`/usr/`、`/bin/`、`/sbin/`、`~/.Trash`、`com.apple.*` 系统应用及 `SoftLive` 自身，并校验有效 `.app` 目录与 `Contents/MacOS`），通过单次预索引 `UserLibraryIndex` 关联每个 `.app` 在 `~/Library` 下的 8 类文件（[`AppResidualKind`](../../Sources/SoftLive/Cleaner/CleanModels.swift)）：

| 关联类型 (`AppResidualKind`) | 扫描位置 | 默认安全级别 |
| --- | --- | --- |
| 应用本体 (`appBundle`) | `/Applications/*.app`、`~/Applications/*.app` 或拖入的 `.app` | `.safe`（完整卸载勾选；切换「仅清数据」时自动取消勾选以保留应用本体） |
| 应用支持 (`appSupport`) | `~/Library/Application Support/*`（匹配 Bundle ID、应用名及词界分隔的产品名，避免短名误匹配其他应用） | `.safe` |
| 缓存数据 (`caches`) | `~/Library/Caches/*` | `.safe` |
| 沙盒容器 (`containers`) | `~/Library/Containers/*` | `.safe` |
| 偏好设置 (`preferences`) | `~/Library/Preferences/*.plist`、`~/Library/Preferences/ByHost/*.plist` | `.safe` |
| 状态与网络 (`stateAndWeb`) | `~/Library/Saved Application State/*.savedState`、`~/Library/HTTPStorages/*`、`~/Library/WebKit/*` | `.safe` |
| 诊断日志 (`logs`) | `~/Library/Logs/*` | `.safe` |
| 共享与启动项 (`sharedAndAgents`) | `~/Library/Group Containers/*`、`~/Library/LaunchAgents/*.plist` | `.checkFirst`（默认不勾选，且按点分隔边界匹配，防止同厂商其他应用共用容器被误删） |

## 运行路径

1. **两阶段渐进式并发扫描、后台移入废纸篓与即时取消**：首次切换到「清理」页或切换顶部「缓存与残留 / 应用卸载」模式时，在后台执行扫描（`CleanEnvironment` 发现、回收站移动及拖入解析均在后台执行，不阻塞 `MainActor`）；关闭配置中心或重扫时通过 `CleanCancellationToken` 立即中止目录与 `fts_read` 遍历。
   - **Stage 1（零 TCC 路径即时出结果）**：`DiskCleaner.scan()` 先调用 `CleanRuleEngine.scanNonProtected(environment:cancelToken:)`，通过 `DispatchQueue.concurrentPerform` 并发扫描 `~/Library` 缓存/日志/残留、开发工具缓存与 `~/Developer`、`~/Projects`、`~/Code`、`~/Work`，立即结束主加载态并填充 4 张分类卡片与候选列表。
   - **Stage 2（独立异步扫描受 TCC 保护目录）**：Stage 1 发布后，再启动两个互不阻塞的独立后台任务分别调用 `CleanRuleEngine.scanDocumentsGitHub(environment:cancelToken:)` 与 `CleanRuleEngine.scanDownloadsInstallers(environment:cancelToken:)`（`Info.plist` 与 `Resources/{zh-Hans,en}.lproj/InfoPlist.strings` 已声明 `NSDocumentsFolderUsageDescription` 与 `NSDownloadsFolderUsageDescription`）；任一目录就绪后即通过 `DiskCleaner.mergeProtectedScanResults(_:)` 增量去重并入列表，且保留用户对 Stage 1 条目的手动勾选状态。若系统授权弹窗待确认，Stage 1 结果与清理操作不受阻塞。
   - **POSIX `fts_open` 物理块统计与硬链接去重**：`CleanRuleEngine.directoryMetrics(at:cancelToken:)` 使用 `fts_open(..., FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil)` 遍历目录，按 `st_blocks * 512` 统计真实物理分配字节（稀疏空洞与 iCloud 占位文件记为 `0`），并对 `st_nlink > 1` 的硬链接文件（如 pnpm / Bun 虚拟存储）按 `st_ino` 去重。
   - **动态双语标题解析**：扫描引擎通过 [`BilingualTitle`](../../Sources/SoftLive/Cleaner/CleanModels.swift) 产出中英文标题对，界面按 [`CleanCandidate.displayTitle`](../../Sources/SoftLive/Cleaner/CleanModels.swift) 在 `MainActor` 经 `L10n.tr` 实时解析，切换界面语言无需重扫。
2. **Finder `.app` 拖拽直达（`.onDrop`）**：在「清理」页任意区域拖入 `.app` 应用包，自动调用 `DiskCleaner.inspectDroppedAppURL(_:)` 在后台校验并拆解应用本体与关联文件，并在应用列表扫描后保留外部拖入条目；若拖入系统应用、SoftLive 自身或无效包则显示明确提示。
3. **完整卸载 vs 仅重置应用数据**：
   - 在「应用卸载」右侧详情卡可一键切换 **「完整卸载」**（勾选 `.app` 本体 + 安全关联项）或 **「仅清数据」**（取消勾选 `.app` 本体，仅清理 `~/Library` 关联缓存与数据，保留应用本身）。
   - 执行时若目标应用正在运行，先通过 `NSRunningApplication.terminate()` 请求优雅退出并短暂等待进程结束；若仍未退出则经 `AppUninstallEngine.canSafelyTrash` 拦截并记入 `skippedCount`，未退出前不删除文件。

## 约束与失败行为

- **符号链接全链路隔离（不使用 `NSDirectoryEnumerator.skipDescendants()`）**：`CleanRuleEngine.isStrictDescendant(_:ofAnyRoot:)` 同时校验词法路径与 `resolvingSymlinksInPath()`，防止中间父目录符号链接逃逸出白名单；`fts_open` 启用 `FTS_PHYSICAL` 从内核/C 库层保证绝不穿透符号链接；不能在 `FileManager.default.enumerator` 遇到叶子符号链接（如 `node_modules/.bin/*`）时调用 `skipDescendants()`，否则 `NSDirectoryEnumerator` 会直接跳过父目录的剩余兄弟节点导致整个 `node_modules` 统计为 `0 KB`。
- **单次计费原则**：`~/Library/Caches` 下的 `Homebrew`、`pnpm`、`Yarn`、`bun`、`mise`、`org.swift.swiftpm`、`pip`、`uv`、`pypoetry`、`CocoaPods`、`go-build`、`typescript`、`ms-playwright`、`Cypress` 仅归入 `devCaches`，在 `appCaches` 扫描中显式跳过。
- **权限或占用失败回退与提示**：若个别目录因系统保护、文件锁或应用拒绝退出导致校验失败或 `trashItem` 抛出错误，计入 `CleanSummaryReport.skippedCount` 并继续处理其余勾选项，并在界面提示已移入数量、释放体积与跳过项数。

## 验证

- `swift test --filter DiskCleanerTests`
