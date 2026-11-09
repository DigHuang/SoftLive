# 经验教训

SoftLive 的代码由 agent 编写和验证。每当有改动需要返工、结论下错，或验证做得太浅，就在这里记下来。
**改代码之前先读一遍。**

- **格式**：每条都是「规则」，然后是原因和证据。「出现」记录在几轮不同的工作里遇到过。
- **毕业**：同一条出现满 3 次，就并入 [docs/code-standards.md](docs/code-standards.md)，并从这里删掉。
- **清理**：已经被代码或规范彻底杜绝、不可能再犯的条目，直接删掉。

## 分支与交付

**独立任务使用独立分支；当前分支已有其他任务的工作或已合入时，从最新目标分支新建分支再提交 PR；切分支重新打包前核对本机运行版是否含未合入 `main` 的本地修复。**
- 2026-11-06，舞台功能已通过 PR 合入 `main`，但本轮清理仍沿用 `feat/stage-mode`，并为对齐目标分支生成合并提交、处理重复引入的内容后创建 PR。用户明确指出应另开分支；改为从最新 `main` 新建清理分支，仅迁移本轮改动并替换 PR。创建 PR 前要核对任务归属与分支是否已合入，不能仅检查是否有打开的 PR。
- 2026-11-08，状态栏二次点击收起修复（`35f9697`）此前仅提交在本地分支 `fix/monitor-popover-second-click` 并打包进 `build/SoftLive.app`，其教训已随 PR #13 合入 `main` 但代码提交本身未合入 `main`。从 `main` 切新分支并运行 `Scripts/build-app.sh --run` 后，把未合入 `main` 的状态栏修复覆盖回旧逻辑，导致状态栏点击收起失效。已将 `35f9697` 补入当前分支并验证测试。
- 出现 2 次。

## 数据与判断

**直接扫描二进制日志文件或调用内核 IOKit 结构体接口时，必须核对底层容器的分块边界与 C 结构体字节对齐。**
- LevelDB 的 `.log` 文件按 32 KiB（`32768` 字节）分块，跨块记录会在 `offset % 32768 == 0` 处插入 7 字节的块续写头（`crc32 + length + type`）。`lastPlaying` 只有 265 字节很少跨块，但 `playingInfo` 约 13 KB，约 40% 的记录会跨 32 KiB 边界；未跳过 7 字节块头会导致 Base64 解码失败并漏掉状态变化。
- `AppleSMC` 内核驱动的 `IOConnectCallStructMethod(selector: 2)` 要求输入/输出 `SMCKeyData_t` 精确为 80 字节。在 C 头文件中，嵌套子结构体 `keyInfo_t`（`UInt32 + UInt32 + UInt8 = 9` 字节）因 4 字节对齐自动补齐到 12 字节；而在 Swift 中直接把字段扁平展开后，紧跟其后的 `result: UInt8` 会填进原本的对齐空隙，导致整个结构体变成 76 字节并报 `kIOReturnBadArgument`。必须在 `keyInfo` 字段后显式补齐 3 字节填充并用 `MemoryLayout<SMCKeyData>.size == 80` 验证。
- `proc_name(pid, ...)` 只读取内核在 `execve()` 时写入的 `p_comm`（如 `"node"`），而 Node.js / Next.js 等工具修改 `process.title = "next-server (v16.3.6)"` 改写的是用户态栈上的 `argv[0]`。若只查 `proc_name` 并按 PID 永久缓存，会把所有 Next.js / CLI 子进程都显示成无区分度的 `"node"`；必须通过 `sysctl([CTL_KERN, KERN_PROCARGS2, pid])` 读取 `argv` 并结合 `proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, ...)` 的工作目录名（如 `next-server (app)` vs `next-server (admin)`）进行区分。
- 出现 2 次。

**引入暂停状态后，所有把“墙钟经过时间（`now - start`）”当作“已播放时长”的判断都要同步修正。**
- 加入暂停/继续后，`NetEaseSource` 原有的两处逻辑仍假设歌曲从未暂停：`publish` 用 `now - start > duration + 5` 丢弃过期会话，`isNewPlay` 用 `latest.start - play.start >= duration` 判断同曲重播。若一首歌中途暂停了几分钟再恢复（或暂停期间重启 App 再恢复），墙钟时间已超过曲目时长，会导致恢复播放后被当成过期会话丢弃（且因 `play == latest` 卡死在 `state == nil`）或误判为从头重播；暂停状态下拖动进度条写出的单条 `lastPlaying` 也会被 `position != previous.position` 误判为恢复播放。必须区分“正在播放 vs 静止过期”、用计入暂停的 `state.position(at:)` 判断是否播完，并在收到 `playingState = 1` 明确暂停后抑制单条 `lastPlaying` 的假恢复。
- 出现 1 次。

**异步派生的缓存值必须在源键更新的同一同步帧清空，且异步任务句柄在完成后必须立即归零。**
- `PlaybackModel.updateRecentTrack` 在切歌时先把 `recentTracks[kind]` 更新为新曲目 B，却未同步清空 `recentArtworks[kind]`（仍留着曲目 A 的旧封面）；紧接着同帧执行的 `loadArtwork(for: B)` 检查 `recentTracks[kind] == B` 命中后直接复用了尚未被覆盖的旧封面 A，导致每次切歌后桌面组件显示的封面都滞后一首。
- 同一处 `recentArtworkTasks[kind]` 在异步任务结束后未置回 `nil`；当首次封面拉取返回 `nil`（如网络瞬断或播放器 `state` 尚未就绪）时，后续 `loadArtwork` 因 `recentArtworkTasks[kind] != nil` 永久短路，导致播放期间不再重试加载封面。
- 出现 2 次。

**觉得功能“没生效”时，先看输入里有没有它需要的数据，再查代码。**
- 用户说看不到逐字效果。查下来，最近播放的几首歌在网易云上本来就没有逐字数据（普通接口和加密接口都没有），代码没问题。
- 出现 1 次。

**时序模型要从实测样本推出来，且不能拿自身含偏差的参考系当真值。**
- `ProgressCalibration` 第一版把 `.info` 缓存文件创建时间当成真音频 `0.0s` 起点，测出 `lastPlaying` 落盘时刻比 `(now - cacheStart)` 小 `0.66–1.68` 秒，于是设 `window = 2.0`。
- 用户反馈“歌词比音乐快一点”后核查实时日志发现：`.info` 是在网络请求刚发起时创建的，比音频缓冲解码后实际出声早 `0.5–2.0` 秒（无损音质 `4999` 尤为明显）；而由相邻两次落盘仅隔 `1.032s` 却从 `226s` 跳到 `228s` 可直接证明，落盘时刻的真实音频进度其实只在 `[n, n + 1.2)` 秒内。旧的 `window = 2.0` 把 `.info` 的提前量当成了 `lastPlaying` 的滞后量，导致每首歌初期超前 `0.5–0.8` 秒时落在 `[n, n + 2.0)` 窗口内永不修正（或只修正到窗口中点，恒定超前约 `0.5–0.7` 秒）。将 `window` 缩窄为 `1.2` 后，开播前两次 `lastPlaying` 即可滤掉缓冲耗时、把误差收敛到 `0.1` 秒内。
- 出现 2 次。

**按分段子串的 UTF-16 长度在整行文本上推进游标时，整行文本不能单独做裁剪或改写。**
- `YRCParser` 曾对 `words.map(\.text).joined()` 做了 `.trimmingCharacters(in: .whitespaces)`，但 `words` 保留了原始分词；当行首含空格词时，`KaraokeLayerView` 在 `CTLine` 上的 UTF-16 游标整体右偏，导致整行逐字高亮错位。
- 出现 1 次。

**对目录 URL 做路径前缀白名单校验、遍历含软链的目录树或过滤运行中应用缓存时，必须剥除路径末尾 `/`、使用 `fts_open(FTS_PHYSICAL)` 替代对叶子软链调用 `NSDirectoryEnumerator.skipDescendants()`，并在 Git 仓库根级判定 monorepo 活跃度。**
- 2026-11-09 实现 `CleanRuleEngine` 时：① `URL.appending(path:directoryHint: .isDirectory).standardizedFileURL.path(percentEncoded: false)` 返回带末尾 `/` 的路径，直接拼接 `root + "/"` 变成双斜杠 `//` 导致 `canSafelyTrash` 误拒合法目录；② 本机运行中的飞书（`com.electron.lark`）在 `~/Library/Caches` 下使用产品词根派生名 `LarkShell`，仅按完整 Bundle ID 匹配会漏过；③ 在 `FileManager.default.enumerator` 遍历 `node_modules` 遇到 `.bin/*` 叶子符号链接时调用 `enumerator.skipDescendants()`，导致 `NSDirectoryEnumerator` 直接中止父目录 `node_modules` 的剩余遍历并返回 `0 MB`；④ 递归扫描 monorepo 子目录（如 `FastGPT-1/projects/*`）时未在顶层 `.git` 仓库根拦截活跃仓库，导致把昨天刚提交过的 monorepo 子包误判为闲置项目；⑤ `NSHostingView` 设 `sizingOptions = []` 时会在每次布局过程把宿主 `NSWindow` 的 `minSize` / `contentMinSize` 重置为 `(0, 0)`，导致用户可把窗口缩到最小尺寸以下产生上下裁切，必须在 `NSWindow` 子类中重写 `minSize` / `contentMinSize` 属性与 `windowWillResize`。统一改为 `canonicalPath`、产品词根前缀匹配、`fts_open(FTS_PHYSICAL | FTS_NOCHDIR)` 硬链去重统计、`.git` 根级活跃短路及重写窗口最小尺寸属性后全部修复。
- 出现 1 次。

## 边界与方案

**提议方案之前，先判断它是否在绕过保护：看被绕开的是什么，而不是手段像不像破解。**
- 第一轮的方案推荐了借 `/usr/bin/perl` 读 MediaRemote，实现时才发现这是绕过系统权限检查，改为各播放器单独接入。
- 第一次讨论拖动同步时，又把解密 `lastPlaying` 也当成绕过保护拒绝了。
  其实它只是网易云对用户自己本地数据的混淆，不涉及系统权限、账号或版权保护，后来重新判断并采用。
- 判断标准已经写进 [docs/code-standards.md](docs/code-standards.md)。
- 出现 2 次。

**说“做不到”或提出手动替代方案之前，先查开源项目有没有解决过。**
- 拖动同步第一次调查后，结论是自动方案不可行，提出用滚轮手动对齐。
  用户要求联网查，才发现 CloudLyrics-for-macOS 已经在读 `lastPlaying`。
- 出现 1 次。

**引入外部规范、GitHub Actions 或依赖项时，必须实时查询最新正式版本，不能凭记忆直接写旧版本号。**
- 2026-11-07 编写 `CHANGELOG.md` 与 `.github/workflows/ci.yml` 时，直接按训练记忆写成了 `Keep a Changelog 1.1.0`、`actions/checkout@v4` 和 `actions/cache@v4`。实时检索官网与 GitHub Releases 后确认当前最新正式版分别为 `Keep a Changelog 2.0.0`、`actions/checkout@v7`（`v7.0.1`）和 `actions/cache@v6`（`v6.1.0`），随后全部返工升级。
- 出现 1 次。

## 验证

**SwiftUI 的 `.glassEffect` 是窗后背景采样材质，不能用于不透明画布窗口内部的悬浮 HUD；嵌套胶囊必须使用等距内边距保持共心圆弧。**
- 2026-11-08，在 `StageWindow` 内部的顶部/底部 HUD 上套用 `.glassEffect(.regular)`，且未给窗口固定 `darkAqua` 外观。由于 `.glassEffect` 底层采样的是窗口背后的桌面/其他浅色窗口而非同窗口内的深色 `StageCanvasView`，在系统浅色外观下把深色舞台上的 HUD 渲染成发白发灰的塑料条；同时外层胶囊使用非等距内边距（`horizontal: 8, vertical: 5`）包内层亮色胶囊、左上角胶囊内又叠一层带描边圆钮，再加切歌按钮误用快进图标 `forward.fill`（`⏩`），导致 5 处视觉比例失调。改为窗口固定 `darkAqua`、舞台内部 HUD 使用深色半透明层与等距 `4 pt` 共心内边距、切歌统一用 `forward.end.fill`（`⏭`）。
- 出现 1 次。

**检查小尺寸透明图形时，不要把“必须存在 Alpha = 255 的像素”当成有效渲染的条件。**
- 2026-11-07 导出第二轮 logo 的 16 px PNG 时，验证脚本要求透明通道极值精确为 `(0, 255)`，误拒绝了经过抗锯齿的细线和小圆点。小图中的形状可能没有覆盖任何一个完整像素；应分别检查尺寸、透明背景、非空内容，并在实际尺寸下核对清晰度。本轮已修正检查，且明确记录波形与点阵方向在 16 px 下的细节损失。
- 出现 1 次。

**批量提取或重命名按完整标识符替换，语法解析不能代替真实编译与测试。**
- 2026-11-06 拆分舞台渲染时，替换类型名 `WordPose` 连带改坏了包含该子串的 `applyWordPoseTimeline`，生成 `applyStageWordAnimation.PoseTimeline`。`swiftc -frontend -parse` 能接受语法，但 `swift test` 的类型检查立即报找不到符号；改为 `StageWordAnimation.applyWordPoseTimeline` 后再跑全部测试与 Release 编译。
- 出现 1 次。

**性能要在用户真实的使用场景里测，并用采样定位开销，不要只测一个窗口或凭经验猜。**
- 加入桌面组件时，测到 CPU 15–20%，去掉持续动画的波形图标后报告 0.5–6%。
  但用户在双窗口、逐字歌词播放时仍觉得异常；在同样场景下实测是 9–14%。
  用 `sample` 定位到 `TextRenderer` 每帧都对整行重新排版，改成 Core Animation 后降到 0–0.8%。
- 出现 2 次。

**隐藏 `NSPanel` 或 `contentView` 不会自动停止 `NSHostingView` 的观察和 `TimelineView` 调度；但频繁开关的弹窗不要用 `if/else` 销毁整棵视图树与 `.glassEffect`，而应隔离 `@Observable` 数据源。**
- 默认关闭的桌面组件虽然被 `orderOut` 且 `contentView.isHidden = true`，但 `NSHostingView` 仍保持挂载，每句歌词切换时后台仍在做 CoreText 位图光栅化和 Core Animation 构建，且进度条 `TimelineView` 仍在每秒唤醒。
- `MonitorPopoverView` 曾为了防止后台重算而在 `body` 顶层写 `if monitor.isDetailActive { ... } else { Color.clear }`，结果每次关闭弹窗都会把整棵 SwiftUI 视图树、27 个 `GeometryReader` 和 `.glassEffect` 毛玻璃图层全部销毁，每次点击打开弹窗时主线程又必须从零重建整棵视图树与毛玻璃层，造成打开瞬间 CPU 飙高。将状态栏快照 `metrics` 与弹窗快照 `detailMetrics`（仅在弹窗展开时更新）拆开后，`MonitorPopoverView` 保持常驻挂载且只观察 `detailMetrics`（并用固定尺寸替代 27 个 `GeometryReader`），收起时后台 0 重算、打开时 0 重建开销。
- 出现 2 次。

**高频进度事件或拖动校对路径上，不能顺带执行全量磁盘/SQLite 扫描或全字段跨进程 IPC。**
- `NetEaseSource.reported(_:)` 每 1.8 秒收到一条同曲目的 `lastPlaying` 进度汇报时都会无条件调用 `reload()`，触发主线程同步打开读取 `sqlite_storage.sqlite3` 并遍历 `online_play_cache` 目录；`AppleMusicSource` 每 2 秒校对拖动时也调用完整 `refresh()` 发起 8 次同步 ScriptingBridge AppleEvent IPC。播放期间只需在曲目变化时 `reload()`（并对缓存目录按 `contentModificationDateKey` 做内存缓存），Apple Music 拖动校对只需单次读取 `playerPosition`。
- 出现 1 次。

**性能结论必须标明适用场景，前后对比要在相同条件下测。**
- 优化 CPU 那一轮报告内存从 87.7 MB 降到 23.6 MB，但两个数字分别是启动后约 6 秒和约 1 秒采到的，不能比较；后来已更正。
- 加入独立舞台后，README 仍把此前仅开启桌面歌词与桌面组件测得的 `0–0.8% CPU` 写成整个 App 的播放性能。2026-11-06 审查时将其限定回原场景，并明确舞台性能待测；增加窗口与渲染风格后不能沿用旧测量结论。
- 出现 2 次。

**`NSWindow.ignoresMouseEvents = true` 不会阻止 SwiftUI `.onHover` 触发；全局事件监听必须在面板不可见时短路，且只在值变化时写入 `@Observable` 属性。**
- SwiftUI 的 `.onHover` 底层使用 `NSTrackingArea(.activeAlways)`，即使窗口开启了 `ignoresMouseEvents = true`（鼠标点击穿透），鼠标划过窗口时 `.onHover` 依然会触发 `true`。因此悬停态 UI（如桌面歌词毛玻璃背景与控制栏）必须同时判断 `!desktopLyricsLocked`，并在点击锁定按钮时立即将唤醒态置为 `false`。
- `NSEvent` 的 `.flagsChanged` 会在按下任意修饰键或方向键时触发，且 `@Observable` 属性每次赋值（哪怕新旧值相等）都会触发 `withMutation` 唤醒 `Observations`。若 `LyricsInteraction` 未在 `!panel.isVisible` 时短路、或未判断新旧值不等再写入，会导致隐藏状态下按任意修饰键仍在后台高频触发观察循环，甚至在鼠标偶经隐藏面板区域按 `⌘` 时提前把 `isAwake` 置为 `true`。
- 出现 2 次。

**使用 `NSEvent` 监听点击外部收起状态栏 `.nonactivatingPanel` 弹窗时，必须处理监听回调先于 `NSStatusBarButton.action` 触发的同次点击重开。**
- 在 macOS 26 的 `NSSceneStatusItem` 下，状态栏项由系统菜单栏场景承载并包含多个变体窗口（`Presentation` / `ActiveSnapshot` / `InactiveSnapshot`），且 `.nonactivatingPanel` 展开时应用仍处于非激活态。用户第二次点击状态栏图标关闭弹窗时，`globalMonitor` 或 `localMonitor` 会先于 `NSStatusBarButton` 的 `statusItemClicked` 收到 `.leftMouseDown` 并调用 `dismiss()` 将 `panel.isVisible` 置为 `false`；紧接着同一次点击触发 `statusItemClicked` 时看到 `panel.isVisible == false`，误走打开分支把弹窗重新打开。此外弹窗四周波纹阴影留出的 `14 pt` 透明边距顶部有 `8 pt` 与菜单栏重叠，`hitTest` 与 `localMonitor` 必须按卡片实际内框判定，并在 `handleLeftClick` 中消费刚由外部点击监听触发的收起记录，防止同一次点击把刚收起的弹窗重新打开。
- 出现 1 次。

**周期性状态栏采样与弹窗详情采样必须避免全量跨进程 IPC、全字典 IORegistry 序列化、缓存穿透以及把开窗渲染耗时计入自身进程 CPU。**
- 第一版 `ThermalSampler.sample()` 每秒对全部 14 个 `PMU tdie*` 传感器调用 `IOHIDServiceClientCopyEvent`（底层走 `io_hideventsystem_copy_event_for_service` → `hidd` Mach IPC），同时 `MonitorStatusBar` 每秒无条件赋值 `item.isVisible = true` 和 `item.length`（在 macOS 26 的 `NSSceneStatusItem` 上触发 `FrontBoardServices` 场景同步）并重建字体字典与 `NSImage`，导致单状态栏监控就占用 1–4% CPU。改为只保留 1 个主传感器句柄且每 3 拍查 1 次、缓存 `static let` 字体与段落样式、仅在 `item.isVisible` 变化时写入，并按 `DisplayKey` 去重重绘后，平时后台降至约 0.14% CPU。
- 打开详情弹窗时，曾无条件同时采样 `CPU / RAM / TMP` 三个标签页的全部详情（含 20+ 个温度传感器的 Mach IPC 与 SMC 调用），`GPUSampler` 每次调用 `IORegistryEntryCreateCFProperties` 序列化整个 `IOAccelerator` 注册表大字典（单次耗费 `1.05 ms` CPU），`ProcessSampler.resolveMeta` 对名字仍为 `"zsh"`/`"node"` 的通用进程拒绝写入 `metaCache` 导致每次都重复调用 `KERN_PROCARGS2` 与 `PROC_PIDVNODEPATHINFO`，且 `setDetailActive(true)` 在 `t = 0`（开窗渲染前）与 `t = 320 ms`（开窗渲染后）连跑两次采样，把开窗那一瞬间的渲染开销除以 `0.32s` 放大成 `SoftLive 15%–25%` 的假峰值。改为按当前 `activeTab` 按需采样、`GPUSampler` 缓存服务句柄并单查 `"PerformanceStatistics"`（降至 `0.016 ms`，快 65 倍）、`metaCache` 缓存全部已解析 PID，并在窗口首帧提交完成（`60 ms`）后再重置 `captureBaseline()`，彻底消除了打开弹窗时的 CPU 尖峰。
- 出现 2 次。

**和其他 App 交互，不能顺带把它启动起来。**
- 退出 Music 后，它会被 SoftLive 重新拉起：Music 退出时仍会发 `playerInfo` 通知，而按 bundle ID 创建的 `SBApplication` 一查询就会启动目标。
  改为按正在运行的进程的 PID 创建。
- 出现 1 次。

**测试会动到用户正在用的 App 时，先想好怎么恢复，并告诉用户。**
- 测试时打开过网易云，它启动后自动开始播放。当时调低音量，测完暂停、恢复音量、退出，并在回复里写明。
- 现在的规则：不操作用户的播放器。
- 出现 1 次。
