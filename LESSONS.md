# 经验教训

SoftLive 的代码由 agent 编写和验证。每当有改动需要返工、结论下错，或验证做得太浅，就在这里记下来。
**改代码之前先读一遍。**

- **格式**：每条都是「规则」，然后是原因和证据。「出现」记录在几轮不同的工作里遇到过。
- **毕业**：同一条出现满 3 次，就并入 [docs/code-standards.md](docs/code-standards.md)，并从这里删掉。
- **清理**：已经被代码或规范彻底杜绝、不可能再犯的条目，直接删掉。

## 数据与判断

**在一个数据源上建功能之前，先用独立的事实核对它的承诺。**
- 第一版假设网易云的 `historyTracks` 会在每首歌开始时写入，并用它判断换歌和开始时间。
  用户反馈后台播放时不同步，才用 `playingCount`（每次播放结束时的记录）和缓存文件的创建时间核对：15 次播放里 5 次没有记录，2 次晚写 124 秒和 285 秒。
- 后来换成缓存文件之前，先核对了它的创建时间与真实开始时间（相差 ≤ 2 秒）。
- 同样曾假设网易云暂停时 Core Audio 的 `kAudioProcessPropertyIsRunningOutput` 会变为 `0`，未实际测量就上线；用户反馈暂停不同步后核查 `coreaudiod` 日志才发现网易云暂停后会保持音频流开启并输出静音长达 20 小时（`IsRunningOutput` 恒为 `1`），且新歌 `.info` 创建早于音频流启动 150 ms 会把状态卡在暂停。核对 LevelDB `.log` 实测数据后改为读取 `playingInfo.playingState`（`1` = 暂停，`2` = 播放）并辅以 `lastPlaying` 4 秒静默超时。
- 出现 2 次。

**直接扫描二进制日志文件里的键值时，必须处理底层容器的分块边界。**
- LevelDB 的 `.log` 文件按 32 KiB（`32768` 字节）分块，跨块记录会在 `offset % 32768 == 0` 处插入 7 字节的块续写头（`crc32 + length + type`）。`lastPlaying` 只有 265 字节很少跨块，但 `playingInfo` 约 13 KB，约 40% 的记录会跨 32 KiB 边界；未跳过 7 字节块头会导致 Base64 解码失败并漏掉状态变化。
- 出现 1 次。

**引入暂停状态后，所有把“墙钟经过时间（`now - start`）”当作“已播放时长”的判断都要同步修正。**
- 加入暂停/继续后，`NetEaseSource` 原有的两处逻辑仍假设歌曲从未暂停：`publish` 用 `now - start > duration + 5` 丢弃过期会话，`isNewPlay` 用 `latest.start - play.start >= duration` 判断同曲重播。若一首歌中途暂停了几分钟再恢复（或暂停期间重启 App 再恢复），墙钟时间已超过曲目时长，会导致恢复播放后被当成过期会话丢弃（且因 `play == latest` 卡死在 `state == nil`）或误判为从头重播；暂停状态下拖动进度条写出的单条 `lastPlaying` 也会被 `position != previous.position` 误判为恢复播放。必须区分“正在播放 vs 静止过期”、用计入暂停的 `state.position(at:)` 判断是否播完，并在收到 `playingState = 1` 明确暂停后抑制单条 `lastPlaying` 的假恢复。
- 出现 1 次。

**觉得功能“没生效”时，先看输入里有没有它需要的数据，再查代码。**
- 用户说看不到逐字效果。查下来，最近播放的几首歌在网易云上本来就没有逐字数据（普通接口和加密接口都没有），代码没问题。
- 出现 1 次。

**时序模型要从实测样本推出来，不要凭直觉。**
- `ProgressCalibration` 的窗口（2 秒），来自连续 22 条 `lastPlaying` 记录的实测：真实进度比记录值高 0.66–1.68 秒。
- 第一次写测试时，用“真实进度减延迟再取整”来模拟记录，会产生实际从未出现过的超过 2 秒的差；改成直接用实测的差值。
- 出现 1 次。

**按分段子串的 UTF-16 长度在整行文本上推进游标时，整行文本不能单独做裁剪或改写。**
- `YRCParser` 曾对 `words.map(\.text).joined()` 做了 `.trimmingCharacters(in: .whitespaces)`，但 `words` 保留了原始分词；当行首含空格词时，`KaraokeLayerView` 在 `CTLine` 上的 UTF-16 游标整体右偏，导致整行逐字高亮错位。
- 出现 1 次。

## 边界与方案

**提议方案之前，先判断它是否在绕过保护：看被绕开的是什么，而不是手段像不像破解。**
- 第一轮的方案推荐了借 `/usr/bin/perl` 读 MediaRemote，实现时才发现这是绕过系统权限检查，改为各播放器单独接入。
- 第一次讨论拖动同步时，又把解密 `lastPlaying` 也当成绕过保护拒绝了。
  其实它只是网易云对用户自己本地数据的混淆，不涉及系统权限、账号或版权保护，后来重新判断并采用。
- 判断标准已经写进 [docs/code-standards.md](docs/code-standards.md)。
- 出现 2 次。

**说“做不到”或提出手动替代方案之前，先查开源项目有没有解决过。**
- 拖动同步第一次调查后，结论是自动方案不可行，提出用滚轮手动对齐。
  用户要求联网查，才发现 CloudLyrics-for-macOS 已经在读 `lastPlaying`。
- 出现 1 次。

## 验证

**性能要在用户真实的使用场景里测，并用采样定位开销，不要只测一个窗口或凭经验猜。**
- 加入桌面组件时，测到 CPU 15–20%，去掉持续动画的波形图标后报告 0.5–6%。
  但用户在双窗口、逐字歌词播放时仍觉得异常；在同样场景下实测是 9–14%。
  用 `sample` 定位到 `TextRenderer` 每帧都对整行重新排版，改成 Core Animation 后降到 0–0.8%。
- 出现 2 次。

**隐藏 `NSPanel` 或 `contentView` 不会自动停止 `NSHostingView` 的观察和 `TimelineView` 调度。**
- 默认关闭的桌面组件虽然被 `orderOut` 且 `contentView.isHidden = true`，但 `NSHostingView` 仍保持挂载，每句歌词切换时后台仍在做 CoreText 位图光栅化和 Core Animation 构建，且进度条 `TimelineView` 仍在每秒唤醒；需在视图层用 `!isHiddenOrHasHiddenAncestor` 和可见状态显式短路。
- 出现 1 次。

**新增交互入口（按钮、菜单、URL Scheme 唤起）必须在真实运行态下点击并核对日志，不能只跑单元测试。**
- 桌面组件首次加上「开始播放」按钮和 `orpheus://` 唤起时只跑了单元测试就交付；实际存在三处运行态问题：① `OverlayHostingView.hitTest(_:)` 的参数在父视图未翻转坐标系中，直接按 `isFlipped` 裁剪导致顶部按钮区域返回 `nil`、点击穿透到桌面（后改为锚定 `frame.maxY` 直接调整 `NSPanel` 高度）；② `.borderless` 的 `NSPanel` 默认 `canBecomeKey == false`，未重写时点击控件只打印 `makeKeyWindow` 警告；③ 网易云冷启动时首个 `orpheus://` 事件早于 CEF 页面就绪而丢失，需在未进入播放态时延迟补发。
- 出现 1 次。

**前后对比必须在相同条件下测。**
- 优化 CPU 那一轮报告内存从 87.7 MB 降到 23.6 MB，但两个数字分别是启动后约 6 秒和约 1 秒采到的，不能比较；后来已更正。
- 出现 1 次。

**和其他 App 交互，不能顺带把它启动起来。**
- 退出 Music 后，它会被 SoftLive 重新拉起：Music 退出时仍会发 `playerInfo` 通知，而按 bundle ID 创建的 `SBApplication` 一查询就会启动目标。
  改为按正在运行的进程的 PID 创建。
- 出现 1 次。

**测试会动到用户正在用的 App 时，先想好怎么恢复，并告诉用户。**
- 测试时打开过网易云，它启动后自动开始播放。当时调低音量，测完暂停、恢复音量、退出，并在回复里写明。
- 现在的规则：不操作用户的播放器。
- 出现 1 次。
