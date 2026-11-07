# 界面与渲染

## 职责与事实来源

- 界面读取 [`PlaybackModel`](../../Sources/SoftLive/Playback/PlaybackModel.swift)、[`SystemMonitor`](../../Sources/SoftLive/Monitor/SystemMonitor.swift) 和 [`Preferences`](../../Sources/SoftLive/App/Preferences.swift)，通过模型方法发起播放控制、详情采样选择与结束进程；不直接访问播放器存储、采样器或网络。独立舞台的排版与特效见 [舞台模式](stage.md)。
- [`AppMenu`](../../Sources/SoftLive/App/AppMenu.swift) 是共享主菜单，两个状态栏项、右键桌面歌词/组件/舞台窗口及再次打开 App 都可访问。

## 应用图标与打包

- 正式图标采用「Sync / 同频 × 霜光」：[`AppIcon.icon`](../../Resources/Branding/AppIcon.icon/icon.json) 使用系统背景与独立的细节缎带图层，避免系统再给旧式完整底板套框。矢量图层保留柔和的曲面折返，下方前后两面使用一致的连接边界与底色；预览和独立单色标志见 [品牌资源](../../Resources/Branding/README.md)。
- [`build-app.sh`](../../Scripts/build-app.sh) 使用 Xcode `actool` 编译原生 `Assets.car` 与兼容 `AppIcon.icns`，连同状态栏位图复制到 `Contents/Resources` 后再签名；[`Info.plist`](../../Resources/Info.plist) 声明 `CFBundleIconFile` 与 `CFBundleIconName`。

## 状态栏

- [`LyricsStatusBar`](../../Sources/SoftLive/UI/StatusBar/LyricsStatusBar.swift) 显示 `PlaybackModel.headline`，最大宽度 260 pt，长句截断。关闭状态栏歌词且开启系统监控时隐藏该项，释放菜单栏空间。
- 无歌词文字时显示 18 × 18 pt 的单色 Sync 模板图标，随系统外观着色；有歌词时仅显示文字。128 × 128 px 模板由 [`BrandAssets`](../../Sources/SoftLive/UI/Branding/BrandAssets.swift) 缓存，与桌面组件共用，通过 SwiftPM 资源支持本地运行，App 打包时也复制到主资源目录。
- [`MonitorStatusBar`](../../Sources/SoftLive/UI/StatusBar/MonitorStatusBar.swift) 使用 `52 × 22 pt` 非模板图像：左侧上下两行上传/下载紧凑数值，右侧 CPU / RAM / TMP 三根语义彩色柱，温度按 `0–100 °C` 映射。文字、底轨与语义颜色适配系统外观；字体和段落样式缓存，仅在 `DisplayKey`（文本、柱高步进或颜色分段）变化时重绘。
- 左键按下打开 `.nonactivatingPanel` 承载的 [`MonitorPopoverView`](../../Sources/SoftLive/UI/StatusBar/MonitorPopover.swift)，期间状态栏按钮保持高亮；右键打开主菜单。首击直达控件，不激活 SoftLive；点击外部或按 `Esc` 收起。
- 详情页为 CPU / RAM / TMP：CPU 显示趋势、核心与 GPU 负载、Top 10 进程；RAM 显示趋势、内存构成与压力、Swap、Top 10 进程；TMP 显示趋势、部位热力、整机功耗与风扇。底栏显示完整上下行速率。数据来源、周期、按需采样和失败表现统一见 [系统监控](monitor.md)。
- 进程行先点 `✕` 再确认 `结束`，确认期间固定列表避免排序导致误点；由 `SystemMonitor.terminateProcess` 执行结束。
- 详情面板的 Liquid Glass 包裹自然高度内容，固定内边距，按内容变化调整可点击高度。视图树常驻，仅观察收起时停止更新的 `detailMetrics`，避免反复重建玻璃与布局。

## 桌面面板

[`OverlayPanel`](../../Sources/SoftLive/UI/Overlay/OverlayPanel.swift) 共用透明背景、跨桌面空间、原生拖动、首击、右键菜单与位置保存，并通过 `Observations` 同步显示、鼠标穿透和紧凑态可点击高度。`OverlayHostingView` 将右键转给菜单；固定尺寸宿主设 `sizingOptions = []`。

### 桌面歌词

[`DesktopLyrics`](../../Sources/SoftLive/UI/Overlay/DesktopLyrics.swift) 位于 `.floating` 层级，在全屏 App 上也显示。固定双行居中：上行逐字歌词，下行为翻译或下一句；空行仍保留高度。平时无背景，标准 SF Pro 字体配位图内双层阴影。

默认锁定并开启鼠标穿透。通过修饰键与鼠标释放事件判断唤醒：按住 `⌘` 移入后显示玻璃背景和暂停/继续、锁定、隐藏控制栏；鼠标仍在卡片内时，松开 `⌘` 后仍可点击、拖动或双击切下一首，移出后恢复穿透。面板不可见时事件监听立即短路并复位，观察属性仅在值变化时赋值。

### 桌面组件

[`DesktopWidget`](../../Sources/SoftLive/UI/Overlay/DesktopWidget.swift) 位于桌面图标之上、App 窗口之下，支持拖动、保存位置和双击切下一首。

- 未播放时是紧凑卡片，显示所选播放器最近曲目与封面、播放器选择和播放按钮，不保留空歌词区或进度条。
- 无封面时显示 28 × 28 pt 的单色 Sync 标志，使用次级文字色；播放器选择按钮保留各播放器自己的图标。
- 播放时展开曲目、封面、进度、双行歌词及播放/暂停、关闭按钮。关闭通过 `PlaybackModel.closePlayback()` 退出目标播放器并收起卡片。
- 进度条每秒刷新，时间用整数格式化；组件关闭时不启动 `TimelineView` 调度。

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
