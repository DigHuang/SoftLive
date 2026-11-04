# 播放与同步

## 职责与事实来源

- **播放状态与控制**：每个播放器来源实现 [`PlayerSource`](../../Sources/SoftLive/Playback/PlayerSource.swift)，发布 [`PlaybackState`](../../Sources/SoftLive/Playback/PlaybackState.swift)（曲目 + 锚点 `(位置, 时刻, 是否播放)`）和最近已知曲目 `recentTrack`（供桌面组件紧凑态展示），并提供 `play()`、`pause()`、`nextTrack()`、`close()`（退出目标播放器进程并清空状态）。
  - 任意时刻的进度 = `位置 + (现在 − 时刻)`（暂停时就是锚点位置）。
  - 来源只在发生事件时更新锚点：换歌、播放/暂停、拖动（`seek(to:at:)`）。
- **编排**：[`AppModel`](../../Sources/SoftLive/App/AppModel.swift) 负责选择跟随的播放器、加载歌词和封面（切歌时同步清空 `recentArtworks` 以防复用上一首旧封面），并维护当前行 `currentIndex`。
  界面上显示的内容都从它读取。
- **手动偏移**：`offset` 是手动校正值（正值表示歌词提前）。换歌时归零。

## 运行路径

1. **来源变化**：`sourceDidChange` 被调用。
   - 刚开始播放的来源接管。
   - 当前来源没在播放时，有其他正在播放的来源就切换过去；都没在播放时，保持当前有曲目的来源，或换成任何一个有曲目的来源。
2. **曲目变了**：重新加载歌词和封面，偏移归零；否则只重新计算当前行。
3. **按时刻切行**：`syncCurrentLine` 算出当前行，并只设一个单次定时器，在下一行开始时再调用自己。
   暂停时不设定时器。

## Apple Music

- **读取**：[`AppleMusicSource`](../../Sources/SoftLive/Playback/AppleMusic/AppleMusicSource.swift) 通过 ScriptingBridge 读取 `playerState`、`currentTrack`、`playerPosition`。
- **事件**：由 `com.apple.Music.playerInfo` 分布式通知触发。
- **拖动**：Music 拖动进度时不发通知，所以播放期间每 2 秒校对一次位置，偏差超过 0.4 秒视为拖动（`seekThreshold`、`seekCheckInterval`）。
- **封面**：从 `currentTrack.artworks` 读取。

## 约束与失败行为

- **不轮询进度**：除上面的 Apple Music 拖动校对外，不加周期性读取。
- **不重新拉起 Music**：脚本对象按正在运行的 Music 的 PID 创建（`runningMusic`）。
  Music 退出时仍会发 `playerInfo` 通知；如果用 bundle ID 创建，一查询就会把它重新启动。
- **授权**：Apple Music 需要「自动化 → Music」授权；没有授权时读不到状态，界面显示未在播放。
- **MediaRemote 不可用**：macOS 15.4 起它不向第三方进程提供数据，本机实测返回空值。
  不借用系统二进制的授权去读它（例如 `mediaremote-adapter`），见 [code-standards](../code-standards.md)。

## 验证

- `swift test --filter "PlaybackStateTests|AppModelTests"`
- Apple Music 播放中的完整流程尚未端到端测试：用户的资料库是空的。
