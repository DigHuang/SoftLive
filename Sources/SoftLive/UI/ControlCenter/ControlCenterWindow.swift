import AppKit
import Observation
import SwiftUI

enum ControlCenterSection: String, CaseIterable, Identifiable, Sendable {
    case player
    case monitor
    case cleaner
    case about

    static let navigationTabs: [ControlCenterSection] = [.player, .monitor, .cleaner]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .player: L10n.tr("播放器", "Player")
        case .monitor: L10n.tr("监听", "Monitor")
        case .cleaner: L10n.tr("清理", "Cleaner")
        case .about: L10n.tr("产品说明", "About")
        }
    }

    var icon: String {
        switch self {
        case .player: "music.note"
        case .monitor: "gauge.with.dots.needle.67percent"
        case .cleaner: "sparkles"
        case .about: "info.circle"
        }
    }

    var badgeColor: Color {
        switch self {
        case .player: MonitorPalette.cyan
        case .monitor: MonitorPalette.indigo
        case .cleaner: MonitorPalette.emerald
        case .about: MonitorPalette.teal
        }
    }
}

@Observable
final class ControlCenterState {
    var isOpen = false
    var selectedSection: ControlCenterSection = {
        if let raw = ProcessInfo.processInfo.environment["SOFTLIVE_INITIAL_SECTION"],
           let initial = ControlCenterSection(rawValue: raw) {
            return initial
        }
        return .player
    }()
    var windowSize: NSSize = ControlCenterWindow.defaultSize
}

/// Unified macOS desktop configuration center with a clean left-right split layout (`播放器` / `监听` / `清理` + bottom brand entry for `产品说明`).
/// Supports user window resizing with an enforced minimum size constraint (`740 × 640 pt`) and unloads its SwiftUI subtree when closed.
final class ControlCenterWindow: NSWindow, NSWindowDelegate {
    static let defaultSize = NSSize(width: 780, height: 680)
    static let minWindowSize = NSSize(width: 740, height: 640)
    static var windowSize: NSSize { defaultSize }
    private static let frameAutosave = "SoftLiveControlCenterWindow"

    let state = ControlCenterState()
    let cleaner: DiskCleaner

    override var minSize: NSSize {
        get { Self.minWindowSize }
        set { super.minSize = Self.minWindowSize }
    }

    override var contentMinSize: NSSize {
        get { Self.minWindowSize }
        set { super.contentMinSize = Self.minWindowSize }
    }

    init(
        model: PlaybackModel,
        monitor: SystemMonitor,
        cleaner: DiskCleaner? = nil,
        preferences: Preferences
    ) {
        let resolvedCleaner = cleaner ?? DiskCleaner(preferences: preferences)
        self.cleaner = resolvedCleaner
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        title = "SoftLive"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        collectionBehavior = [.moveToActiveSpace, .fullScreenNone]
        standardWindowButton(.zoomButton)?.isEnabled = true
        delegate = self

        let rootView = ControlCenterView(
            model: model,
            monitor: monitor,
            cleaner: resolvedCleaner,
            preferences: preferences,
            state: state
        )
        let host = NSHostingView(rootView: rootView)
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        host.frame = NSRect(origin: .zero, size: Self.defaultSize)
        contentView = host

        // Set `minSize` and `contentMinSize` AFTER assigning `contentView = host` so AppKit does not reset them.
        minSize = Self.minWindowSize
        contentMinSize = Self.minWindowSize

        let restored = setFrameUsingName(Self.frameAutosave)
        setFrameAutosaveName(Self.frameAutosave)
        if restored {
            let targetWidth = max(frame.width, Self.minWindowSize.width)
            let targetHeight = max(frame.height, Self.minWindowSize.height)
            if abs(frame.width - targetWidth) > 0.5 || abs(frame.height - targetHeight) > 0.5 {
                setFrame(
                    NSRect(
                        x: frame.minX,
                        y: frame.maxY - targetHeight,
                        width: targetWidth,
                        height: targetHeight
                    ),
                    display: false
                )
            }
        } else if let screen = NSScreen.main?.visibleFrame {
            let origin = NSPoint(
                x: round(screen.midX - Self.defaultSize.width / 2),
                y: round(screen.midY - Self.defaultSize.height / 2)
            )
            setFrameOrigin(origin)
        }
        state.windowSize = frame.size
    }

    func show(section: ControlCenterSection? = nil) {
        if let section {
            state.selectedSection = section
        }
        minSize = Self.minWindowSize
        contentMinSize = Self.minWindowSize
        let targetWidth = max(frame.width, Self.minWindowSize.width)
        let targetHeight = max(frame.height, Self.minWindowSize.height)
        if abs(frame.width - targetWidth) > 0.5 || abs(frame.height - targetHeight) > 0.5 {
            setFrame(
                NSRect(
                    x: frame.minX,
                    y: frame.maxY - targetHeight,
                    width: targetWidth,
                    height: targetHeight
                ),
                display: false
            )
        }
        state.windowSize = frame.size
        state.isOpen = true
        contentView?.isHidden = false
        contentView?.frame = NSRect(origin: .zero, size: frame.size)
        NSApp.activate()
        makeKeyAndOrderFront(nil)
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        NSSize(
            width: max(frameSize.width, Self.minWindowSize.width),
            height: max(frameSize.height, Self.minWindowSize.height)
        )
    }

    func windowDidResize(_ notification: Notification) {
        state.windowSize = frame.size
        contentView?.frame = NSRect(origin: .zero, size: frame.size)
    }

    func windowWillClose(_ notification: Notification) {
        cleaner.cancelInFlightScan()
        state.isOpen = false
        contentView?.isHidden = true
    }
}

struct ControlCenterView: View {
    static let sidebarWidth: CGFloat = 168
    private static let githubURL = URL(string: "https://github.com/DigHuang/SoftLive")!

    let model: PlaybackModel
    let monitor: SystemMonitor
    let cleaner: DiskCleaner
    let preferences: Preferences
    let state: ControlCenterState

    init(
        model: PlaybackModel,
        monitor: SystemMonitor,
        cleaner: DiskCleaner? = nil,
        preferences: Preferences,
        state: ControlCenterState
    ) {
        self.model = model
        self.monitor = monitor
        self.cleaner = cleaner ?? DiskCleaner(preferences: preferences)
        self.preferences = preferences
        self.state = state
    }

    @Environment(\.colorScheme) private var colorScheme

    private var appVersionString: String {
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.2"
        return "v\(ver)"
    }

    var body: some View {
        if !state.isOpen {
            Color.clear.frame(width: 0, height: 0)
        } else {
            let winWidth = max(state.windowSize.width, ControlCenterWindow.minWindowSize.width)
            let winHeight = max(state.windowSize.height, ControlCenterWindow.minWindowSize.height)
            let rightWidth = max(winWidth - Self.sidebarWidth - 0.5, 400)

            HStack(alignment: .top, spacing: 0) {
                sidebar
                    .frame(width: Self.sidebarWidth, height: winHeight, alignment: .topLeading)

                Rectangle()
                    .fill(dividerColor)
                    .frame(width: 0.5, height: winHeight)

                detailPane
                    .frame(width: rightWidth, height: winHeight, alignment: .topLeading)
                    .clipped()
            }
            .frame(width: winWidth, height: winHeight, alignment: .topLeading)
            .background(windowBackground)
            .ignoresSafeArea()
        }
    }

    // MARK: - Window Surface

    private var windowBackground: some View {
        let isDark = colorScheme == .dark
        return Rectangle()
            .fill(
                isDark
                    ? Color(red: 0.08, green: 0.09, blue: 0.12)
                    : Color(red: 0.96, green: 0.965, blue: 0.975)
            )
    }

    // MARK: - Left Sidebar (168 pt)

    private var sidebar: some View {
        let isDark = colorScheme == .dark
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(ControlCenterSection.navigationTabs) { section in
                sidebarItem(section)
            }

            Spacer(minLength: 0)

            brandFooterEntry
        }
        .padding(.top, 50)
        .padding(.bottom, 16)
        .padding(.horizontal, 12)
        .background(
            isDark
                ? Color.white.opacity(0.025)
                : Color.black.opacity(0.028)
        )
    }

    private func sidebarItem(_ section: ControlCenterSection) -> some View {
        let isSelected = state.selectedSection == section
        let isDark = colorScheme == .dark

        return HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                    .fill(
                        isSelected
                            ? section.badgeColor
                            : (isDark ? Color.white.opacity(0.09) : Color.black.opacity(0.06))
                    )
                Image(systemName: section.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isSelected ? .white : .secondary)
            }
            .frame(width: 24, height: 24)

            Text(section.title)
                .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isDark ? Color.white.opacity(0.11) : Color.black.opacity(0.065))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture {
            withAnimation(.snappy(duration: 0.16)) {
                state.selectedSection = section
            }
        }
    }

    private var brandFooterEntry: some View {
        let isSelected = state.selectedSection == .about
        let isDark = colorScheme == .dark

        return HStack(spacing: 10) {
            Image(nsImage: BrandAssets.appIcon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 24, height: 24)

            Text("SoftLive")
                .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isDark ? Color.white.opacity(0.11) : Color.black.opacity(0.065))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture {
            withAnimation(.snappy(duration: 0.16)) {
                state.selectedSection = .about
            }
        }
    }

    // MARK: - Right Detail Pane

    private var detailPane: some View {
        Group {
            switch state.selectedSection {
            case .player:
                playerSettings
            case .monitor:
                monitorSettings
            case .cleaner:
                CleanerPaneView(cleaner: cleaner, preferences: preferences)
            case .about:
                aboutProductView
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 28)
        .padding(.bottom, 22)
    }

    // MARK: - Tab 1: 播放器

    private var playerSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            formGroup(title: L10n.tr("音源与状态栏", "Source & Status Bar")) {
                formRow(L10n.tr("首选播放器", "Preferred Player")) {
                    segmentedPicker(
                        options: PlayerKind.allCases,
                        selection: preferences.preferredPlayer,
                        label: { $0.displayName },
                        icon: { $0.icon }
                    ) {
                        preferences.preferredPlayer = $0
                    }
                }

                rowDivider

                formToggleRow(L10n.tr("桌面常驻组件", "Desktop Widget"), isOn: Binding(
                    get: { preferences.showsDesktopWidget },
                    set: { preferences.showsDesktopWidget = $0 }
                ))

                rowDivider

                formToggleRow(L10n.tr("状态栏歌词", "Status Bar Lyrics"), isOn: Binding(
                    get: { preferences.showsStatusBarLyrics },
                    set: { preferences.showsStatusBarLyrics = $0 }
                ))

                rowDivider

                formRow(L10n.tr("状态栏最大宽度", "Status Bar Max Width")) {
                    segmentedPicker(
                        options: StatusBarWidthPreset.allCases,
                        selection: preferences.statusBarWidthPreset,
                        label: { $0.displayName }
                    ) {
                        preferences.statusBarWidthPreset = $0
                    }
                }
            }

            formGroup(title: L10n.tr("桌面悬浮歌词", "Desktop Lyrics")) {
                formToggleRow(L10n.tr("显示桌面歌词", "Show Desktop Lyrics"), isOn: Binding(
                    get: { preferences.showsDesktopLyrics },
                    set: { preferences.showsDesktopLyrics = $0 }
                ))

                rowDivider

                formToggleRow(L10n.tr("锁定鼠标穿透（按住 ⌘ 唤醒）", "Click-Through Lock (Hold ⌘ to Wake)"), isOn: Binding(
                    get: { preferences.desktopLyricsLocked },
                    set: { preferences.desktopLyricsLocked = $0 }
                ))

                rowDivider

                formRow(L10n.tr("歌词字号", "Font Size")) {
                    segmentedPicker(
                        options: DesktopLyricsSize.allCases,
                        selection: preferences.desktopLyricsSize,
                        label: { $0.displayName }
                    ) {
                        preferences.desktopLyricsSize = $0
                    }
                }

                rowDivider

                formRow(L10n.tr("副句内容", "Subline Mode")) {
                    segmentedPicker(
                        options: DesktopLyricsSublineMode.allCases,
                        selection: preferences.desktopLyricsSublineMode,
                        label: { $0.displayName }
                    ) {
                        preferences.desktopLyricsSublineMode = $0
                    }
                }
            }

            formGroup(title: L10n.tr("演示舞台", "Stage Mode")) {
                formToggleRow(L10n.tr("开启演示舞台", "Enable Stage Window"), isOn: Binding(
                    get: { preferences.showsStageWindow },
                    set: { preferences.showsStageWindow = $0 }
                ))

                rowDivider

                formRow(L10n.tr("律动风格", "Kinetic Style")) {
                    segmentedPicker(
                        options: StageStyle.allCases,
                        selection: preferences.stageStyle,
                        label: { $0.displayName }
                    ) {
                        preferences.stageStyle = $0
                    }
                }

                rowDivider

                formToggleRow(L10n.tr("星火粒子特效", "Spark Particles"), isOn: Binding(
                    get: { preferences.stageSparks },
                    set: { preferences.stageSparks = $0 }
                ))
            }
        }
    }

    // MARK: - Tab 2: 监听

    private var monitorSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            formGroup(title: L10n.tr("状态栏与面板", "Status Bar & Popover")) {
                formToggleRow(L10n.tr("显示状态栏监控", "Show System Monitor"), isOn: Binding(
                    get: { preferences.showsSystemMonitor },
                    set: { preferences.showsSystemMonitor = $0 }
                ))

                rowDivider

                formRow(L10n.tr("状态栏样式", "Status Bar Style")) {
                    segmentedPicker(
                        options: MonitorStatusBarStyle.allCases,
                        selection: preferences.monitorStatusBarStyle,
                        label: { $0.displayName }
                    ) {
                        preferences.monitorStatusBarStyle = $0
                    }
                }

                rowDivider

                formToggleRow(L10n.tr("柱状图彩色显示", "Colored Bars"), isOn: Binding(
                    get: { preferences.monitorColoredBars },
                    set: { preferences.monitorColoredBars = $0 }
                ))

                rowDivider

                formRow(L10n.tr("弹窗默认页面", "Default Popover Tab")) {
                    segmentedPicker(
                        options: MonitorTab.allCases,
                        selection: preferences.monitorDefaultTab,
                        label: { $0.rawValue }
                    ) {
                        preferences.monitorDefaultTab = $0
                    }
                }
            }

            formGroup(title: L10n.tr("采样与告警阈值", "Sampling & Alert Thresholds")) {
                formRow(L10n.tr("采样间隔", "Refresh Interval")) {
                    segmentedPicker(
                        options: MonitorSampleInterval.allCases,
                        selection: preferences.monitorSampleInterval,
                        label: { $0.displayName }
                    ) {
                        preferences.monitorSampleInterval = $0
                    }
                }

                rowDivider

                formRow(L10n.tr("CPU 告警阈值", "CPU Alert Threshold")) {
                    segmentedPicker(
                        options: MonitorCPUAlertThreshold.allCases,
                        selection: preferences.monitorCPUAlertThreshold,
                        label: { $0.displayName }
                    ) {
                        preferences.monitorCPUAlertThreshold = $0
                    }
                }

                rowDivider

                formRow(L10n.tr("内存告警阈值", "RAM Alert Threshold")) {
                    segmentedPicker(
                        options: MonitorRAMAlertThreshold.allCases,
                        selection: preferences.monitorRAMAlertThreshold,
                        label: { $0.displayName }
                    ) {
                        preferences.monitorRAMAlertThreshold = $0
                    }
                }

                rowDivider

                formRow(L10n.tr("温度告警阈值", "Temp Alert Threshold")) {
                    segmentedPicker(
                        options: MonitorThermalAlertThreshold.allCases,
                        selection: preferences.monitorThermalAlertThreshold,
                        label: { $0.displayName }
                    ) {
                        preferences.monitorThermalAlertThreshold = $0
                    }
                }
            }
        }
    }

    // MARK: - Tab 3: 产品说明 (About & Guide)

    private var aboutProductView: some View {
        let isDark = colorScheme == .dark
        return VStack(alignment: .leading, spacing: 18) {
            formGroup(title: L10n.tr("关于应用", "About")) {
                HStack(spacing: 14) {
                    Image(nsImage: BrandAssets.appIcon)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 52, height: 52)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text("SoftLive")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.primary)
                            Text(appVersionString)
                                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                .foregroundStyle(MonitorPalette.cyan)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(MonitorPalette.cyan.opacity(0.14), in: .capsule)
                        }
                        Text(L10n.tr("macOS 原生实时逐字歌词、硬件遥测与空间清理", "Native Lyrics, Hardware Telemetry & Space Cleaner"))
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 4) {
                        Text("GitHub")
                            .font(.system(size: 11.5, weight: .medium))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 11)
                    .frame(height: 26)
                    .background(
                        isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.05),
                        in: .capsule
                    )
                    .overlay {
                        Capsule().strokeBorder(borderColor, lineWidth: 0.5)
                    }
                    .contentShape(.capsule)
                    .onTapGesture {
                        NSWorkspace.shared.open(Self.githubURL)
                    }
                }
                .padding(14)
            }

            formGroup(title: L10n.tr("通用设置", "General")) {
                formRow(L10n.tr("界面语言", "Language")) {
                    segmentedPicker(
                        options: AppLanguage.allCases,
                        selection: preferences.language,
                        label: { $0.displayName }
                    ) {
                        preferences.language = $0
                    }
                }
            }

            formGroup(title: L10n.tr("交互指南", "Interaction Guide")) {
                guideRow(
                    icon: "text.quote",
                    title: L10n.tr("桌面悬浮歌词", "Desktop Floating Lyrics"),
                    detail: L10n.tr("默认鼠标穿透；按住 ⌘ 移入唤醒，支持 ±0.5s 偏移与双击切歌", "Click-through; hold ⌘ to wake, ±0.5s offset & double-click skip")
                )
                rowDivider
                guideRow(
                    icon: "rectangle.on.rectangle.angled",
                    title: L10n.tr("桌面组件与演示舞台", "Desktop Widget & Stage Window"),
                    detail: L10n.tr("随专辑封面实时提取流光色盘，支持自由拖动与双击切下一首", "Live album-art aurora palette; drag freely or double-click to skip")
                )
                rowDivider
                guideRow(
                    icon: "menubar.rectangle",
                    title: L10n.tr("状态栏歌词与硬件监控", "Status Bar Lyrics & Telemetry"),
                    detail: L10n.tr("左键点击监控项展开 CPU / 内存 / 温度面板，右键呼出快捷菜单", "Left-click for CPU / RAM / TMP popover; right-click for menu")
                )
            }

            formGroup(title: L10n.tr("架构与隐私承诺", "Architecture & Privacy")) {
                guideRow(
                    icon: "lock.shield",
                    title: L10n.tr("纯本地只读 · 最小权限", "Read-Only Local Access · Minimal Permissions"),
                    detail: L10n.tr("网易云零系统授权，Apple Music 仅需自动化权限，只读不写", "Zero permissions for NetEase; Automation-only for Apple Music")
                )
                rowDivider
                guideRow(
                    icon: "bolt.horizontal.circle",
                    title: L10n.tr("原生低功耗架构", "Native Low-Power Engine"),
                    detail: L10n.tr("Swift 6.2 + AppKit + Core Animation 硬件加速，零第三方依赖", "Swift 6.2 + AppKit + Core Animation, zero dependencies")
                )
            }
        }
    }

    private func guideRow(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(MonitorPalette.cyan)
                .frame(width: 22, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.system(size: 11.5, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
    }

    // MARK: - Form Building Blocks

    private var dividerColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.06)
    }

    private var borderColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.10)
            : Color.black.opacity(0.06)
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(dividerColor)
            .frame(height: 0.5)
    }

    private func formGroup<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isDark = colorScheme == .dark
        return VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isDark ? Color.white.opacity(0.05) : Color.white)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(borderColor, lineWidth: 0.5)
                    }
            }
        }
    }

    private func formRow<Control: View>(
        _ title: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            control()
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 16)
        .frame(height: 42)
    }

    private func formToggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .frame(height: 42)
    }

    private func segmentedPicker<Option: Hashable>(
        options: [Option],
        selection: Option,
        label: @escaping (Option) -> String,
        icon: ((Option) -> NSImage?)? = nil,
        onSelect: @escaping (Option) -> Void
    ) -> some View {
        let isDark = colorScheme == .dark
        let hasIcons = icon != nil
        let segmentMinWidth: CGFloat = hasIcons ? 96 : (options.count == 2 ? 64 : 62)

        return HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                HStack(spacing: 5) {
                    if let iconImage = icon?(option) {
                        Image(nsImage: iconImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 14, height: 14)
                    }
                    Text(label(option))
                        .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                        .fixedSize(horizontal: true, vertical: false)
                }
                .foregroundStyle(isSelected ? .primary : .secondary)
                .padding(.horizontal, 10)
                .frame(minWidth: segmentMinWidth, minHeight: 24, maxHeight: 24)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(isDark ? Color.white.opacity(0.16) : Color.white)
                            .shadow(color: .black.opacity(isDark ? 0.22 : 0.06), radius: 2, y: 1)
                            .overlay {
                                Capsule().strokeBorder(borderColor, lineWidth: 0.5)
                            }
                    }
                }
                .contentShape(.capsule)
                .onTapGesture {
                    withAnimation(.snappy(duration: 0.16)) {
                        onSelect(option)
                    }
                }
            }
        }
        .padding(3)
        .background(
            isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.05),
            in: .capsule
        )
    }
}
