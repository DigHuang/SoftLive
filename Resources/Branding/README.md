# SoftLive 品牌资源

正式方案为 **Sync / 同频 × 霜光**。应用图标保留柔和的缎带曲面与折返层次，背景由 macOS 原生图标系统绘制；状态栏使用独立的单色模板。

## 文件

- [AppIcon.icon/icon.json](AppIcon.icon/icon.json)：macOS 26 原生图标工程，定义霜光背景、图层与平台。
- [AppIcon.icon/Assets/Ribbon.svg](AppIcon.icon/Assets/Ribbon.svg)：透明背景的细节缎带矢量图层；同目录的 `Ribbon.png` 是 1024 px 同源导出，供图标工程使用。
- [app-icon.svg](app-icon.svg)：完整、不预裁圆角的矢量画布，背景配色与缎带轮廓对应原生图标工程。
- [app-icon.png](app-icon.png)：系统从最终 App 包读取的图标预览，供 README 展示。
- [logo.svg](logo.svg)：相同缎带外轮廓的透明背景单色标志，使用 `currentColor`。
- [SyncTemplate.png](../../Sources/SoftLive/UI/Branding/Resources/SyncTemplate.png)：从单色轮廓导出的 128 × 128 px 共享模板，状态栏以 18 × 18 pt 显示，桌面组件无封面时以 28 × 28 pt 显示。

## 材质与尺寸

缎带保留上、中、下曲面的柔和渐变。下方折返的前后两面共用同一条贝塞尔边界，与外轮廓相接时保持切线一致；连接处使用一致的底色，避免模糊叠层露出暗线。曲面不叠加平行高光线，整体轮廓保持一致。矢量源文件由路径、渐变、裁剪和滤镜组成，未嵌入位图。

原生图标工程使用冷青蓝与雾蓝的缎带层，配浅冷色渐变背景。圆角、底板和系统外观由 macOS 处理，不在前景图层里再画一套缩小底板，以免出现双重套框。固定预览与动态系统呈现可能因外观和尺寸而有所区别。

共享模板只有黑色与透明度，不包含背景、彩色渐变或霜光效果；`NSImage.isTemplate = true` 使状态栏随系统深浅外观着色，桌面组件的无封面占位标志使用次级文字色。有歌词文字时延续仅显示文字的行为。

修改缎带轮廓后，应同步更新单色标志、图层 PNG 和状态栏位图。独立标志保持长宽比例与至少 12 个 SVG 坐标单位的净空。

## App 打包

需要项目要求的 Swift 6.2 / macOS 26 工具链，以及 Xcode 的 `actool`：

```bash
Scripts/build-app.sh
```

脚本执行 Release 编译，使用 `xcrun actool` 编译 `AppIcon.icon`，将 `Assets.car`、兼容 `AppIcon.icns` 和共享模板位图复制到 `build/SoftLive.app/Contents/Resources`，然后签名。临时编译目录在脚本结束时清理。

`Resources/Info.plist` 同时声明 `CFBundleIconName = AppIcon` 和 `CFBundleIconFile = AppIcon`。共享模板通过 SwiftPM 支持本地运行，打包 App 优先从主资源目录加载，由 `BrandAssets` 缓存并复用。

构建并重启当前 SoftLive：

```bash
Scripts/build-app.sh --run
```

签名注意事项沿用项目 [构建说明](../../README.md#构建与运行)。构建与运行不向应用添加第三方依赖。

## 验证

已通过全部测试、Release 构建与签名检查；核对原生图标编译产物、状态栏位图尺寸 / 单色像素、App 包内资源和一致的 SVG 轮廓，并实际重启当前进程。系统图标 API 可读取更新后的原生图标。

原生截图工具未能正确捕获状态栏画面，因此未将资源检查描述为状态栏实屏截图验证。
