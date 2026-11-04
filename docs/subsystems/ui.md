# 界面与渲染

## 职责与事实来源

- **只读数据与快捷控制**：界面只读取 [`AppModel`](../../Sources/SoftLive/App/AppModel.swift) 和 [`Preferences`](../../Sources/SoftLive/App/Preferences.swift)，并通过 `AppModel.play(_:)`、`togglePlayPause()`、`closePlayback()` 控制播放与收起，不直接接触播放器内部实现或网络。
- **状态栏**：[`StatusBarController`](../../Sources/SoftLive/UI/StatusBarController.swift) 显示 `AppModel.headline`，最大宽度 260 pt，长句尾部截断。
- **菜单**：[`AppMenu`](../../Sources/SoftLive/UI/AppMenu.swift) 是唯一的菜单，状态栏、右键桌面歌词或桌面组件、再次打开 App 都弹出它。
- **悬浮面板基类**：[`OverlayPanel`](../../Sources/SoftLive/UI/Overlay/OverlayPanel.swift) 是桌面歌词和桌面组件共用的面板。
  它负责透明背景、在所有桌面空间显示、拖动（`window.performDrag`）、首击直达控件（`acceptsFirstMouse` + `canBecomeKey`）、右键菜单、记住位置（`frameName`），并通过 `Observations` 同步显示、鼠标穿透和紧凑态可点击高度（`activeTopHeight`，用 `convert(point, from: superview)` 转换坐标）。
- **桌面歌词**：[`DesktopLyrics`](../../Sources/SoftLive/UI/Overlay/DesktopLyrics.swift)，窗口层级 `.floating`，全屏 App 上也显示；锁定时鼠标穿透。
- **桌面组件**：[`DesktopWidget`](../../Sources/SoftLive/UI/Overlay/DesktopWidget.swift)，窗口层级为 `kCGDesktopIconWindowLevel + 1`（`NSWindow.Level.desktopWidget`），位于桌面图标之上、所有 App 窗口之下，共用顶部头部并通过 `.spring` 动画在紧凑态与展开态之间平滑过渡：
  - **未播放（紧凑态）**：单行卡片（高度 88 pt），不展示空白歌词区与进度条；左侧展示所选播放器最近曲目的专辑封面，中间展示最近曲目与歌手，右侧上方为 `播放` 胶囊按钮、下方为横向排列的播放器 App Icon 切换栏（通过图标亮暗区分选中态）。
  - **播放中（展开态）**：高度 146 pt，顶部头部信息列内联紧凑进度条与时间（`━━━── 1:51 / 4:04`），右侧提供**暂停/继续（`⏸`/`▶`）**和**关闭（`✕`，退出后台播放器并收起回紧凑小组件）**两个圆形按钮；下方区域完整留给双行歌词区（逐字当前句 + 翻译或下一句）。
- **逐字渲染**：
  - [`KaraokeText`](../../Sources/SoftLive/UI/Karaoke/KaraokeText.swift)：SwiftUI 包装。
  - [`KaraokeLayerView`](../../Sources/SoftLive/UI/Karaoke/KaraokeLayerView.swift)：用 CoreText 排版和光栅化，用 Core Animation 推进。

## 运行路径（逐字渲染）

1. **只在必要时重新渲染**：行内容、尺寸、字体、颜色或屏幕缩放变化时（`RenderKey`），用 CoreText 排版并光栅化一张位图，同时算出每个词的起止像素位置（`wordRanges`）。
   文字太长时缩小到 50%–100% 以放进宽度；桌面歌词的阴影直接画进位图。
2. **两层裁剪**：高亮层和暗色层（不透明度 0.38）共用这张位图，各由一个 `masksToBounds` 的图层裁剪。
   暗色层的锚点在右边缘，所以只需改它的 `bounds`。
3. **一条关键帧动画**：`syncAnimation` 根据当前进度和每个词的起止时间，生成一条 `CAKeyframeAnimation(keyPath: "bounds")`，由系统渲染服务逐帧插值。
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
