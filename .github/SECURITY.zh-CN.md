# 安全策略 (Security Policy)

[English](SECURITY.md) | **简体中文**

## 支持的版本 (Supported Versions)

目前维护并提供安全修复的版本如下：

| 版本 | 支持状态 |
| --- | --- |
| `0.0.x` / `main` | ✅ 支持 |

## 权限与隐私边界

SoftLive 在设计上严格遵循最小权限与本地只读原则：

- **零遥测与统计**：不包含任何分析 SDK、崩溃上报或私人数据收集逻辑。
- **播放器数据纯只读**：对网易云音乐本地缓存、SQLite 与 LevelDB 仅做本地只读解析；Apple Music 仅通过 macOS 标准 ScriptingBridge（「自动化 → Music」授权）读取播放状态与发起基础控制。
- **系统监控用户态运行**：CPU、内存、温度、功耗、风扇与网速采样均在普通用户态下通过 Mach / BSD / IOKit 接口完成，不安装特权后台 Helper，不请求 root 或辅助功能（Accessibility）权限。
- **网络请求范围**：仅在获取歌词与歌曲元数据时请求网易云音乐公开接口与 [LRCLIB](https://lrclib.net)。

## 报告安全漏洞 (Reporting a Vulnerability)

如果你在 SoftLive 中发现了潜在的安全问题（例如本地文件解析内存安全问题、命令/URL 注入风险、或权限边界缺陷）：

1. **请勿通过公开的 GitHub Issue 提交漏洞细节。**
2. 请直接通过本仓库的 **[GitHub Private Vulnerability Reporting（私密漏洞报告）](https://github.com/DigHuang/SoftLive/security/advisories/new)** 提交报告，附上复现方式、影响范围及修复建议。
3. 维护者会在收到报告后尽快确认并跟进修复，在修复合入后再公开致谢与披露详情。
