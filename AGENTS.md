# 给编程 agent 的说明

SoftLive 是一个原生 macOS 歌词应用：在状态栏、桌面悬浮窗和桌面组件里同步显示 Apple Music / 网易云音乐的歌词，支持逐字。
技术栈：Swift 6.2 · SwiftPM · AppKit + SwiftUI · macOS 26+ · 零第三方依赖。

## 先读什么

- **需求**：[docs/requirements.md](docs/requirements.md)，现在要做到什么、明确不做什么。
- **子系统参考**：改某个子系统前，先读它在 [docs/subsystems/](docs/subsystems/README.md) 里的页面，再核对链接到的源码。
  行为变了，在同一改动里更新那一页。
- **代码规范**：按 [docs/code-standards.md](docs/code-standards.md) 写代码和审查。
- **经验教训**：改代码前读 [LESSONS.md](LESSONS.md)：之前做错了什么，以及哪条规则能避免。

## 命令

- 测试：`swift test`（必须全部通过）
- 构建并重启 App：`Scripts/build-app.sh --run`（产物在 `build/SoftLive.app`）
- 查看日志：`/usr/bin/log show --last 10m --info --predicate 'subsystem == "dev.softlive.SoftLive"' --style compact`
  - zsh 里 `log` 是内置命令，必须写全路径。
  - 实时看 debug 级日志：把 `show --last 10m --info` 换成 `stream --level debug`。
- 量 CPU：`top -l 5 -s 1 -stats pid,cpu,idlew,mem -pid $(pgrep -x SoftLive)`

## 维护文档

- **文档只写现在**：需求、子系统参考、规范都直接在原文上更新，过时的内容删掉。
  不另建迭代记录或决策记录；被放弃的方案在对应子系统的「约束」里留一句为什么不用；历史查 git。
- **教训进 `LESSONS.md`**：每轮工作结束，把需要返工、判断失误或验证太浅的地方写进去（规则 → 原因 → 证据）。
  同一条出现满 3 次，就并入代码规范。

## 容易踩的坑

- **签名会让授权失效**：默认 ad-hoc 签名每次构建都会变，「自动化 → Music」授权随之失效。
  需要保留授权时用 `SIGN_IDENTITY=... Scripts/build-app.sh`。
- **Apple Music 测不了完整流程**：用户的 Music 资料库是空的，播放中的完整流程没有端到端测过。
  不要为了测试往资料库里加歌（会同步到 iCloud）。
- **网易云的数据源各有局限**：各自的可靠性和实测数据见 [网易云来源](docs/subsystems/netease.md)，动这部分前一定先读。
