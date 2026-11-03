# 歌词

## 职责与事实来源

- **入口**：[`LyricsService`](../../Sources/SoftLive/Lyrics/LyricsService.swift) 为一首曲目找歌词。
  查找顺序：内存缓存 → 磁盘缓存 `~/Library/Caches/SoftLive/Lyrics-v2/<来源>-<ID>.json` → 网络。
- **模型**：[`Lyrics`](../../Sources/SoftLive/Lyrics/Lyrics.swift) 是按时间排序的若干行；一行有文本、可选的翻译和可选的逐字时间（`LyricWord`）。
- **网络来源**：
  - [`NetEaseAPI`](../../Sources/SoftLive/Network/NetEaseAPI.swift)：歌词、搜索、歌曲详情。
  - [`LRCLibAPI`](../../Sources/SoftLive/Network/LRCLibAPI.swift)：LRCLIB 搜索。

## 运行路径

1. **网易云曲目**：直接用歌曲 ID 请求 `/api/song/lyric`，参数 `lv=-1&tv=-1&yv=-1`。
   - 有 `yrc` 就用逐字歌词（[`YRCParser`](../../Sources/SoftLive/Lyrics/Parsers/YRCParser.swift)），否则用 `lrc`（[`LRCParser`](../../Sources/SoftLive/Lyrics/Parsers/LRCParser.swift)）。
   - `tlyric` 是翻译。
2. **其他曲目**：先搜网易云，再搜 LRCLIB，由 [`TrackMatcher`](../../Sources/SoftLive/Lyrics/TrackMatcher.swift) 选出最匹配的结果。
   - 先清洗标题，去掉 `(Live)`、`[Remastered]`、`- 2011 Remaster`、`feat.` 等后缀。
   - 再按「标题 > 歌手 > 时长」打分；时长相差超过 8 秒的候选直接排除。
3. **翻译对齐**：每条翻译挂到时间最近的非空歌词行，相差不超过 0.75 秒，每行最多一条。
   逐字歌词每行的开始时间和翻译的时间戳本来就有偏差，所以需要这个容差。

## 约束与失败行为

- **版本参数必须是 `-1`**：传正数时，如果服务端存的版本更旧，会返回空文本。
- **不需要加密请求**：`yv=-1` 不经过 eapi 加密就能拿到 YRC。
- **逐字数据不是每首歌都有**：有些歌用网易云普通接口和客户端的加密接口查都没有 YRC，这些歌只能逐行显示。LRCLIB 也没有逐字数据。
- **缓存规则**：
  - 网络失败不缓存，下次播放会重试。
  - “没找到”只在本次运行内记住。
  - 歌词数据结构变化时，要同时升级缓存目录名（当前是 `Lyrics-v2`）。
- **Apple Music 自带歌词不可用**：它是加密的 TTML，接口需要付费的开发者令牌。

## 验证

- `swift test --filter "LRCParserTests|YRCParserTests|TrackMatcherTests"`
