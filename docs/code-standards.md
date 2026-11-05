# 代码规范

写代码和审查改动都以此为准。其中一部分来自用户的明确要求，一部分是 [LESSONS.md](../LESSONS.md) 里反复出现过的教训。
子系统行为的描述方式和更新规则，见 [子系统参考](subsystems/README.md)。

## 改动的内容

| 规则 | 审查时看什么 |
| --- | --- |
| 只做目标需要的改动，不写冗余逻辑，不留死代码。 | 每处行为变化都有理由；同一件事只有一份实现（例如文件监听统一用 `FileWatcher`，歌曲 JSON 统一用 `NetEaseSong`）。用户在第一版就提出过这个要求 |
| 遵守模块边界。 | `Playback/` 只产出 `PlaybackState` 并由 `PlaybackModel` 编排；`Lyrics/`（含 `Providers/`、`Parsers/`）不碰界面和播放器；`Monitor/` 只采样内核与 IOKit 指标并产出 `SystemMetrics`；`Support/` 放通用基础设施（`HTTPClient`、`FileWatcher`、`Log`）；`UI/` 只读 `PlaybackModel`、`SystemMonitor`、`Preferences`。新的播放器放在 `Playback/<Name>/` |
| 事件驱动，不轮询。 | 播放进度靠锚点外推，切行用单次定时器，逐字效果用 Core Animation。连续变化的系统指标（`SystemMonitor`）用 2 秒周期采样（弹窗关闭时仅查 1 个主传感器，详情仅在弹窗展开时按需采样），且关闭显示时必须停止定时器 |
| 隐藏的界面不做后台工作。 | `NSHostingView` 在窗口 `orderOut` 或 `isHidden` 时仍会响应 `@Observable` 更新；隐藏面板里的位图渲染（`!isHiddenOrHasHiddenAncestor`）和 `TimelineView` 调度必须短路。固定尺寸面板的 `NSHostingView` 设 `sizingOptions = []` |
| 非激活悬浮面板（`.nonactivatingPanel`）的点击交互必须支持首击直达且不触发应用激活。 | 状态栏弹窗或桌面悬浮窗不得在左键点击时调用 `NSApp.activate()`（在刘海屏上切换前台菜单栏会导致状态栏图标跨刘海跳变）；宿主 `NSHostingView` 必须重写 `acceptsFirstMouse(for:) -> true`，且面板内的 SwiftUI 切换/按钮优先使用 `.contentShape(Rectangle()).onTapGesture`（避免 `NSApp.isActive == false` 时 `Button` 忽略首击） |
| 用 Swift 6.2 原生特性减少样板代码。 | `Package.swift` 已开启 `.defaultIsolation(MainActor.self)`，不在类型和普通方法上重复标 `@MainActor`；需要析构清理时用 `isolated deinit`，不加 `nonisolated(unsafe)`；正则统一用 `static let` 原生 `Regex` 字面量，不用 `NSRegularExpression` 字符串桥接 |
| 不绕过系统权限。 | 不借用系统二进制的授权（例如用 `/usr/bin/perl` 加载 `mediaremote-adapter` 读 MediaRemote），不碰沙盒、TCC、账号或版权保护。读取一个 App 对**用户自己本地数据**做的混淆（例如网易云的 `lastPlaying`）可以，但只读 |
| 其他 App 的数据只读，其他 App 或外部数据格式的行为以本机真实样本实测为准，不能凭字面含义假设字段承诺。 | 不写网易云的数据库、缓存、LevelDB。在一个数据源或歌词/日志字段上建功能前，必须先用本机真实样本核对（例如：`historyTracks` 后台漏写/晚写、`IsRunningOutput` 暂停后恒为 `1`、网易云 LRC 空时间标签常在开唱后 `0.3–0.7s` 作为分段空行打点而非句尾、YRC 行头 `durationMs` 常跨间奏拉通到下一句起点），并将实测结论写进对应子系统页面 |
| 和其他 App 交互不能把它启动起来。 | 绑定到正在运行的进程（例如按 PID 创建 `SBApplication`），不要用会自动启动目标的接口 |
| 保留与改动无关的注释和文档注释。 | 代码注释用英文，文档用中文 |

## 验证

| 规则 | 审查时看什么 |
| --- | --- |
| 跑全部测试。 | `swift test` 全部通过。纯逻辑（解析、判定、校准）都要有单元测试，用例尽量取自真实数据 |
| 新增或修改交互入口必须在真实运行进程上触发点击并抓图查验。 | 按钮、标签页切换、URL Scheme 唤起、状态栏弹窗等交互改动，不能只跑单元测试；必须启动 App 后在真实窗口上触发点击、核对点击前后窗口坐标与状态，并通过位图渲染核验每一页真实画面 |
| 改动界面或播放状态后，在真实场景下测 CPU。 | 同时开启桌面歌词和桌面组件，播放带逐字歌词的歌，用 `top` 测；需要定位时用 `sample`。目标：播放时 ≤ 1% |
| 前后对比要在相同条件下测。 | 相同场景、相同时长、启动后相同时间点。测不了的写明测不了 |
| 写明验证到了什么、没验证到什么。 | 只验证过离屏渲染、没测到真实播放的，要写明。不能把推测写成结论 |
| 测试时不打扰用户。 | 不操作用户正在用的播放器（播放、暂停、切歌、音量）。必须操作时先说明，结束后恢复原状，并在回复里写明 |

## 文档

| 规则 | 审查时看什么 |
| --- | --- |
| 行为变了，在同一改动里更新对应子系统页面。 | 见 [子系统参考](subsystems/README.md) 的维护规则 |
| 需求变了，更新 [requirements.md](requirements.md)。 | 直接在原文上改，状态写现在的；过时的需求直接删掉 |
| 出了值得记住的错，写进 [LESSONS.md](../LESSONS.md)。 | 写成「规则 → 原因 → 证据」，并记录出现次数 |
