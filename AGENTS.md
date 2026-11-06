# 给编程 agent 的说明

SoftLive 是原生 macOS 歌词与系统监控应用，提供状态栏、桌面悬浮歌词、桌面组件和独立舞台窗口。
技术栈：Swift 6.2 · SwiftPM · AppKit + SwiftUI · macOS 26+ · 零第三方依赖。

## 开始工作

1. 读 [需求](docs/requirements.md)，确认目标、验收标准与明确不做的事。
2. 读 [代码规范](docs/code-standards.md) 和 [LESSONS.md](LESSONS.md)，再修改代码。
3. 从 [子系统索引](docs/subsystems/README.md) 找到对应页面，顺着源码链接核对当前实现。
4. 修改后运行全部测试；按改动范围补充构建、真实交互或性能验证。无法验证的部分如实说明。

## 文件结构与职责

| 位置 | 职责 |
| --- | --- |
| `Sources/SoftLive/App/` | App 入口、依赖组装、共享菜单、偏好持久化 |
| `Sources/SoftLive/Playback/` | 播放器接入与 `PlaybackModel` 编排；新增播放器放在 `<Name>/` |
| `Sources/SoftLive/Lyrics/` | 歌词模型、来源、匹配、解析与缓存 |
| `Sources/SoftLive/Monitor/` | 监控模型与采样编排；独立系统接口采样器放在 `Samplers/` |
| `Sources/SoftLive/UI/` | 按 `StatusBar/`、`Overlay/`、`Karaoke/`、`Stage/` 组织界面与渲染 |
| `Sources/SoftLive/Support/` | 跨子系统复用的基础设施；模块专用 helper 留在所属模块 |
| `Tests/SoftLiveTests/` | 按被测职责组织 Swift Testing 测试 |
| `Resources/`、`Scripts/` | App 打包资源与开发脚本 |
| `docs/` | 需求、规范与子系统参考 |

## 命令

在仓库根目录运行：

- 全部测试：`swift test`（必须全部通过）。
- Release 编译检查：`swift build -c release`，不打包或重启 App。
- 构建 App：`Scripts/build-app.sh`，产物为 `build/SoftLive.app`。
- 构建并重启：`Scripts/build-app.sh --run`，会退出当前运行的 SoftLive。
- 查日志：`/usr/bin/log show --last 10m --info --predicate 'subsystem == "dev.softlive.SoftLive"' --style compact`。
  zsh 的 `log` 是内置命令，必须写全路径；实时 debug 日志将 `show --last 10m --info` 换成 `stream --level debug`。
- 量 CPU：`top -l 5 -s 1 -stats pid,cpu,idlew,mem -pid $(pgrep -x SoftLive)`；记录开启的窗口、播放状态与采样时点。

`build/`、`.build/`、`.swiftpm/` 是本地产物，不入库。

## 维护与验证边界

- 文档分工、源码链接与同步规则见 [子系统索引](docs/subsystems/README.md#维护规则)；代码与验证要求见 [代码规范](docs/code-standards.md)。
- 每轮工作结束，把确实发生的返工、误判或验证不足记进 [LESSONS.md](LESSONS.md)，沿用其中的格式与毕业规则。
- **打包会重新签名**：默认 ad-hoc 签名变化可能使「自动化 → Music」授权失效。只检查编译时用 `swift build -c release`；需要保留授权的打包使用 `SIGN_IDENTITY=... Scripts/build-app.sh`。
- **不操作用户的播放器，不修改其数据**：不要为验证往 Music 资料库添加歌曲（会同步到 iCloud）。当前完整播放流程的验证边界见 [需求的待验证项](docs/requirements.md#待验证)。
- **网易云格式以实测为准**：动接入前先读 [网易云来源](docs/subsystems/netease.md) 中的可靠性与失败行为。
