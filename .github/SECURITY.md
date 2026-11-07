# Security Policy

**English** | [简体中文](SECURITY.zh-CN.md)

## Supported Versions

Security updates are provided for the following versions:

| Version | Supported |
| --- | --- |
| `0.0.x` / `main` | ✅ Yes |

## Permission & Privacy Model

SoftLive is designed around strict least-privilege and local read-only boundaries:

- **Zero Telemetry**: No analytics SDKs, crash reporters, or user-tracking endpoints are included.
- **Strictly Read-Only Player Access**: NetEase Cloud Music's local streaming cache, SQLite database, and Chromium LevelDB logs are accessed in read-only mode; Apple Music is accessed solely through standard macOS `ScriptingBridge` (**Automation → Music** user consent).
- **User-Space System Monitoring**: CPU, memory, thermal, power, fan, and network metrics are sampled in unprivileged user space via Mach, BSD, and IOKit APIs — no privileged helper daemon, root access, or Accessibility permission is required.
- **Network Scope**: Outbound network requests are made only to public NetEase Cloud Music and [LRCLIB](https://lrclib.net) endpoints when fetching lyrics and track metadata.

## Reporting a Vulnerability

If you discover a security vulnerability in SoftLive (for example, memory-safety issues when parsing local log/database files, URL/command injection risks, or permission boundary flaws):

1. **Please do NOT report the vulnerability in a public GitHub issue.**
2. Submit a report privately via **[GitHub Private Vulnerability Reporting](https://github.com/DigHuang/SoftLive/security/advisories/new)** with reproduction steps, impact assessment, and any suggested remediation.
3. The maintainer will review and respond promptly, and coordinate public disclosure and credit once a fix is released.
