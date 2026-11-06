# Changelog

本项目所有面向用户的显著变更均记录于此文件。

格式遵循 [Keep a Changelog 2.0.0](https://keepachangelog.com/en/2.0.0/)，版本号遵循 [语义化版本 2.0.0](https://semver.org/lang/zh-CN/)。

## [Unreleased]

## [0.0.1] - 2026-11-06

SoftLive 首个版本：提供 macOS 状态栏、桌面悬浮窗、桌面组件与独立律动舞台窗口的 Apple Music / 网易云音乐逐字歌词同步，以及零权限菜单栏系统监控与 Liquid Glass 详情面板。

### Added

- **双播放器歌词同步**：原生支持 **Apple Music**（ScriptingBridge + `playerInfo` 分布式通知）与 **网易云音乐**（流媒体缓存 `.info`、本地 SQLite 历史表与 Chromium LevelDB 只读监听），无需辅助功能权限即可后台跟随切歌、暂停/继续与拖动进度。([#1])
- **多来源歌词与逐字高亮**：支持网易云逐字歌词（YRC）、逐行歌词（LRC）、双语翻译对齐、长前奏/演职员表后/句间长间奏呼吸圆点指示器，以及 LRCLIB 回退搜索与本地磁盘缓存；提供菜单内 ±0.5 秒手动偏移微调。([#9])
- **三种常驻歌词界面**：
  - **状态栏歌词**：自适应截断，关闭歌词且开启监控时自动释放菜单栏空间。
  - **桌面悬浮歌词**：跨空间与全屏置顶、双层柔光阴影、默认鼠标穿透；按住 `⌘` 移入唤醒 Liquid Glass 背景与迷你控制栏，支持拖动与双击切歌。([#2])
  - **桌面组件**：位于桌面图标之上、应用窗口之下的 Liquid Glass 卡片；未播放时收起为播放器选择紧凑卡片，播放时展开封面、进度、控制按钮与双行逐字歌词。([#2])
- **独立舞台模式（Stage Mode）**：可缩放/最大化的独立窗口，内置基于封面取色的动态极光背景、「流光」与「描金」两种 Core Animation 律动排版风格、星火粒子开关及黑胶唱片间奏动画。([#10])
- **菜单栏系统监控**：独立 `52 × 22 pt` 状态栏项实时显示上下行网速及 `CPU / RAM / TMP` 语义彩色柱；点击展开 macOS 26+ Liquid Glass 动态高度详情面板，含 60 秒趋势图、E/P 核心与 GPU 负载矩阵、支持二次确认结束进程的 **Top 10 进程 CPU/内存排行**、内存压力与 Swap、SoC/SSD/电池温度及 AppleSMC 整机功耗与风扇转速。([#5])

### Changed

- **Core Animation 逐字渲染**：单行歌词通过 CoreText 一次性光栅化位图，由单条 `CAKeyframeAnimation` 驱动高亮裁剪，替代 30 fps 逐帧重排版；桌面歌词与桌面组件双开播放逐字歌词时 CPU 占用降至 `0–0.8%`。([#1], [#6])
- **隐藏面板零后台开销与按需采样**：面板隐藏时短路位图光栅化、动画构建、全局修饰键监听与 `TimelineView` 调度；监控详情面板保持常驻视图树并按当前激活标签页（`CPU / RAM / TMP`）按需采样，消除开关弹窗时的主线程重建与 CPU 尖峰。([#6], [#7])
- **低开销播放器校对**：网易云同曲目进度汇报直接进入 `ProgressCalibration` 区间交集校准，不再重复扫描 SQLite 与缓存目录；Apple Music 拖动校对仅单次读取 `playerPosition`。([#6])

### Fixed

- **LevelDB 跨块解析与轮换续读**：修复网易云 LevelDB `.log` 跨越 32 KiB 块边界时未跳过 7 字节续写头导致 `playingInfo` Base64 解码失败的问题，并在日志轮换切换前读完旧文件尾部。([#8])
- **暂停恢复与进度校准收敛**：基于实测缓冲提前量将 `ProgressCalibration` 窗口收窄至 `1.2s`，修正暂停恢复后误判过期会话或同曲重播、切歌封面滞后一首以及首次封面拉取失败后不重试的问题。([#2], [#8])
- **YRC 词间空格与游标对齐**：归并 YRC 词间独立空白分词并保持整行文本与分词 UTF-16 长度一致，修复含行首空格或英文分词时的逐字高亮偏移。([#8], [#9])
- **系统采样边界修复**：补齐 `AppleSMC` `SMCKeyData_t` 80 字节结构体对齐填充，通过 `KERN_PROCARGS2` 与工作目录区分通用宿主进程（如 `node` / `next-server`），并过滤 `utun*` 虚拟网卡重复流量与 `tcal` 固定校准温度项。([#5], [#7], [#8])

[Unreleased]: https://github.com/DigHuang/SoftLive/compare/HEAD...main
[0.0.1]: https://github.com/DigHuang/SoftLive/commits/main
[#1]: https://github.com/DigHuang/SoftLive/pull/1
[#2]: https://github.com/DigHuang/SoftLive/pull/2
[#5]: https://github.com/DigHuang/SoftLive/pull/5
[#6]: https://github.com/DigHuang/SoftLive/pull/6
[#7]: https://github.com/DigHuang/SoftLive/pull/7
[#8]: https://github.com/DigHuang/SoftLive/pull/8
[#9]: https://github.com/DigHuang/SoftLive/pull/9
[#10]: https://github.com/DigHuang/SoftLive/pull/10
