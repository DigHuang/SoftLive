# 界面与渲染

## 职责与事实来源

- 界面读取 [`PlaybackModel`](../../Sources/SoftLive/Playback/PlaybackModel.swift)、[`SystemMonitor`](../../Sources/SoftLive/Monitor/SystemMonitor.swift) 和 [`Preferences`](../../Sources/SoftLive/App/Preferences.swift)，通过模型方法发起播放控制、详情采样选择与结束进程；不直接访问播放器存储、采样器或网络。独立舞台的排版与特效见 [舞台模式](stage.md)。
- [`AppMenu`](../../Sources/SoftLive/App/AppMenu.swift) 是共享主菜单，两个状态栏项及右键桌面歌词/组件/舞台窗口均可访问；再次打开 App、点击菜单「配置中心… (`⌘,`)」或点击监控面板底栏设置图标可打开 [`ControlCenterWindow`](../../Sources/SoftLive/UI/ControlCenter/ControlCenterWindow.swift)。
- [`L10n`](../../Sources/SoftLive/Support/L10n.swift) 提供零依赖、编译期安全的中英双语（`zh-Hans` / `en`）本地化，由 `Preferences.language`（`跟随系统 / 简体中文 / English`）驱动；切换时通过 `@Observable` 自动刷新 SwiftUI 面板、CoreText 舞台/歌词占位与 `AppMenu`，无需重启 App。[`build-app.sh`](../../Scripts/build-app.sh) 同时将 `Resources/{zh-Hans,en}.lproj/InfoPlist.strings` 拷入应用包，本地化系统自动化授权弹窗。

## 应用图标与打包

- 正式图标采用「Sync / 同频 × 霜光」：[`AppIcon.icon`](../../Resources/Branding/AppIcon.icon/icon.json) 使用系统背景与独立的细节缎带图层，避免系统再给旧式完整底板套框。矢量图层保留柔和的曲面折返，下方前后两面使用一致的连接边界与底色；预览和独立单色标志见 [品牌资源](../../Resources/Branding/README.md)。
- [`build-app.sh`](../../Scripts/build-app.sh) 使用 Xcode `actool` 编译原生 `Assets.car` 与兼容 `AppIcon.icns`，连同状态栏位图复制到 `Contents/Resources` 后再签名；[`Info.plist`](../../Resources/Info.plist) 声明 `CFBundleIconFile` 与 `CFBundleIconName`。

## 状态栏

- [`LyricsStatusBar`](../../Sources/SoftLive/UI/StatusBar/LyricsStatusBar.swift) 显示 `PlaybackModel.headline`，宽度上限由 `Preferences.statusBarWidthPreset`（`180 / 260 / 340 pt`）控制，长句截断。关闭状态栏歌词且开启系统监控时隐藏该项，释放菜单栏空间。
- 无歌词文字时显示 18 × 18 pt 的单色 Sync 模板图标，随系统外观着色；有歌词时仅显示文字。128 × 128 px 模板由 [`BrandAssets`](../../Sources/SoftLive/UI/Branding/BrandAssets.swift) 缓存，与桌面组件和舞台窗口无封面占位共用，通过 SwiftPM 资源支持本地运行，App 打包时也复制到主资源目录。
- [`MonitorStatusBar`](../../Sources/SoftLive/UI/StatusBar/MonitorStatusBar.swift) 支持两种图像样式：`网速 + 柱状图`（`52 × 22 pt`，左侧上下两行上传/下载紧凑数值 + 右侧 CPU / RAM / TMP 三根柱）与 `仅柱状图`（`20 × 22 pt`），并支持切换柱状图彩色或单色模板显示（`Preferences.monitorColoredBars`）；温度按 `0–100 °C` 映射，CPU、内存与温度告警阈值由 `Preferences` 控制。文字、底轨与语义颜色适配系统外观；字体和段落样式缓存，仅在 `DisplayKey`（样式、彩色开关、文本、柱高步进或颜色分段）变化时重绘。
- 左键按下切换 `.nonactivatingPanel` 承载的 [`MonitorPopoverView`](../../Sources/SoftLive/UI/StatusBar/MonitorPopover.swift)，展开期间状态栏按钮保持高亮；右键打开主菜单。首击直达控件，不激活 SoftLive；再次点击状态栏按钮、点击卡片外或按 `Esc` 收起（消去事件监听先于按钮动作触发时的同次点击重开）。
- 详情页为 CPU / RAM / TMP：CPU 显示趋势、核心与 GPU 负载、Top 10 进程；RAM 显示趋势、内存构成与压力、Swap、Top 10 进程；TMP 显示趋势、部位热力、整机功耗与风扇。底栏显示完整上下行速率。数据来源、周期、按需采样和失败表现统一见 [系统监控](monitor.md)。
- 进程行先点 `✕` 再确认 `结束`，确认期间固定列表避免排序导致误点；由 `SystemMonitor.terminateProcess` 执行结束。
- 详情面板的 Liquid Glass 包裹自然高度内容，固定内边距，按内容变化调整可点击高度。视图树常驻，仅观察收起时停止更新的 `detailMetrics`，避免反复重建玻璃与布局。

## 桌面面板

[`OverlayPanel`](../../Sources/SoftLive/UI/Overlay/OverlayPanel.swift) 共用透明背景、跨桌面空间、原生拖动、首击、右键菜单与位置保存，并通过 `Observations` 同步显示、鼠标穿透和紧凑态可点击高度。`OverlayHostingView` 将右键转给菜单；固定尺寸宿主设 `sizingOptions = []`。

### 桌面歌词

[`DesktopLyrics`](../../Sources/SoftLive/UI/Overlay/DesktopLyrics.swift) 位于 `.floating` 层级，在全屏 App 上也显示。双行居中：上行逐字歌词，下行为翻译或下一句（由 `Preferences.desktopLyricsSublineMode` 控制「翻译优先 / 仅翻译 / 单行主句」，字号由 `Preferences.desktopLyricsSize` 提供 `22 / 26 / 30 pt` 三档）；双行模式下空行仍保留高度。平时无背景，标准 SF Pro 字体配位图内双层阴影。

默认锁定并开启鼠标穿透。通过修饰键与鼠标释放事件判断唤醒：按住 `⌘` 移入后显示单层霜光玻璃背景和顶部控制栏（左侧显示 Sync 标志与当前曲目，中部在有歌词时提供 `±0.5s` 偏移与重置胶囊，右侧提供 `28 × 28 pt` 播放/暂停、锁定、隐藏按钮）；鼠标仍在卡片内时，松开 `⌘` 后仍可点击、拖动或双击切下一首，移出后恢复穿透。面板不可见时事件监听立即短路并复位，观察属性仅在值变化时赋值。

### 桌面组件

[`DesktopWidget`](../../Sources/SoftLive/UI/Overlay/DesktopWidget.swift) 位于桌面图标之上、App 窗口之下，支持拖动、保存位置和双击切下一首。

- 背景复用 [`StagePalette.cached(for:)`](../../Sources/SoftLive/UI/Stage/StagePalette.swift) 按图片对象引用缓存的封面色盘，在 `.glassEffect(.regular)` 下方叠加静态封面双色环境柔光与高光描边；控件底色随系统浅色/深色外观自适应，统一使用 `28 × 28 pt` 首击直达热区（`.onTapGesture`）。
- 未播放时是紧凑卡片，显示所选播放器最近曲目与封面、播放器选择和播放按钮，不保留空歌词区或进度条。
- 无封面时显示 28 × 28 pt 的单色 Sync 标志，使用次级文字色；播放器选择按钮保留各播放器自己的图标。
- 播放时展开曲目、封面、随封面强调色着色的进度条、细分割线与双行歌词，以及播放/暂停、关闭按钮。关闭通过 `PlaybackModel.closePlayback()` 退出目标播放器并收起卡片。
- 进度条每秒刷新，时间用 `11 pt` 等宽整数格式化；组件关闭时不启动 `TimelineView` 调度。

### 桌面配置中心

[`ControlCenterWindow`](../../Sources/SoftLive/UI/ControlCenter/ControlCenterWindow.swift) 为 `640 × 636 pt` 左右分栏配置窗口，禁用最大化按钮：

- **左侧栏（`168 pt`）**：上方为原生系统设置风格的单行「播放器」与「监听」导航项（配 `24 × 24 pt` 圆角图标徽标与平铺选中态），底部为带完整彩色应用图标（`BrandAssets.appIcon`）的 `SoftLive` 入口，点击后在右侧展示通用语言设置、产品说明、交互指南与架构隐私承诺。
- **右侧内容区（`464 pt`）**：采用无冗余副文案的单列分组表单（每行固定 `34 pt` 高，分段器使用 `.fixedSize` 防止文字截断）：
  - **播放器**：配置首选播放器、桌面常驻组件开关、状态栏歌词开关与最大宽度（`180 / 260 / 340 pt`）、桌面悬浮歌词开关/穿透锁定/字号（`22 / 26 / 30 pt`）/副句模式（`翻译优先 / 仅翻译 / 单行`）、演示舞台开关/律动风格（`流光 / 描金`）/星火特效。
  - **监听**：配置状态栏监控总开关、状态栏样式（`网速 + 柱状图` / `仅柱状图`）、柱状图彩色显示开关、弹窗默认页面（`CPU / RAM / TMP`）、采样间隔（`1 秒 / 2 秒 / 5 秒`）以及 CPU / 内存 / 温度三项告警阈值。
- **生命周期**：窗口关闭时 `ControlCenterState.isOpen` 置为 `false` 并隐藏宿主视图，卸载内部 SwiftUI 子树，关闭期间后台零观察开销。

## 逐字渲染

[`KaraokeText`](../../Sources/SoftLive/UI/Karaoke/KaraokeText.swift) 是 SwiftUI 包装，[`KaraokeLayerView`](../../Sources/SoftLive/UI/Karaoke/KaraokeLayerView.swift) 负责 CoreText 排版与位图、Core Animation 填色。

1. 行内容、间奏状态、尺寸、字体、颜色或屏幕缩放变化时，按 `RenderKey` 光栅化位图，并计算词的像素范围；长文本缩小至可用宽度。间奏将三枚圆点的高亮映射到三等分时间。
2. 高亮层与暗色层共用位图，分别裁剪；一条 `bounds` 关键帧动画驱动分割点。仅换行、锚点变化或重新显示时重建，暂停时固定在当前分割点，词间空档不前进。
3. 视图常驻且高度固定；入场动画与间奏呼吸都用 Core Animation。隐藏面板不光栅化、不构建动画。

## 约束与失败行为

- 不逐帧驱动歌词。原 SwiftUI `TextRenderer` 的 30 fps 重排版方案在双窗口场景实测 CPU 9–14%，已改为 Core Animation。
- 桌面组件不用持续动画的系统控件；此前一个带 `symbolEffect` 的图标就曾占用约 15% CPU。玻璃放在静态背景，避免跟随歌词重算。
- 不用 WidgetKit，其刷新频率不适合实时歌词，桌面组件因此不出现在系统小组件库。
- 菜单栏被刘海或其他图标挤满时，macOS 可能隐藏状态栏项；使用上面的其他主菜单入口。
- Liquid Glass 实际屏幕效果尚未验证，现有验证仅覆盖离屏布局。
- 性能实测仅覆盖同时开启桌面歌词和桌面组件、播放逐字歌词的场景：CPU 0–0.8%。此数据不覆盖舞台窗口。

## 验证

- `swift test --filter KaraokeLayerViewTests`
- 真实交互与性能验证要求见 [代码规范](../code-standards.md#验证)。
