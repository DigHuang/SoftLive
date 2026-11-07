import AppKit
import Observation
import SwiftUI

enum ControlCenterSection: String, CaseIterable, Identifiable, Sendable {
    case player
    case monitor
    case about

    static let navigationTabs: [ControlCenterSection] = [.player, .monitor]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .player: "播放器"
        case .monitor: "监听"
        case .about: "产品说明"
        }
    }

    var icon: String {
        switch self {
        case .player: "music.note"
        case .monitor: "gauge.with.dots.needle.67percent"
        case .about: "info.circle"
        }
    }

    var badgeColor: Color {
        switch self {
        case .player: MonitorPalette.cyan
        case .monitor: MonitorPalette.indigo
        case .about: MonitorPalette.teal
        }
    }
}

@Observable
final class ControlCenterState {
    var isOpen = false
    var selectedSection: ControlCenterSection = .player
}

/// Unified macOS desktop configuration center with a clean left-right split layout (`播放器` / `监听` + bottom brand entry for `产品说明`).
/// Unloads its SwiftUI subtree when closed so background CPU overhead remains strictly zero.
final class ControlCenterWindow: NSWindow, NSWindowDelegate {
    static let windowSize = NSSize(width: 640, height: 636)
    private static let frameAutosave = "SoftLiveControlCenterWindow"

    let state = ControlCenterState()

    init(
        model: PlaybackModel,
        monitor: SystemMonitor,
        preferences: Preferences
    ) {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.windowSize),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        title = "SoftLive"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        collectionBehavior = [.moveToActiveSpace, .fullScreenNone]
        standardWindowButton(.zoomButton)?.isEnabled = false
        delegate = self

        let rootView = ControlCenterView(
            model: model,
            monitor: monitor,
            preferences: preferences,
            state: state
        )
        let host = NSHostingView(rootView: rootView)
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: Self.windowSize)
        contentView = host

        if setFrameUsingName(Self.frameAutosave) {
            if abs(frame.width - Self.windowSize.width) > 0.5 || abs(frame.height - Self.windowSize.height) > 0.5 {
                setFrame(
                    NSRect(
                        x: frame.minX,
                        y: frame.maxY - Self.windowSize.height,
                        width: Self.windowSize.width,
                        height: Self.windowSize.height
                    ),
                    display: false
                )
            }
        } else if let screen = NSScreen.main?.visibleFrame {
            let origin = NSPoint(
                x: round(screen.midX - Self.windowSize.width / 2),
                y: round(screen.midY - Self.windowSize.height / 2)
            )
            setFrameOrigin(origin)
        }
        setFrameAutosaveName(Self.frameAutosave)
    }

    func show(section: ControlCenterSection? = nil) {
        if let section {
            state.selectedSection = section
        }
        state.isOpen = true
        contentView?.isHidden = false
        NSApp.activate()
        makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        state.isOpen = false
        contentView?.isHidden = true
    }
}

struct ControlCenterView: View {
    static let sidebarWidth: CGFloat = 168
    private static let githubURL = URL(string: "https://github.com/DigHuang/SoftLive")!

    let model: PlaybackModel
    let monitor: SystemMonitor
    let preferences: Preferences
    let state: ControlCenterState

    @Environment(\.colorScheme) private var colorScheme

    private var appVersionString: String {
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.1"
        return "v\(ver)"
    }

    var body: some View {
        if !state.isOpen {
            Color.clear.frame(width: 0, height: 0)
        } else {
            HStack(spacing: 0) {
                sidebar
                    .frame(width: Self.sidebarWidth)
                    .frame(maxHeight: .infinity)

                Rectangle()
                    .fill(dividerColor)
                    .frame(width: 0.5)
                    .frame(maxHeight: .infinity)

                detailPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(
                width: ControlCenterWindow.windowSize.width,
                height: ControlCenterWindow.windowSize.height
            )
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
        VStack(alignment: .leading, spacing: 18) {
            switch state.selectedSection {
            case .player:
                playerSettings
            case .monitor:
                monitorSettings
            case .about:
                aboutProductView
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.top, 32)
        .padding(.bottom, 28)
    }

    // MARK: - Tab 1: 播放器

    private var playerSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            formGroup(title: "音源与状态栏") {
                formRow("首选播放器") {
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

                formToggleRow("桌面常驻组件", isOn: Binding(
                    get: { preferences.showsDesktopWidget },
                    set: { preferences.showsDesktopWidget = $0 }
                ))

                rowDivider

                formToggleRow("状态栏歌词", isOn: Binding(
                    get: { preferences.showsStatusBarLyrics },
                    set: { preferences.showsStatusBarLyrics = $0 }
                ))

                rowDivider

                formRow("状态栏最大宽度") {
                    segmentedPicker(
                        options: StatusBarWidthPreset.allCases,
                        selection: preferences.statusBarWidthPreset,
                        label: { $0.displayName }
                    ) {
                        preferences.statusBarWidthPreset = $0
                    }
                }
            }

            formGroup(title: "桌面悬浮歌词") {
                formToggleRow("显示桌面歌词", isOn: Binding(
                    get: { preferences.showsDesktopLyrics },
                    set: { preferences.showsDesktopLyrics = $0 }
                ))

                rowDivider

                formToggleRow("锁定鼠标穿透（按住 ⌘ 唤醒）", isOn: Binding(
                    get: { preferences.desktopLyricsLocked },
                    set: { preferences.desktopLyricsLocked = $0 }
                ))

                rowDivider

                formRow("歌词字号") {
                    segmentedPicker(
                        options: DesktopLyricsSize.allCases,
                        selection: preferences.desktopLyricsSize,
                        label: { $0.displayName }
                    ) {
                        preferences.desktopLyricsSize = $0
                    }
                }

                rowDivider

                formRow("副句内容") {
                    segmentedPicker(
                        options: DesktopLyricsSublineMode.allCases,
                        selection: preferences.desktopLyricsSublineMode,
                        label: { $0.displayName }
                    ) {
                        preferences.desktopLyricsSublineMode = $0
                    }
                }
            }

            formGroup(title: "演示舞台") {
                formToggleRow("开启演示舞台", isOn: Binding(
                    get: { preferences.showsStageWindow },
                    set: { preferences.showsStageWindow = $0 }
                ))

                rowDivider

                formRow("律动风格") {
                    segmentedPicker(
                        options: StageStyle.allCases,
                        selection: preferences.stageStyle,
                        label: { $0.displayName }
                    ) {
                        preferences.stageStyle = $0
                    }
                }

                rowDivider

                formToggleRow("星火粒子特效", isOn: Binding(
                    get: { preferences.stageSparks },
                    set: { preferences.stageSparks = $0 }
                ))
            }
        }
    }

    // MARK: - Tab 2: 监听

    private var monitorSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            formGroup(title: "状态栏与面板") {
                formToggleRow("显示状态栏监控", isOn: Binding(
                    get: { preferences.showsSystemMonitor },
                    set: { preferences.showsSystemMonitor = $0 }
                ))

                rowDivider

                formRow("状态栏样式") {
                    segmentedPicker(
                        options: MonitorStatusBarStyle.allCases,
                        selection: preferences.monitorStatusBarStyle,
                        label: { $0.displayName }
                    ) {
                        preferences.monitorStatusBarStyle = $0
                    }
                }

                rowDivider

                formRow("弹窗默认页面") {
                    segmentedPicker(
                        options: MonitorTab.allCases,
                        selection: preferences.monitorDefaultTab,
                        label: { $0.rawValue }
                    ) {
                        preferences.monitorDefaultTab = $0
                    }
                }
            }

            formGroup(title: "采样与告警阈值") {
                formRow("采样间隔") {
                    segmentedPicker(
                        options: MonitorSampleInterval.allCases,
                        selection: preferences.monitorSampleInterval,
                        label: { $0.displayName }
                    ) {
                        preferences.monitorSampleInterval = $0
                    }
                }

                rowDivider

                formRow("CPU 告警阈值") {
                    segmentedPicker(
                        options: MonitorCPUAlertThreshold.allCases,
                        selection: preferences.monitorCPUAlertThreshold,
                        label: { $0.displayName }
                    ) {
                        preferences.monitorCPUAlertThreshold = $0
                    }
                }

                rowDivider

                formRow("内存告警阈值") {
                    segmentedPicker(
                        options: MonitorRAMAlertThreshold.allCases,
                        selection: preferences.monitorRAMAlertThreshold,
                        label: { $0.displayName }
                    ) {
                        preferences.monitorRAMAlertThreshold = $0
                    }
                }

                rowDivider

                formRow("温度告警阈值") {
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
        return VStack(alignment: .leading, spacing: 20) {
            // Brand Hero Card
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
                    Text("macOS 原生实时逐字歌词与系统硬件遥测工具")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                HStack(spacing: 4) {
                    Text("GitHub")
                        .font(.system(size: 11.5, weight: .medium))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                }
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
            .background {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(isDark ? Color.white.opacity(0.05) : Color.white)
                    .overlay {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(borderColor, lineWidth: 0.5)
                    }
            }

            formGroup(title: "交互指南") {
                guideRow(
                    icon: "text.quote",
                    title: "桌面悬浮歌词",
                    detail: "默认鼠标穿透；按住 ⌘ 移入唤醒控制栏，支持 ±0.5s 偏移与双击切歌"
                )
                rowDivider
                guideRow(
                    icon: "rectangle.on.rectangle.angled",
                    title: "桌面组件与演示舞台",
                    detail: "随专辑封面实时提取流光色盘，支持自由拖动与双击切下一首"
                )
                rowDivider
                guideRow(
                    icon: "menubar.rectangle",
                    title: "状态栏歌词与硬件监控",
                    detail: "左键点击监控项展开 CPU / 内存 / 温度面板，右键呼出快捷菜单"
                )
            }

            formGroup(title: "架构与隐私承诺") {
                guideRow(
                    icon: "lock.shield",
                    title: "纯本地只读 · 最小权限",
                    detail: "网易云音乐零系统授权，Apple Music 仅需自动化授权，不写任何播放器数据"
                )
                rowDivider
                guideRow(
                    icon: "bolt.horizontal.circle",
                    title: "原生低功耗架构",
                    detail: "Swift 6.2 + AppKit + Core Animation 硬件加速，零第三方依赖"
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

            Spacer(minLength: 0)
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
        HStack(spacing: 16) {
            Text(title)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.primary)
            Spacer(minLength: 16)
            control()
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 16)
        .frame(height: 42)
    }

    private func formToggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 16) {
            Text(title)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.primary)
            Spacer(minLength: 16)
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
