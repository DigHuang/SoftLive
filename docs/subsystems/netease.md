# 网易云来源

网易云没有脚本接口，页面也不暴露辅助功能树；MediaRemote 又不可用（见 [播放与同步](playback.md#约束与失败行为)）。
所以 [`NetEaseSource`](../../Sources/SoftLive/Playback/NetEase/NetEaseSource.swift) 读取客户端自己留下的数据。
全部只读、由事件触发，不需要系统权限。数据目录是 `~/Library/Application Support/com.netease.163music/`（`NetEaseClient.dataDirectory`）。

## 职责与事实来源

| 信息 | 来源 | 可靠性（本机实测） |
| --- | --- | --- |
| 哪首歌、何时开始 | `Caches/online_play_cache/<歌曲ID>-_-_<码率>-_-_<hash>.info` 的创建时间（[`NetEasePlayCache`](../../Sources/SoftLive/Playback/NetEase/NetEasePlayCache.swift)） | 原生下载器在开始请求音频流的瞬间创建，窗口在后台也一样；由于建连、缓冲和无损解码耗时，文件创建时间比音频实际开始出声早 0.5–2.0 秒，开播几秒内由 `ProgressCalibration` 根据 `lastPlaying` 校准对齐。同目录的 `.idx!` 在一首歌结束（即下一首开始）时才创建，不能用来判断开始 |
| 缓存看不到的歌（已下载、从缓存重播） | `Documents/storage/sqlite_storage.sqlite3` 的 `historyTracks` 最新一行（[`NetEaseHistory`](../../Sources/SoftLive/Playback/NetEase/NetEaseHistory.swift)）+ localStorage 的 `playingInfo` / `lastPlaying` | `historyTracks` 由网页脚本写入，窗口在后台时被限流（15 次播放里 5 次没写，2 次晚写 124 秒和 285 秒）；而 LevelDB 里的 `playingInfo` 与 `lastPlaying` 在后台同样按时落盘 |
| 歌曲信息 | 历史表最新一行或 LevelDB `playingInfo.curTrack`；都没有时请求网易云歌曲详情接口（`NetEaseAPI.track(songID:)`） | 三种来源都由 [`NetEaseSong`](../../Sources/SoftLive/Network/NetEaseAPI.swift) 解析（接口的 ID 是数字，历史表与 `playingInfo` 里是字符串） |
| 播放 / 暂停 | localStorage 的 `playingInfo.playingState`（`2` = 播放，`1` = 暂停），辅以 `lastPlaying` 的 4 秒静默超时（[`NetEaseLastPlaying`](../../Sources/SoftLive/Playback/NetEase/NetEaseLastPlaying.swift)） | 实测点击暂停或继续后，网页更新 `playingInfo` 并在 0.8–1.0 秒内落盘到 LevelDB `.log`；暂停状态下拖动进度条只会更新 `lastPlaying` 而保持暂停状态；播放期间 `lastPlaying` 每 1.5–2.0 秒落盘一次，暂停期间完全停止周期写入 |
| 进度（用于开播缓冲校准与拖动后同步） | localStorage 的 `lastPlaying`：`Documents/storage/CEFCache/Local Storage/leveldb/*.log`（[`NetEaseLastPlaying`](../../Sources/SoftLive/Playback/NetEase/NetEaseLastPlaying.swift)） | 整数秒（`floor`），播放期间约每 1.8 秒写入一次磁盘，拖动后立即写一次；由相邻两条记录 `1.03s` 内从 `226` 跳到 `228` 实测可得，落盘时刻的真实进度在 `[n, n + 1.2)` 秒之间（之前测出的 `0.66–1.68` 秒实际混入了 `.info` 早于真音频出声的缓冲耗时）。`lastPlaying` 与 `playingInfo` 都用客户端内置的固定密钥做了 AES-128-ECB 加密（读法参考 CloudLyrics-for-macOS） |
| 反向控制（播放 / 暂停 / 下一首 / 关闭） | `orpheus://<base64(json)>` URL Scheme（`{"cmd":"resume"}`、`{"cmd":"pause"}`、`{"cmd":"next"}`），通过 `NSWorkspace.OpenConfiguration(activates: false)` 后台投递；关闭通过 `NSRunningApplication.terminate()` | `resume` 幂等，调用时同步通过 `noteSongStarted()` 启动 4 秒超时检测；冷启动时首个 URL 事件早于 CEF 页面注册消息处理器，因此后台补发 3 次以确保冷启动恢复播放 |

## 运行路径

1. **判断当前在播哪一次**：缓存目录、数据库或 LevelDB 有变化时调用 `reload()`，由 `NetEasePlay.latest` 选出当前这次播放：
   - 取缓存里创建时间最新的那首歌。
   - 历史表最新一行如果比缓存里同一首歌的开始时间晚、但不超过这首歌的时长，视为同一次播放，开始时间以缓存为准；否则按历史表的时间作为一次新的播放。
   - LevelDB 报告的歌（`lastPlaying` 或 `playingInfo` 切歌），只有缓存和历史都没看到、且推算的开始时间比当前歌晚 3 秒以上时才采用（`reportLag`）。
     因为换歌后网页可能还会短暂报告上一首。
   - 取开始时间最晚的那个。
2. **是不是新的一次播放**：`isNewPlay` 判断。同一首歌在当前播放位置尚未到达歌曲结尾前，后续由历史表晚写或暂停后恢复带来的开始时间重算都视为同一次播放，进度交给第 4 步校准。
   是新播放时：优先从历史表行或 `playingInfo.curTrack` 取歌曲信息，都没有再请求网易云接口；`publish` 发布状态，是否在播放取 `NetEaseLastPlaying.isPlaying`（新歌刚由 `.info` 触发、LevelDB 尚未落盘时先视为播放并启动 4 秒超时检测）。
   不再处于播放状态且开始时间早于“现在 − (时长 + 5 秒)”的，视为上次运行留下的，不显示；若之后用户在网易云继续播放该曲目，再按最新进度发布。
3. **播放 / 暂停**：`playingChanged` 在收到 `playingInfo.playingState` 变化或 `lastPlaying` 超时（4 秒无新记录）时，把锚点切到播放或暂停并重置校准窗口。暂停期间拖动进度条只更新锚点位置、不触发恢复播放。
4. **拖动后同步**：每来一条 `lastPlaying` 记录，就交给 [`ProgressCalibration`](../../Sources/SoftLive/Playback/NetEase/NetEaseLastPlaying.swift) 判断。
   - 每条记录 `n` 表示真实进度在 `[n, n + 1.2)` 秒之间（`window`），与之前记录给出的范围取交集。
   - 外推进度在范围内：不动，避免每 2 秒重建一次逐字动画。
   - 外推进度在范围外：移到范围中点。
   - 新记录和已有范围完全不重叠（又拖动了一次）：重新开始取交集。
   - 实测：一次 57 s → 69 s 的跳转，记录到达后 2 ms 完成修正。

## 约束与失败行为

- **只读**：网易云的数据库、缓存、LevelDB 都不写。
- **历史表不能单独用来判断换歌**：在后台不可靠，原因见上表。
  播放/暂停不读菜单栏「控制」菜单的标题（需要辅助功能权限且要轮询），也不用 Core Audio 的 `kAudioProcessPropertyIsRunningOutput`（实测网易云暂停后会保持音频流开启并输出静音长达数小时，`IsRunningOutput` 一直为 `1`）。
- **LevelDB 的读取**：LevelDB 会轮换 `.log` 文件，要跟到修改时间最新的那个，切换前先读完旧文件末尾。
  只读新追加的部分：跨越 32 KiB（`32768` 字节）LevelDB 块边界的记录（如约 13 KB 的 `playingInfo`）会在边界处插入 7 字节的块续写头，读取时按文件偏移跳过；末尾写到一半被截断的记录保留其标记留待下次续读，其余解析不了的记录直接跳过；记录的时间用文件的修改时间。
- **读不到进度时**：密钥或格式变了，就读不到 `lastPlaying` 和 `playingInfo`。这时退回到「开始时间 + 外推」，只是拖动和暂停后不再自动跟上。
- **拖动后的精度**：刚跟上时误差在 1 秒以内（只有整数秒），之后的记录继续收敛。
  改 `window` 之前，先用新的实测数据确认记录值和真实进度之间的差。
- **识别不到的情况**：缓存和历史都没看到、LevelDB 也读不到的歌，识别不了。
- **离线**：取不到歌曲信息时用占位曲目（`unknownNetEaseSong`），歌词仍按歌曲 ID 请求。

## 验证

- `swift test --filter "NetEasePlayTests|NetEaseSongTests|NetEaseLastPlayingTests|ProgressCalibrationTests"`
- 运行日志：`/usr/bin/log show --last 10m --info --predicate 'subsystem == "dev.softlive.SoftLive"' --style compact`
  - info 级：换歌、暂停/继续播放、进度校正。
  - debug 级：每条进度记录，需要用 `log stream --level debug` 实时查看。
