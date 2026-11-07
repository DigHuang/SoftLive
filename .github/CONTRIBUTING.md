# Contributing to SoftLive

**English** | [简体中文](CONTRIBUTING.zh-CN.md)

Thank you for your interest in contributing to SoftLive! Please read the guidelines below before opening an issue or pull request.

## Prerequisites

- **OS**: macOS 26.0+
- **Toolchain**: Swift 6.2+ (Xcode 26+)
- **Dependency Policy**: 100% native Swift + AppKit + SwiftUI with **zero third-party dependencies**

## Development Workflow

1. **Read the project specifications and subsystem docs**
   - [Requirements & Non-Goals](../docs/requirements.md): Check target features, acceptance criteria, and explicit non-goals.
   - [Code Standards](../docs/code-standards.md) & [LESSONS.md](../LESSONS.md): Understand module boundaries, default `MainActor` isolation (`isolated deinit`), non-activating panel event handling, resource cleanup, and performance budgets.
   - [Subsystem Reference](../docs/subsystems/README.md): Read the corresponding subsystem page before modifying playback, NetEase local storage parsing, lyrics matching, system monitoring, or UI rendering.
   - If working with an AI coding agent, follow [AGENTS.md](../AGENTS.md).

2. **Build & Test Locally**

   ```bash
   # Run all Swift Testing unit tests (must pass before submitting)
   swift test

   # Verify Release compilation without replacing the running app bundle
   swift build -c release

   # Build build/SoftLive.app and restart SoftLive
   Scripts/build-app.sh --run
   ```

3. **Core Boundaries**
   - **Never bypass system permissions**: Do not piggyback on system binary entitlements to read private frameworks (such as `mediaremote-adapter`), and never circumvent sandboxing, TCC, account authentication, or DRM.
   - **Read-only external data, verified against live samples**: Access third-party client caches/databases (such as NetEase Cloud Music's SQLite and LevelDB) in strictly read-only mode, and never implicitly launch a quit player process during passive observation.
   - **Zero background overhead when hidden**: Short-circuit bitmap rasterization, animation construction, and `TimelineView` schedules when panels are hidden. Measure CPU usage with `top` / `sample` under realistic playback conditions.
   - **Keep documentation in sync**: When a change alters subsystem responsibilities, interfaces, runtime paths, or failure behaviors, update the corresponding page under `docs/subsystems/` in the same commit/PR.

4. **Commit & Pull Request Guidelines**
   - Create a dedicated branch from the latest `main` for each independent task.
   - Follow **Conventional Commits** for commit and PR titles (`feat(stage): ...`, `fix(monitor): ...`, `perf(lyrics): ...`, `docs: ...`).
   - State clearly in your PR description **what was verified** and **what could not be verified** under your local test setup.
