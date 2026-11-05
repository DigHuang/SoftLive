# 界面与渲染

## 职责与事实来源

- **只读数据与快捷控制**：界面只读取 [`PlaybackModel`](../../Sources/SoftLive/Playback/PlaybackModel.swift)、[`SystemMonitor`](../../Sources/SoftLive/Monitor/SystemMonitor.swift) 和 [`Preferences`](../../Sources/SoftLive/App/Preferences.swift)，并通过 `PlaybackModel.play(_:)`、`togglePlayPause()`、`nextTrack()`、`closePlayback()` 控制播放与收起，不直接接触播放器内部实现、内核采样器或网络。
- **状态栏歌词**：[`LyricsStatusBar`](../../Sources/SoftLive/UI/StatusBar/LyricsStatusBar.swift) 显示 `PlaybackModel.headline`，最大宽度 260 pt，长句尾部截断；当用户在菜单中关闭「状态栏歌词」且「显示状态栏监控」已开启时，自动隐藏该状态栏项（`isVisible = false`），节省刘海屏菜单栏空间。
- **状态栏系统监控**：[`MonitorStatusBar`](../../Sources/SoftLive/UI/StatusBar/MonitorStatusBar.swift) 是独立的状态栏项（`variableLength` 紧凑图像宽度 `52 × 22 pt`），用单张非模板图像（`isTemplate = false`）同时实现文字自适应明暗菜单栏与三柱语义着色，并在弹窗打开期间保持状态栏按钮高亮选中态（`button.highlight(true)`）：
  - **左侧（`0 .. 33 pt`）**：上下两行右对齐纯数值紧凑网速（`SystemMetrics.formatCompactRate`，上行上传、下行下载，去掉 `↑`/`↓` 箭头与 `/s` 后缀，最宽 `999 MB` 实测 `31.70 pt` 永不截断，`8.0 pt` 等宽数字 + `NSColor.labelColor` 动态适配浅色/深色菜单栏）。
  - **右侧（`39.0 .. 52.0 pt`，与网速列间距 `6.0 pt`）**：三根高度 `17 pt` 的纵向语义彩色胶囊柱（按 **CPU · RAM · TMP** 排列，量程统一为 `0 ~ 100`，与左侧双行文字上下边缘平齐，通过 `NSColor(name: nil) { appearance in ... }` 与 `NSColor.labelColor.withAlphaComponent(0.22)` 自适应浅色/深色菜单栏对比度）：
    - **CPU 柱**：青色（浅色模式 `#0284C7` / 深色模式 `#38BDF8`；负载 `≥ 75%` 时转为高负载活力橙）。
    - **RAM 柱**：随内核 `memoryPressure` 实时联动变色（正常翡翠绿 → 压力偏高琥珀黄 → 压力吃紧珊瑚红）。
    - **TMP 柱**：热力渐变（`< 55 °C` 冰川青 → `55–72 °C` 琥珀黄 → `≥ 72 °C` 珊瑚红）。
  - **macOS 26+ 原生 Liquid Glass 动态高度详情面板**：左键按下（`.leftMouseDown`）弹出 `.nonactivatingPanel` 承载 [`MonitorPopoverView`](../../Sources/SoftLive/UI/StatusBar/MonitorPopover.swift)（不调用 `NSApp.activate()`，避免在刘海屏上因切换前台菜单栏导致状态栏图标跨刘海跳变；使用 `acceptsFirstMouse` + `.onTapGesture` 支持非激活态首击直达切换，并通过全局/本地鼠标与 `Esc` 监听实现点击外部即收起；视图树与 `.glassEffect` 常驻挂载、仅观察 `monitor.detailMetrics`，弹窗收起时 `detailMetrics` 不更新且 `contentView.isHidden = true`，后台 0 重算、再次打开时 0 重建开销）。
    - **原生亮暗自适应与 Liquid Glass**：不强制固定深色背景，直接使用系统原生 `Color.clear.glassEffect(.regular, in: .rect(cornerRadius: 22))` 毛玻璃材质与动态语义色盘（`MonitorPalette`），自动跟随系统浅色/深色外观。
    - **动态高度与恒定内边距**：`.glassEffect` 直接包裹自然高度的 `VStack(spacing: 10).padding(14)`（不使用 `maxHeight: .infinity` 撑开底部空白），内部进度柱全部使用已知固定尺寸直接计算（0 个 `GeometryReader`），四周边距恒定为 `14 pt`，卡片高度通过 `.spring` 动画贴合内容，并通过 `onGeometryChange` 同步更新 `FirstMouseHostingView.activeTopHeight` 使下方透明区域点击穿透并关闭弹窗。
    - **三页遥测与进程强杀**：
      - **CPU 标签页**：芯片型号与核心拓扑徽章（`Apple M4 · 4P + 6E`）、60 秒总负载波形、用户/系统/平均负载、**能效核 E + 性能核 P + GPU 硬件渲染** 11 柱矩阵，以及 **高占用进程 Top 10**（每行右侧带 `✕` → 红色 `结束` 二次确认胶囊，点击期间锁定列表排序防止跳动，确认后直接终止进程）。
      - **RAM 标签页**：已用/总计内存与**内存压力徽章**、60 秒内存趋势波形、四段多色构成条（`App` / `联动` / `压缩` / `Swap`），以及同样支持一键结束的 **物理内存大户 Top 10（`Phys Footprint`）**。
      - **TMP 标签页**：SoC 核心温度与热状态徽章、60 秒温度波形、**整机实时功耗（`W`）与散热风扇转速（`RPM`）双卡片**，以及 5 项硬件关键部位热力分布条（SoC 性能核峰值、SoC 核心均值、主板与供电 PMU、SSD 固态闪存、智能电池）；底栏显示实时 `KB/s` / `MB/s` 上下行网速。
  - **去重与缓存**：字体与段落属性字典缓存为 `static let`，仅在网速文本、柱高步进或内存压力等级（`DisplayKey`）变化时才重绘 `NSImage`。
- **菜单**：[`AppMenu`](../../Sources/SoftLive/App/AppMenu.swift) 是唯一的菜单，两个状态栏项、右键桌面歌词或桌面组件、再次打开 App 都弹出它。
- **悬浮面板基类**：[`OverlayPanel`](../../Sources/SoftLive/UI/Overlay/OverlayPanel.swift) 是桌面歌词和桌面组件共用的面板。
  它负责透明背景、在所有桌面空间显示、原生拖动（`window.performDrag`，保留系统屏幕边缘阻尼感）、首击直达控件（`acceptsFirstMouse` + `canBecomeKey`）、右键菜单、记住位置（`frameName`），并通过 `Observations` 同步显示、鼠标穿透和紧凑态可点击高度（`activeTopHeight`，用 `convert(point, from: superview)` 转换坐标）。
- **桌面歌词**：[`DesktopLyrics`](../../Sources/SoftLive/UI/Overlay/DesktopLyrics.swift)，窗口层级 `.floating`，全屏 App 上也显示：
  - **平时状态**：完全透明背景，采用统一的标准 SF Pro 字体与固定高度双行居中排版（上行 26 pt `.semibold` 逐字高亮，下行 15 pt `.medium` 翻译或下一句，空行保留高度防跳动），配合文字自身的双层自然投影（紧贴边缘阴影 + 柔和环境阴影），不使用生硬的黑边 `strokeWidth` 描边。
  - **穿透与唤醒**：默认开启鼠标穿透（`desktopLyricsLocked = true`），通过 `NSEvent` 的 `.flagsChanged` 与 `.leftMouseUp` 监听 `Command (⌘)` 键和按键释放（面板不可见时短路并复位状态）；按住 `⌘` 移入歌词区域即唤醒 `.glassEffect` 毛玻璃卡片与顶部居中迷你控制栏（暂停/继续、锁定切换、隐藏桌面歌词），且只要鼠标仍停留在卡片内，松开 `⌘` 后依然保持唤醒状态可直接点击、拖动或双击卡片切下一首，鼠标移出卡片（或按住移出后释放）自动恢复穿透。
- **桌面组件**：[`DesktopWidget`](../../Sources/SoftLive/UI/Overlay/DesktopWidget.swift)，窗口层级为 `kCGDesktopIconWindowLevel + 1`（`NSWindow.Level.desktopWidget`），位于桌面图标之上、所有 App 窗口之下，共用顶部头部并通过 `.spring` 动画在紧凑态与展开态之间平滑过渡：
  - **未播放（紧凑态）**：单行卡片（高度 88 pt），不展示空白歌词区与进度条；左侧展示所选播放器最近曲目的专辑封面，中间展示最近曲目与歌手，右侧上方为 `播放` 胶囊按钮、下方为横向排列的播放器 App Icon 切换栏（通过图标亮暗区分选中态）。
  - **播放中（展开态）**：高度 146 pt，顶部头部信息列内联紧凑进度条与时间（`━━━── 1:51 / 4:04`），右侧提供**暂停/继续（`⏸`/`▶`）**和**关闭（`✕`，退出后台播放器并收起回紧凑小组件）**两个圆形按钮，双击卡片空白处切下一首；下方区域完整留给双行歌词区（逐字当前句 + 翻译或下一句）。
- **逐字渲染**：
  - [`KaraokeText`](../../Sources/SoftLive/UI/Karaoke/KaraokeText.swift)：SwiftUI 包装。
  - [`KaraokeLayerView`](../../Sources/SoftLive/UI/Karaoke/KaraokeLayerView.swift)：用 CoreText 排版和光栅化，用 Core Animation 推进。

## 运行路径（逐字渲染）

1. **只在必要时重新渲染**：行内容、间奏态（`isInterlude`）、尺寸、字体、颜色或屏幕缩放变化时（`RenderKey`），用 CoreText 排版并光栅化一张位图，同时算出每个词的起止像素位置（`wordRanges`）；处于前奏或长间奏（`interlude != nil`）时，在同一图层内光栅化三枚圆点（`• • •`）并按三等分时间映射到 `wordRanges`。
   文字太长时缩小到 50%–100% 以放进宽度；桌面歌词的阴影直接画进位图。
2. **两层裁剪**：高亮层和暗色层（不透明度 0.38）共用这张位图，各由一个 `masksToBounds` 的图层裁剪。
   暗色层的锚点在右边缘，所以只需改它的 `bounds`。
3. **一条关键帧动画**：`syncAnimation` 根据当前进度和每个词（或间奏三圆点）的起止时间，生成一条 `CAKeyframeAnimation(keyPath: "bounds")`，由系统渲染服务逐帧插值；间奏播放期间同时挂载 `CABasicAnimation(keyPath: "opacity")` 实现柔和呼吸效果。
   - 只在换行、播放锚点变化或视图重新显示时重建；面板隐藏时不光栅化也不建动画。
   - 暂停时停在当前分割点（`splitX`）。
   - 词与词之间的空档，分割点停住不动。
4. **视图常驻**：视图高度固定、换行时不重建；换行时的入场动画也用 Core Animation（`animateEntrance`）。

## 约束与失败行为

- **不逐帧驱动**：不用 `TimelineView` 或定时器逐帧驱动歌词。
  之前的 SwiftUI `TextRenderer` 加 30 fps 方案，双窗口时 CPU 9–14%：每帧都对整行重新排版、重算玻璃效果。
- **桌面组件里不放持续动画的系统控件**：例如带 `symbolEffect` 的 SF Symbol，实测单这一项就占 15% CPU。
- **玻璃效果放在静态背景层**：放在内容上会随歌词更新被重算；桌面歌词只在鼠标悬停时显示玻璃背景。
- **进度条每秒更新一次**：时间文本用整数格式化，不用 `Duration.formatted`；桌面组件关闭时不启动 `TimelineView` 调度。
- **固定尺寸宿主视图**：`OverlayHostingView` 设 `sizingOptions = []`，避免 SwiftUI 内容变化时反复测量 `intrinsicContentSize` 并与固定面板尺寸冲突。
- **不用 WidgetKit**：它的刷新频率由系统控制，做不了实时歌词。
  代价是桌面组件不出现在系统小组件库里。
- **右键菜单**：`NSHostingView` 会吞掉右键事件，所以由 `OverlayHostingView` 转给菜单。
- **状态栏被隐藏**：带刘海的屏幕上，菜单栏放不下时 macOS 会隐藏带文字的状态栏项；这时可以通过桌面歌词、桌面组件或再次打开 App 弹出菜单。
- **Liquid Glass 的实际视觉效果尚未验证**：开发环境没有屏幕录制权限，只看过离屏渲染的布局。
- **性能**：同时开启桌面歌词和桌面组件、播放逐字歌词时，实测 CPU 0–0.8%。

## 验证

- `swift test --filter KaraokeLayerViewTests`
- 改动渲染相关代码后，按 [code-standards](../code-standards.md) 实测 CPU。
