# 歌词

## 职责与事实来源

- **入口**：[`LyricsService`](../../Sources/SoftLive/Lyrics/LyricsService.swift) 为一首曲目找歌词。
  查找顺序：内存缓存 → 磁盘缓存 `~/Library/Caches/SoftLive/Lyrics-v4/<来源>-<ID>.json` → 网络。
- **模型**：[`Lyrics`](../../Sources/SoftLive/Lyrics/Lyrics.swift) 是按时间排序的非空歌词行；一行有起止时间（`time` / `endTime`）、文本、可选的翻译、可选的逐字时间（`LyricWord`）以及演职员表判定（`isCredit`），并提供前奏/间奏区间计算（`interlude(at:)` 与 `nextEventTime(after:)`）。
- **网络来源**：
  - [`NetEaseAPI`](../../Sources/SoftLive/Lyrics/Providers/NetEaseAPI.swift)：歌词、搜索、歌曲详情。
  - [`LRCLibAPI`](../../Sources/SoftLive/Lyrics/Providers/LRCLibAPI.swift)：LRCLIB 搜索。

## 运行路径

1. **网易云曲目**：直接用歌曲 ID 请求 `/api/song/lyric`，参数 `lv=-1&tv=-1&yv=-1`。
   - 有 `yrc` 就用逐字歌词（[`YRCParser`](../../Sources/SoftLive/Lyrics/Parsers/YRCParser.swift)，将词间独立纯空格归并到前一词末尾、丢弃行首行尾空白词，并以末词结束时间 `lastWord.start + max(lastWord.duration, 0.5)` 作为行结束时间 `endTime`——实测网易云 YRC 行头 `[startMs, durationMs]` 常把句间间奏一并算进 `durationMs` 直至下一句起点，不能用行头 `durationMs` 判断唱完时刻），否则用 `lrc`（[`LRCParser`](../../Sources/SoftLive/Lyrics/Parsers/LRCParser.swift)）。
   - `tlyric` 是翻译。
2. **其他曲目**：先搜网易云，再搜 LRCLIB，由 [`TrackMatcher`](../../Sources/SoftLive/Lyrics/TrackMatcher.swift) 选出最匹配的结果。
   - 先清洗标题，去掉 `(Live)`、`[Remastered]`、`- 2011 Remaster`、`feat.` 等后缀。
   - 再按「标题 > 歌手 > 时长」打分；时长相差超过 8 秒的候选直接排除。
3. **翻译对齐與空行过滤**：`Lyrics.init` 先过滤掉纯空白行（实测网易云 LRC 如 `3445957923` 常在每段末句开唱后仅 `0.30–0.74s` 处插入空时间标签 `[mm:ss.xx]` 作为段落空行，保留空行或将其当成句尾标记会在歌词刚唱一个字时就截断当前句），再把每条翻译挂到时间最近的歌词行（相差不超过 0.75 秒，每行最多一条）。
   逐字歌词每行的开始时间和翻译的时间戳本来就有偏差，所以需要这个容差。
4. **前奏、演职员表与间奏识别**：
   - `LyricLine.isCredit` 识别 `作词 / 作曲 / 编曲 / 制作 / 混音 / 录音 / 母带 / 统筹 / 策划 / 企划 / 出品 / 发行 / 原唱 / OP / SP` 等演职员行（连续演职员行之间不进间奏，最后一条演职员行最多展示 `2.5s`）。
   - 首句前纯伴奏或末条演职员行结束后距首句正文的剩余空白 `≥ 5.0s` 时进入前奏 `Interlude`；句间则在当前句唱完后（YRC 为末词结束 `+ 1.5s` 余韵；无逐字时间的 LRC 按慢歌单句最长 `8.0s` 演唱时长计算）且距下一句剩余空白仍 `≥ 7.0s`（即 LRC 两句间隔 `≥ 15.0s`）时才返回 `Interlude(start:end:)`。

## 约束与失败行为

- **版本参数必须是 `-1`**：传正数时，如果服务端存的版本更旧，会返回空文本。
- **不需要加密请求**：`yv=-1` 不经过 eapi 加密就能拿到 YRC。
- **逐字数据不是每首歌都有**：有些歌用网易云普通接口和客户端的加密接口查都没有 YRC，这些歌只能逐行显示。LRCLIB 也没有逐字数据。
- **缓存规则**：
  - 网络失败不缓存，下次播放会重试。
  - “没找到”只在本次运行内记住。
  - 歌词数据结构变化时，要同时升级缓存目录名（当前是 `Lyrics-v4`）。
- **Apple Music 自带歌词不可用**：它是加密的 TTML，接口需要付费的开发者令牌。

## 验证

- `swift test --filter "LRCParserTests|YRCParserTests|TrackMatcherTests"`
