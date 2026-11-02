# 网易云来源

网易云没有脚本接口，页面也不暴露辅助功能树；MediaRemote 又不可用（见 [播放与同步](playback.md#约束与失败行为)）。
所以 [`NetEaseSource`](../../Sources/SoftLive/Playback/NetEase/NetEaseSource.swift) 读取客户端自己留下的数据。
全部只读、由事件触发，不需要系统权限。数据目录是 `~/Library/Application Support/com.netease.163music/`（`NetEaseClient.dataDirectory`）。

## 职责与事实来源

| 信息 | 来源 | 可靠性（本机实测） |
| --- | --- | --- |
| 哪首歌、何时开始 | `Caches/online_play_cache/<歌曲ID>-_-_<码率>-_-_<hash>.info` 的创建时间（[`NetEasePlayCache`](../../Sources/SoftLive/Playback/NetEase/NetEasePlayCache.swift)） | 原生播放器在开始播放的瞬间创建，窗口在后台也一样；与真实开始时间相差 ≤ 2 秒。同目录的 `.idx!` 在一首歌结束（即下一首开始）时才创建，不能用来判断开始 |
| 缓存看不到的歌（已下载、从缓存重播） | `Documents/storage/sqlite_storage.sqlite3` 的 `historyTracks` 最新一行（[`NetEaseHistory`](../../Sources/SoftLive/Playback/NetEase/NetEaseHistory.swift)） | 由网页脚本写入，窗口在后台时被限流：15 次播放里 5 次没写，2 次晚写 124 秒和 285 秒，时间戳是写入时刻 |
| 歌曲信息 | 历史表那一行；没有就请求网易云歌曲详情接口（`NetEaseAPI.track(songID:)`） | 两种格式都由 [`NetEaseSong`](../../Sources/SoftLive/Network/NetEaseAPI.swift) 解析（接口的 ID 是数字，历史表里是字符串） |
| 播放 / 暂停 | 网易云进程对象的 `kAudioProcessPropertyIsRunningOutput`（[`AudioOutputMonitor`](../../Sources/SoftLive/Support/AudioOutputMonitor.swift)） | Core Audio 公开 API（macOS 14.2+），不需要权限，有变化就通知。暂停时读到 0，播放时读到 1 |
| 进度（用于拖动后同步） | localStorage 的 `lastPlaying`：`Documents/storage/CEFCache/Local Storage/leveldb`（[`NetEaseLastPlaying`](../../Sources/SoftLive/Playback/NetEase/NetEaseLastPlaying.swift)） | 整数秒，约每 2 秒写入一次磁盘，拖动后立即写一次；磁盘上的值比真实进度落后 0.66–1.68 秒。值用客户端内置的固定密钥做了 AES-128-ECB 加密（读法参考 CloudLyrics-for-macOS） |

## 运行路径

1. **判断当前在播哪一次**：缓存目录、数据库或 LevelDB 有变化时调用 `reload()`，由 `NetEasePlay.latest` 选出当前这次播放：
   - 取缓存里创建时间最新的那首歌。
   - 历史表最新一行如果比缓存里同一首歌的开始时间晚、但不超过这首歌的时长，视为同一次播放，开始时间以缓存为准；否则按历史表的时间作为一次新的播放。
   - `lastPlaying` 报告的歌，只有缓存和历史都没看到、且推算的开始时间比当前歌晚 3 秒以上时才采用（`reportLag`）。
     因为换歌后网页还会短暂报告上一首。
   - 取开始时间最晚的那个。
2. **是不是新的一次播放**：`isNewPlay` 判断。同一首歌、开始时间又在它的时长之内，就不是新播放，进度交给第 4 步校准。
   是新播放时：从历史表行或网易云接口取到歌曲信息后，`publish` 发布状态，是否在播放取 `AudioOutputMonitor.isRunning`。
   开始时间早于“现在 − (时长 + 5 秒)”的，视为上次运行留下的，不显示。
3. **播放 / 暂停**：`audioChanged` 把锚点切到播放或暂停。
4. **拖动后同步**：每来一条 `lastPlaying` 记录，就交给 [`ProgressCalibration`](../../Sources/SoftLive/Playback/NetEase/NetEaseLastPlaying.swift) 判断。
   - 每条记录 `n` 表示真实进度在 `[n, n + 2)` 秒之间（`window`），与之前记录给出的范围取交集。
   - 外推进度在范围内：不动，避免每 2 秒重建一次逐字动画。
   - 外推进度在范围外：移到范围中点。
   - 新记录和已有范围完全不重叠（又拖动了一次）：重新开始取交集。
   - 实测：一次 57 s → 69 s 的跳转，记录到达后 2 ms 完成修正。

## 约束与失败行为

- **只读**：网易云的数据库、缓存、LevelDB 都不写。
- **历史表不能单独用来判断换歌**：在后台不可靠，原因见上表。
  播放/暂停也不再读菜单栏「控制」菜单的标题：那种做法要辅助功能权限，还要轮询，后台时也无法保证标题及时更新。
- **LevelDB 的读取**：LevelDB 会轮换 `.log` 文件，要跟到修改时间最新的那个。
  只读新追加的部分，解析不了的记录（例如写到一半被截断）直接跳过；记录的时间用文件的修改时间。
- **读不到进度时**：密钥或格式变了，就读不到 `lastPlaying`。这时退回到「开始时间 + 外推」，只是拖动后不再自动跟上。
- **拖动后的精度**：刚跟上时误差在 1 秒以内（只有整数秒），之后的记录继续收敛。
  改 `window` 之前，先用新的实测数据确认记录值和真实进度之间的差。
- **识别不到的情况**：缓存和历史都没看到、`lastPlaying` 也读不到的歌（例如后台从缓存重播、又读不到进度时），识别不了。
- **离线**：取不到歌曲信息时用占位曲目（`unknownNetEaseSong`），歌词仍按歌曲 ID 请求。
- **Core Audio**：暂停时输出状态切换有多少延迟，尚未观察到。

## 验证

- `swift test --filter "NetEasePlayTests|NetEaseSongTests|NetEaseLastPlayingTests|ProgressCalibrationTests"`
- 运行日志：`/usr/bin/log show --last 10m --info --predicate 'subsystem == "dev.softlive.SoftLive"' --style compact`
  - info 级：换歌、开始/停止输出音频、进度校正。
  - debug 级：每条进度记录，需要用 `log stream --level debug` 实时查看。
