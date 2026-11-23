# 界面与渲染

## 职责与事实来源

- 界面读取 [`PlaybackModel`](../../Sources/SoftLive/Playback/PlaybackModel.swift)、[`SystemMonitor`](../../Sources/SoftLive/Monitor/SystemMonitor.swift)、[`DiskCleaner`](../../Sources/SoftLive/Cleaner/DiskCleaner.swift) 和 [`Preferences`](../../Sources/SoftLive/App/Preferences.swift)，通过模型方法发起播放控制、详情采样选择、结束进程与按需空间清理；不直接访问播放器存储、采样器或网络。独立舞台的排版与特效见 [舞台模式](stage.md)，空间清理规则与安全边界见 [空间清理](cleaner.md)。
- [`AppMenu`](../../Sources/SoftLive/App/AppMenu.swift) 提供精简的右键快捷菜单（仅保留曲目短标题、桌面歌词/锁定/桌面组件/演示舞台开关、`歌词偏移` 子菜单、「配置中心… (`⌘,`)」与「退出 (`⌘Q`)」，两个状态栏项及桌面歌词/组件/舞台窗口右键均可访问）以及应用级 `NSApp.mainMenu`（使 `ControlCenterWindow` 与 `StageWindow` 聚焦时原生支持 `⌘Q` 退出、`⌘W` 关闭窗口、`⌘M` 最小化与 `⌘,` 打开配置中心）；再次打开 App、点击菜单「配置中心… (`⌘,`)」或点击监控面板底栏设置图标可打开 [`ControlCenterWindow`](../../Sources/SoftLive/UI/ControlCenter/ControlCenterWindow.swift)。
- [`L10n`](../../Sources/SoftLive/Support/L10n.swift) 提供零依赖、编译期安全的中英双语（`zh-Hans` / `en`）本地化，由 `Preferences.language`（`跟随系统 / 简体中文 / English`）驱动；切换时通过 `@Observable` 自动刷新 SwiftUI 面板、CoreText 舞台/歌词占位与 `AppMenu`，无需重启 App。[`build-app.sh`](../../Scripts/build-app.sh) 同时将 `Resources/{zh-Hans,en}.lproj/InfoPlist.strings` 拷入应用包，本地化系统自动化授权弹窗。

## 应用图标与打包

- 正式图标采用「Sync / 同频 × 霜光」：[`AppIcon.icon`](../../Resources/Branding/AppIcon.icon/icon.json) 使用系统背景与独立的细节缎带图层，避免系统再给旧式完整底板套框。矢量图层保留柔和的曲面折返，下方前后两面使用一致的连接边界与底色；预览和独立单色标志见 [品牌资源](../../Resources/Branding/README.md)。
- [`build-app.sh`](../../Scripts/build-app.sh) 使用 Xcode `actool` 编译原生 `Assets.car` 与兼容 `AppIcon.icns`，连同状态栏位图复制到 `Contents/Resources` 后再签名；[`Info.plist`](../../Resources/Info.plist) 声明 `CFBundleIconFile` 与 `CFBundleIconName`。

## 状态栏

- [`LyricsStatusBar`](../../Sources/SoftLive/UI/StatusBar/LyricsStatusBar.swift) 显示 `PlaybackModel.headline`，宽度上限由 `Preferences.statusBarWidthPreset`（`180 / 260 / 340 pt`）控制，长句截断。关闭状态栏歌词且开启系统监控时隐藏该项，释放菜单栏空间。
- 无歌词文字时显示 18 × 18 pt 的单色 Sync 模板图标，随系统外观着色；有歌词时仅显示文字。128 × 128 px 模板由 [`BrandAssets`](../../Sources/SoftLive/UI/Branding/BrandAssets.swift) 缓存，与桌面组件和舞台窗口无封面占位共用，通过 SwiftPM 资源支持本地运行，App 打包时也复制到主资源目录。
- [`MonitorStatusBar`](../../Sources/SoftLive/UI/StatusBar/MonitorStatusBar.swift) 支持两种图像样式：`网速 + 柱状图`（`52 × 22 pt`，左侧上下两行上传/下载紧凑数值 + 右侧 CPU / RAM / TMP 三根柱）与 `仅柱状图`（`20 × 22 pt`），并支持切换柱状图彩色或单色模板显示（`Preferences.monitorColoredBars`）；温度按 `0–100 °C` 映射，CPU、内存与温度告警阈值由 `Preferences` 控制。文字、底轨与语义颜色适配系统外观；字体和段落样式缓存，仅在 `DisplayKey`（样式、彩色开关、文本、柱高步进或颜色分段）变化时重绘。
- 左键按下切换 `.nonactivatingPanel` 承载的 [`MonitorPopoverView`](../../Sources/SoftLive/UI/StatusBar/MonitorPopover.swift)，展开期间状态栏按钮保持高亮；右键直接弹出主菜单。左键与右键交互均首击直达控件且不激活 SoftLive；再次点击状态栏按钮、点击卡片外或按 `Esc` 收起（消去事件监听先于按钮动作触发时的同次点击重开）。
- 详情页为 CPU / RAM / TMP：CPU 显示趋势、核心与 GPU 负载、Top 10 进程；RAM 显示趋势、内存构成与压力、Swap、Top 10 进程；TMP 显示趋势、部位热力、整机功耗与风扇。底栏显示完整上下行速率。数据来源、周期、按需采样和失败表现统一见 [系统监控](monitor.md)。
- 进程行先点 `✕` 再确认 `结束`，确认期间固定列表避免排序导致误点；由 `SystemMonitor.terminateProcess` 执行结束。
- 详情面板的 Liquid Glass 包裹自然高度内容，固定内边距，按内容变化调整可点击高度。视图树常驻，仅观察收起时停止更新的 `detailMetrics`，避免反复重建玻璃与布局。

## 桌面面板

[`OverlayPanel`](../../Sources/SoftLive/UI/Overlay/OverlayPanel.swift) 共用透明背景、跨桌面空间、原生拖动、首击、右键菜单与位置保存（恢复位置时钳制到当前已连接屏幕可见区域），并通过按值去重的 `Observations`（于 `isolated deinit` 取消）同步显示、鼠标穿透和紧凑态可点击高度。`OverlayHostingView` 将右键转给菜单；固定尺寸宿主设 `sizingOptions = []`。

### 桌面歌词

[`DesktopLyrics`](../../Sources/SoftLive/UI/Overlay/DesktopLyrics.swift) 位于 `.floating` 层级，在全屏 App 上也显示。双行居中：上行逐字歌词，下行为翻译或下一句（由 `Preferences.desktopLyricsSublineMode` 控制「翻译优先 / 仅翻译 / 单行主句」，字号由 `Preferences.desktopLyricsSize` 提供 `22 / 26 / 30 pt` 三档）；双行模式下空行仍保留高度，隐藏或无播放时卸载内部视图树。平时无背景，标准 SF Pro 字体配位图内双层阴影；控制栏标题截断而偏移步进胶囊保持固定宽度。

默认锁定并开启鼠标穿透。通过修饰键与鼠标释放事件判断唤醒：按住 `⌘` 移入后通过激活态追踪唤醒 `24 pt` 圆角单层霜光玻璃背景和 `26 pt` 统一高度的顶部控制栏（左侧显示 Sync 标志与当前曲目；中部在有歌词时将 `-0.5s` / 当前偏移 / `+0.5s` 收敛为单个步进胶囊，活跃偏移高亮使用 [`SoftLiveTheme.accent`](../../Sources/SoftLive/UI/Theme/SoftLiveTheme.swift)；右侧提供 `26 × 26 pt` 播放/暂停、穿透切换（`cursorarrow.motionlines` / `cursorarrow`）与隐藏（`eye.slash`）按钮，`11 pt .medium` 图标且 `play.fill` 带 `+1 pt` 视觉居中微调）；鼠标仍在卡片内时，松开 `⌘` 后仍可点击、拖动或双击切下一首，移出后恢复穿透。面板不可见时事件监听立即短路并复位，锁定且未唤醒时窗口外按 `⌘` 不取消穿透（不截获背景窗口的 `⌘` 点击）。

### 桌面组件

[`DesktopWidget`](../../Sources/SoftLive/UI/Overlay/DesktopWidget.swift) 位于桌面图标之上、App 窗口之下，支持拖动、保存位置和双击切下一首。

- 背景复用 [`StagePalette.cached(for:)`](../../Sources/SoftLive/UI/Stage/StagePalette.swift) 按图片对象引用缓存的封面色盘，在 `24 pt` 圆角 `.glassEffect(.regular)` 下方叠加静态封面双色环境柔光与高光描边；控件底色随系统浅色/深色外观自适应，统一使用首击直达热区（`.onTapGesture`）。
- 未播放时是 `92 pt` 高紧凑卡片，右侧采用水平布局：左侧为统一圆角矩形裁剪的 `24 × 24 pt` 播放器切换器（未选中项降低饱和度与不透明度，避免鲜艳图标喧宾夺主），右侧为带 Frost / 封面强调色的 `32 × 32 pt` 圆形播放按钮（`play.fill` 带 `+1 pt` 视觉居中微调），不保留空歌词区或进度条。
- 无封面时显示 `28 × 28 pt` 的单色 Sync 标志，使用次级文字色，进度与强调点回退到 [`SoftLiveTheme.accent`](../../Sources/SoftLive/UI/Theme/SoftLiveTheme.swift)。
- 播放时展开曲目、封面、随封面强调色着色的 `100 pt` 进度条、细分割线与双行歌词，以及 `28 × 28 pt`（`11 pt .medium`）播放/暂停与停止（`stop.fill`）按钮。停止按钮通过 `PlaybackModel.closePlayback()` 退出目标播放器并收起卡片。
- 进度条每秒刷新，时间用 `11 pt` 等宽整数格式化；组件关闭时不启动 `TimelineView` 调度。

### 桌面配置中心

[`ControlCenterWindow`](../../Sources/SoftLive/UI/ControlCenter/ControlCenterWindow.swift) 为可自由缩放的左右分栏配置窗口（默认 `780 × 680 pt`，最小尺寸限制 `740 × 640 pt`）：

- **左侧栏（`168 pt`）**：上方为原生系统设置风格的单行「播放器」「监听」与「清理」三项一级导航（配 `24 × 24 pt` 圆角图标徽标与平铺选中态），底部为带完整彩色应用图标（`BrandAssets.appIcon`）的 `SoftLive` 入口，点击后在右侧展示通用语言设置、产品说明、交互指南与架构隐私承诺。
- **右侧内容区（自适应宽度）**：顶部首个分组卡片上沿与左侧首项导航在 `y = 50 pt` 严格水平对齐，各 Tab 切换时顶部标题（`y = 28 pt`）与卡片组间距（`18 pt`）保持零跳动；采用无冗余副文案的单列分组表单（每行固定 `42 pt` 高，分段器使用 `.fixedSize` 防止文字截断）：
  - **播放器**：配置首选播放器、桌面常驻组件开关、状态栏歌词开关与最大宽度（`180 / 260 / 340 pt`）、桌面悬浮歌词开关/穿透锁定/字号（`22 / 26 / 30 pt`）/副句模式（`翻译优先 / 仅翻译 / 单行`）、演示舞台开关/律动风格（`流光 / 描金`）/星火特效。
  - **监听**：配置状态栏监控总开关、状态栏样式（`网速 + 柱状图` / `仅柱状图`）、柱状图彩色显示开关、弹窗默认页面（`CPU / RAM / TMP`）、采样间隔（`1 秒 / 2 秒 / 5 秒`）以及 CPU / 内存 / 温度三项告警阈值。
  - **清理**（[`CleanerPaneView`](../../Sources/SoftLive/UI/Cleaner/CleanerPaneView.swift)）：顶栏右侧提供「缓存与残留 / 应用卸载」双模式切换，并支持将 `.app` 直接拖入窗口自动跳转：①「缓存与残留」模式包含多色分段存储占比条、四列横向 Bento 分类卡片及自适应「扫描明细」大列表；②「应用卸载」模式采用主从双栏布局（左栏展示已安装应用图标、运行态与残留量，右栏拆解应用本体与 8 类 `~/Library` 关联文件，支持一键切换「完整卸载」或保留应用本体的「仅清数据」）。
- **生命周期**：窗口关闭时调用 `cleaner.cancelInFlightScan()` 取消未完成扫描，并将 `ControlCenterState.isOpen` 置为 `false`、隐藏宿主视图，卸载内部 SwiftUI 子树，关闭期间后台零观察开销。

## 逐字渲染

[`KaraokeText`](../../Sources/SoftLive/UI/Karaoke/KaraokeText.swift) 是 SwiftUI 包装，[`KaraokeLayerView`](../../Sources/SoftLive/UI/Karaoke/KaraokeLayerView.swift) 负责 CoreText 排版与位图、Core Animation 填色。

1. 行内容、间奏状态、尺寸、字体、颜色或屏幕缩放变化时，按 `RenderKey` 光栅化位图，并计算词的像素范围；长文本缩小至可用宽度。间奏将三枚圆点的高亮映射到三等分时间。
2. 高亮层与暗色层共用位图，分别裁剪；一条 `bounds` 关键帧动画驱动分割点。仅换行、锚点变化或重新显示时重建，暂停时固定在当前分割点，词间空档不前进。
3. 视图常驻且高度固定；入场动画与间奏呼吸都用 Core Animation。隐藏面板（含 `viewDidHide`）不光栅化、不构建并移除运行中动画；长行词范围钳制在可用宽度内并保持关键帧时间戳单调递增。

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
