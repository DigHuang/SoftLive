# SoftLive

在 macOS 的菜单栏、桌面悬浮窗、桌面组件和独立舞台窗口里，同步显示 **Apple Music / 网易云音乐** 正在播放的歌词，并在菜单栏监控 **CPU、内存、SoC 温度与上下行网速**。

- **状态栏歌词**：显示当前行，长句尾部截断。
- **系统监控**：独立紧凑状态栏项；点击展开 Liquid Glass 详情面板，查看 CPU / RAM / 温度趋势、进程排行、功耗与风扇，支持确认后结束进程；关闭监控后停止采样。
- **桌面悬浮歌词**：置顶、不抢焦点，默认鼠标穿透；按住 `⌘` 移入唤醒控制栏，支持拖动和双击切歌。第二行显示翻译或下一句。
- **桌面组件**：位于桌面图标之上、App 窗口之下。未播放时收起为播放器选择卡片，播放时展开封面、曲目、进度与歌词。
- **舞台模式**：独立可缩放窗口，提供「流光」与「描金」两种律动风格、封面取色背景、星火特效和黑胶间奏。默认关闭，从菜单打开。
- **歌词同步**：网易云 YRC 支持逐字高亮，无逐字数据时逐行显示；支持翻译、间奏指示和菜单内手动校正（每次 ±0.5 秒，换歌重置）。
- **原生实现**：Swift + AppKit + SwiftUI，零第三方依赖，需要 **macOS 26+ 与 Swift 6.2+ 工具链**。

## 构建与运行

```bash
Scripts/build-app.sh --run
```

构建 `build/SoftLive.app` 并重启 SoftLive。仅打包时省略 `--run`；仅检查 Release 编译、不替换 App 时运行：

```bash
swift build -c release
```

运行全部测试：

```bash
swift test
```

Apple Music 首次使用需允许「自动化 → Music」授权；网易云无需授权。

> [!NOTE]
> 自动化授权与代码签名绑定。默认 ad-hoc 签名在重新构建后可能变化，需要重新授权。可设置稳定签名身份打包：`SIGN_IDENTITY="Apple Development: …" Scripts/build-app.sh`；用 `security find-identity -p codesigning` 查看可用身份。

## 文档

| 文档 | 内容 |
| --- | --- |
| [AGENTS.md](AGENTS.md) | 开发入口、目录职责、命令与验证边界 |
| [需求](docs/requirements.md) | 目标、验收标准、明确不做的事与待验证项 |
| [子系统参考](docs/subsystems/README.md) | 各子系统的运行方式、约束与实测依据 |
| [代码规范](docs/code-standards.md) | 代码与审查标准 |
| [LESSONS.md](LESSONS.md) | 开发错误的证据与对应规则 |

## 已知限制

- **网易云拖动后的同步有延迟。** 本地进度记录只有整数秒，约每 2 秒写入一次；记录到达后再修正，详见 [网易云来源](docs/subsystems/netease.md)。
- **依赖网易云私有数据格式。** 客户端更新可能改变缓存格式；读取失败时的回退行为见同一页面。
- **菜单栏放不下时状态栏项可能被系统隐藏。** 可右键桌面歌词（未锁定时）、桌面组件或舞台窗口，或再次打开 SoftLive，访问主菜单。
- **逐字歌词只来自网易云 YRC。** 并非每首歌都有，LRCLIB 只提供逐行歌词。
- **验证有场景边界。** Apple Music 完整播放流程、实际玻璃效果和舞台性能的待验证情况见 [需求](docs/requirements.md#待验证)；桌面双窗口歌词的 CPU 实测见 [界面与渲染](docs/subsystems/ui.md#约束与失败行为)。

## 致谢

- **方案参考**：[LyricsX](https://github.com/ddddxxx/LyricsX)（锚点外推、匹配打分）、[Lyrimuse](https://github.com/Yudaotor/Lyrimuse)、[Lyric Fever](https://github.com/aviwad/LyricFever)、[Stats](https://github.com/exelban/stats)（系统指标采样）。
- **网易云 `lastPlaying` 读取方法**：[CloudLyrics-for-macOS](https://github.com/hellomyonly55/CloudLyrics-for-macOS)。
- **歌词来源**：网易云音乐、[LRCLIB](https://lrclib.net)。
