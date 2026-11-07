# 参与贡献 (Contributing to SoftLive)

[English](CONTRIBUTING.md) | **简体中文**

感谢你对 SoftLive 的关注与贡献！在提交 Issue 或 Pull Request 前，请先阅读以下指南。

## 环境要求

- **操作系统**：macOS 26.0+
- **工具链**：Swift 6.2+（Xcode 26+）
- **依赖原则**：原生 Swift + AppKit + SwiftUI 实现，**零第三方依赖**

## 开发流程

1. **阅读项目规范与设计文档**
   - [需求与明确不做事项](../docs/requirements.md)：确认目标功能、验收标准与架构边界。
   - [代码规范](../docs/code-standards.md) 与 [经验教训](../LESSONS.md)：了解模块职责划分、并发隔离（`MainActor` 默认隔离、`isolated deinit`）、非激活面板交互、资源释放与性能要求。
   - [子系统参考](../docs/subsystems/README.md)：修改任一子系统前，先阅读对应页面的运行路径与实测约束。
   - 如使用 AI 编程助手协作，请直接遵循根目录 [AGENTS.md](../AGENTS.md)。

2. **本地构建与测试**

   ```bash
   # 运行全部 Swift Testing 单元测试（提交前必须全部通过）
   swift test

   # 检查 Release 编译（不打包或替换正在运行的 App）
   swift build -c release

   # 构建 build/SoftLive.app 并启动
   Scripts/build-app.sh --run
   ```

3. **核心红线**
   - **不绕过系统权限**：不借用系统二进制授权读取私有框架（如 `mediaremote-adapter`），不触碰沙盒、TCC、账号或版权保护。
   - **外部数据只读且以实测为准**：对网易云音乐等第三方客户端本地缓存/数据库仅做只读访问，被动观察不得隐式拉起退出的播放器进程。
   - **性能与后台零唤醒**：隐藏面板必须短路位图光栅化、动画构建与 `TimelineView` 调度；界面与采样改动需在真实场景下用 `top` / `sample` 验证 CPU 开销。
   - **文档同步**：改动影响到子系统职责、接口、运行路径或失败行为时，必须在同一次改动中更新 `docs/subsystems/` 对应文档。

4. **提交与 Pull Request 规范**
   - 每个独立任务从最新 `main` 切出独立分支。
   - Commit 标题采用 Conventional Commits 格式（如 `feat(stage): ...`、`fix(monitor): ...`、`perf(lyrics): ...`、`docs: ...`）。
   - 在 PR 描述中如实写明**已验证的场景**与**受条件限制尚未验证的部分**。
