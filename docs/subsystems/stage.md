# 舞台模式

## 职责与事实来源

- [`StageWindow`](../../Sources/SoftLive/UI/Stage/StageWindow.swift) 是独立 `.nonactivatingPanel`，由 `Preferences.showsStageWindow` 控制显示，默认关闭。宿主负责首击、拖动、右键主菜单与位置保存，SwiftUI 控制栏通过 `PlaybackModel` 发起播放控制。
- [`StageCanvasView`](../../Sources/SoftLive/UI/Stage/StageCanvasView.swift) 接收歌词、播放锚点、偏移、风格与封面，编排图层和动画。不直接读取播放器、请求网络或推进播放状态。
- [`StagePalette`](../../Sources/SoftLive/UI/Stage/StagePalette.swift) 将封面降采样后提取背景、光球与强调色，`StagePalette.cached(for:)` 按图片对象引用缓存结果供舞台与桌面组件共用，无封面时使用默认色盘。
- 窗口固定使用 `darkAqua` 外观；悬浮控制采用四角无底栏布局（左上关闭/缩放圆钮、右上共心胶囊风格分段器、左下无底框封面与曲目、右下播放/暂停圆钮），双击舞台区域可切下一首，无封面时复用 [`BrandAssets.syncTemplate`](../../Sources/SoftLive/UI/Branding/BrandAssets.swift)。
- 两种 `StageStyle` 及星火开关由 [`Preferences`](../../Sources/SoftLive/App/Preferences.swift) 持久化。

渲染内部按职责拆分，各 helper 不持有视图或读取其私有状态：

| 源码 | 职责 |
| --- | --- |
| [StageWordTimeline](../../Sources/SoftLive/UI/Stage/StageWordTimeline.swift) | 文本分段、YRC 拆字与回退时序 |
| [StageTextRenderer](../../Sources/SoftLive/UI/Stage/StageTextRenderer.swift) | CoreText 测量、字形路径与光晕位图 |
| [StageWordAnimation](../../Sources/SoftLive/UI/Stage/StageWordAnimation.swift) | 确定性运动曲线、姿态与关键帧编译 |
| [StageLuminousRenderer](../../Sources/SoftLive/UI/Stage/StageLuminousRenderer.swift) | 流光排版与入场效果 |
| [StageInkTraceRenderer](../../Sources/SoftLive/UI/Stage/StageInkTraceRenderer.swift) | 描金排版、描边与填充效果 |
| [StageEffects](../../Sources/SoftLive/UI/Stage/StageEffects.swift) | 镜头、残影、星芒、冲击环与星火 |
| [StageInterludeRenderer](../../Sources/SoftLive/UI/Stage/StageInterludeRenderer.swift) | 黑胶与间奏光点 |

## 运行路径

1. 从模型取当前歌词、下一句时间、翻译或预告、间奏、播放锚点与封面。没有歌词时显示当前或最近曲目名，再没有则显示占位标题。
2. 根据内容、尺寸、风格、色盘等渲染键决定重建；播放锚点与偏移变化会重新同步时序。背景为渐变与漂移极光球，切行可生成上一句残影。
3. 有 YRC 时使用真实词时间；无 YRC 时根据行区间安排舞台入场节奏，仅用于视觉表现，不表示推测出了真实逐字演唱时间。
4. 按所选风格构建图层与关键帧：
   - **流光**：确定性散落排版、3D 翻转、弹射、压扁与拉伸，配合重音镜头律动和句尾特效。
   - **描金**：CoreText 字形路径、分层描边走线与填充，配合几何装饰、残影与句尾星芒。
   - **间奏**：封面标签黑胶唱片与呼吸光点。
5. 控制栏在鼠标悬停或没有播放状态时显示，可切风格、星火、最大化/还原及控制播放。关闭舞台时隐藏宿主并卸载渲染子树，使图层动画随视图释放。

## 约束与失败行为

- 默认窗口 `920 × 580 pt`，最小 `680 × 440 pt`。最大化使用当前屏幕 `visibleFrame`，保留菜单栏和 Dock 的可用区域，不进入独立的系统全屏空间。
- 不逐帧用 SwiftUI 或定时器重排版；动画由 Core Animation 关键帧驱动，暂停时固定歌词表现。
- 不把频繁开关的监控弹窗套用舞台的卸载策略，原因见 [界面与渲染](ui.md#状态栏)。
- 真实播放下两种风格、窗口缩放及关闭后的 CPU 开销尚待测量，不能沿用桌面歌词与桌面组件的实测值；已有验证不能证明舞台隐藏后绝对零开销。

## 验证

- `swift test --filter StageCanvasViewTests` 覆盖文字分段、字形与离屏图层构建；完整测试使用 `swift test`。
- 真实交互和性能验证按 [代码规范](../code-standards.md#验证)，不操作用户正在使用的播放器。
