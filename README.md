# SoftLive

在 macOS 的菜单栏、桌面悬浮窗和桌面组件里，同步显示 **Apple Music / 网易云音乐** 正在播放的歌词，支持**逐字**高亮。

- **状态栏歌词**：有宽度上限，长句尾部截断。
- **桌面悬浮歌词**：始终置顶，所有桌面空间可见，不抢焦点；可拖动，可锁定为鼠标穿透；有翻译时第二行显示翻译，没有则显示下一句。
- **桌面组件**：钉在桌面上、所有窗口之下的 Liquid Glass 卡片，显示封面、曲目、逐字歌词、翻译、下一句和进度。
- **逐字歌词**：歌曲有网易云逐字歌词（YRC）时按演唱进度逐字填亮，没有就逐行显示。
- **跟随播放器**：自动跟随正在播放的播放器；网易云在后台播放、拖动进度后都能自动同步；也可以手动微调偏移（±0.5 秒，换歌后重置）。
- **原生实现**：Swift（AppKit + SwiftUI），无第三方依赖，**需要 macOS 26+**；播放时 CPU 约 0–0.8%。

## 构建与运行

```bash
Scripts/build-app.sh --run     # 构建 build/SoftLive.app 并启动
swift test                     # 单元测试
```

只有 Apple Music 需要授权：首次运行时允许「自动化 → Music」，用来读取当前曲目与进度。网易云不需要任何权限。

> [!NOTE]
> 这项授权和代码签名绑定。默认的 ad-hoc 签名每次构建都会变化，导致授权失效，需要重新授予。可以设置稳定的签名身份来避免：
> `SIGN_IDENTITY="Apple Development: …" Scripts/build-app.sh`（可用 `security find-identity -p codesigning` 查看）。

## 文档

| 文档 | 内容 |
| --- | --- |
| [AGENTS.md](AGENTS.md) | 给 AI 编程 agent 的入口：先读什么、命令、怎么维护文档 |
| [docs/requirements.md](docs/requirements.md) | 需求、验收标准、明确不做的事、待验证项 |
| [docs/subsystems/](docs/subsystems/README.md) | 各子系统现在怎么工作：事实来源、运行路径、约束与失败行为 |
| [docs/code-standards.md](docs/code-standards.md) | 代码规范与审查标准 |
| [LESSONS.md](LESSONS.md) | 开发中做错过什么，以及对应的规则 |

## 已知限制

- **网易云拖动进度后，歌词约 1–2 秒才跟上，刚跟上时可能差 1 秒以内。** 网易云只记录整数秒，大约每 2 秒才写入磁盘一次，之后的记录会继续把误差缩小。仍不准时，可以用菜单里的「歌词提前/延后」微调。
- **依赖网易云的私有数据格式。** 缓存文件命名、`lastPlaying` 的存储方式和密钥都可能随客户端更新而改变。读不到进度时会退回到「开始时间 + 外推」，只是拖动后不再自动跟上。
- **菜单栏放不下时，状态栏歌词会被隐藏。** 带刘海的 MacBook 上，如果菜单栏图标太多，macOS 会直接隐藏放不下的状态栏项。可以在「系统设置 → 菜单栏」中关闭一些图标；也可以右键桌面歌词（未锁定时）或桌面组件，或者在 SoftLive 已运行时再次打开它，都能弹出同一个菜单。
- **逐字歌词只来自网易云 YRC**，不是每首歌都有（LRCLIB 没有逐字数据）。

## 致谢

- **方案参考**：[LyricsX](https://github.com/ddddxxx/LyricsX)（锚点外推、匹配打分）、[Lyrimuse](https://github.com/Yudaotor/Lyrimuse)、[Lyric Fever](https://github.com/aviwad/LyricFever)。
- **网易云 `lastPlaying` 的读取方法**：参考了 [CloudLyrics-for-macOS](https://github.com/hellomyonly55/CloudLyrics-for-macOS)。
- **歌词来源**：网易云音乐、[LRCLIB](https://lrclib.net)。
