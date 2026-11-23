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
        case .player: "waveform"
        case .monitor: "waveform.path.ecg"
        case .cleaner: "internaldrive"
        case .about: "info.circle"
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
    static let sidebarWidth: CGFloat = 172
    private static let githubURL = URL(string: "https://github.com/DigHuang/SoftLive")!

    let model: PlaybackModel
    let monitor: SystemMonitor
    let cleaner: DiskCleaner
    let preferences: Preferences
    let state: ControlCenterState

    @State private var hoveredSection: ControlCenterSection?

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

    private var appVersionNumber: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.2"
    }

    private var appVersionString: String {
        "v\(appVersionNumber)"
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
                    .background(VisualEffectBackground(material: .sidebar, blendingMode: .behindWindow))

                Rectangle()
                    .fill(SoftLiveTheme.hairline)
                    .frame(width: 0.5, height: winHeight)
                    .background(SoftLiveTheme.windowBackdrop)

                detailPane
                    .frame(width: rightWidth, height: winHeight, alignment: .topLeading)
                    .background(SoftLiveTheme.windowBackdrop)
                    .clipped()
            }
            .frame(width: winWidth, height: winHeight, alignment: .topLeading)
            .ignoresSafeArea()
        }
    }

    // MARK: - Left Sidebar (172 pt)

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(ControlCenterSection.navigationTabs) { section in
                sidebarItem(section)
            }

            Spacer(minLength: 0)

            brandFooterEntry
        }
        .padding(.top, 50)
        .padding(.bottom, 14)
        .padding(.horizontal, 10)
    }

    private func sidebarItem(_ section: ControlCenterSection) -> some View {
        let isSelected = state.selectedSection == section
        let isHovered = hoveredSection == section

        return HStack(spacing: 9) {
            Image(systemName: section.icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isSelected ? SoftLiveTheme.accent : .secondary)
                .frame(width: 20, alignment: .center)

            Text(section.title)
                .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(SoftLiveTheme.selectionFill)
            } else if isHovered {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(SoftLiveTheme.insetWell)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering in
            if hovering {
                if hoveredSection != section { hoveredSection = section }
            } else if hoveredSection == section {
                hoveredSection = nil
            }
        }
        .onTapGesture {
            withAnimation(.snappy(duration: 0.16)) {
                state.selectedSection = section
            }
        }
    }

    private var brandFooterEntry: some View {
        let isSelected = state.selectedSection == .about
        let isHovered = hoveredSection == .about

        return HStack(spacing: 8) {
            Image(nsImage: BrandAssets.syncTemplate)
                .resizable()
                .renderingMode(.template)
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
                .foregroundStyle(isSelected ? SoftLiveTheme.accent : .secondary)
                .frame(width: 20, alignment: .center)

            Text("SoftLive")
                .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            Text(appVersionString)
                .font(.system(size: 10.5, weight: .regular).monospacedDigit())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(SoftLiveTheme.selectionFill)
            } else if isHovered {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(SoftLiveTheme.insetWell)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering in
            if hovering {
                if hoveredSection != .about { hoveredSection = .about }
            } else if hoveredSection == .about {
                hoveredSection = nil
            }
        }
        .onTapGesture {
            withAnimation(.snappy(duration: 0.16)) {
                state.selectedSection = .about
            }
        }
    }

    // MARK: - Right Detail Pane

    @ViewBuilder
    private var detailPane: some View {
        switch state.selectedSection {
        case .player:
            scrollableSection { playerSettings }
        case .monitor:
            scrollableSection { monitorSettings }
        case .cleaner:
            CleanerPaneView(cleaner: cleaner, preferences: preferences)
                .padding(.horizontal, 28)
                .padding(.top, 28)
                .padding(.bottom, 22)
        case .about:
            scrollableSection { aboutProductView }
        }
    }

    private func scrollableSection<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            content()
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, 28)
                .padding(.top, 28)
                .padding(.bottom, 22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tint(SoftLiveTheme.accent)
    }

    // MARK: - Tab 1: 播放器

    private var playerSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            formGroup(title: L10n.tr("音源与状态栏", "Source & Status Bar")) {
                formRow(L10n.tr("首选播放器", "Preferred Player")) {
                    menuPicker(
                        options: PlayerKind.allCases,
                        selection: binding(\.preferredPlayer),
                        label: { $0.displayName },
                        icon: { $0.icon }
                    )
                }

                rowDivider

                formToggleRow(L10n.tr("桌面常驻组件", "Desktop Widget"), isOn: binding(\.showsDesktopWidget))

                rowDivider

                formToggleRow(L10n.tr("状态栏歌词", "Status Bar Lyrics"), isOn: binding(\.showsStatusBarLyrics))

                rowDivider

                formRow(L10n.tr("状态栏最大宽度", "Status Bar Max Width")) {
                    menuPicker(
                        options: StatusBarWidthPreset.allCases,
                        selection: binding(\.statusBarWidthPreset),
                        label: { $0.displayName }
                    )
                }
            }

            formGroup(title: L10n.tr("桌面悬浮歌词", "Desktop Lyrics")) {
                formToggleRow(L10n.tr("显示桌面歌词", "Show Desktop Lyrics"), isOn: binding(\.showsDesktopLyrics))

                rowDivider

                formToggleRow(
                    L10n.tr("锁定鼠标穿透（按住 ⌘ 唤醒）", "Click-Through Lock (Hold ⌘ to Wake)"),
                    isOn: binding(\.desktopLyricsLocked)
                )

                rowDivider

                formRow(L10n.tr("歌词字号", "Font Size")) {
                    menuPicker(
                        options: DesktopLyricsSize.allCases,
                        selection: binding(\.desktopLyricsSize),
                        label: { $0.displayName }
                    )
                }

                rowDivider

                formRow(L10n.tr("副句内容", "Subline Mode")) {
                    menuPicker(
                        options: DesktopLyricsSublineMode.allCases,
                        selection: binding(\.desktopLyricsSublineMode),
                        label: { $0.displayName }
                    )
                }
            }

            formGroup(title: L10n.tr("演示舞台", "Stage Mode")) {
                formToggleRow(L10n.tr("开启演示舞台", "Enable Stage Window"), isOn: binding(\.showsStageWindow))

                rowDivider

                formRow(L10n.tr("律动风格", "Kinetic Style")) {
                    segmentedControlPicker(
                        options: StageStyle.allCases,
                        selection: binding(\.stageStyle),
                        label: { $0.displayName }
                    )
                }

                rowDivider

                formToggleRow(L10n.tr("星火粒子特效", "Spark Particles"), isOn: binding(\.stageSparks))
            }
        }
    }

    // MARK: - Tab 2: 监听

    private var monitorSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            formGroup(title: L10n.tr("状态栏与面板", "Status Bar & Popover")) {
                formToggleRow(L10n.tr("显示状态栏监控", "Show System Monitor"), isOn: binding(\.showsSystemMonitor))

                rowDivider

                formRow(L10n.tr("状态栏样式", "Status Bar Style")) {
                    segmentedControlPicker(
                        options: MonitorStatusBarStyle.allCases,
                        selection: binding(\.monitorStatusBarStyle),
                        label: { $0.displayName }
                    )
                }

                rowDivider

                formToggleRow(L10n.tr("柱状图彩色显示", "Colored Bars"), isOn: binding(\.monitorColoredBars))

                rowDivider

                formRow(L10n.tr("弹窗默认页面", "Default Popover Tab")) {
                    segmentedControlPicker(
                        options: MonitorTab.allCases,
                        selection: binding(\.monitorDefaultTab),
                        label: { $0.rawValue }
                    )
                }
            }

            formGroup(title: L10n.tr("采样与告警阈值", "Sampling & Alert Thresholds")) {
                formRow(L10n.tr("采样间隔", "Refresh Interval")) {
                    menuPicker(
                        options: MonitorSampleInterval.allCases,
                        selection: binding(\.monitorSampleInterval),
                        label: { $0.displayName }
                    )
                }

                rowDivider

                formRow(L10n.tr("CPU 告警阈值", "CPU Alert Threshold")) {
                    menuPicker(
                        options: MonitorCPUAlertThreshold.allCases,
                        selection: binding(\.monitorCPUAlertThreshold),
                        label: { $0.displayName }
                    )
                }

                rowDivider

                formRow(L10n.tr("内存告警阈值", "RAM Alert Threshold")) {
                    menuPicker(
                        options: MonitorRAMAlertThreshold.allCases,
                        selection: binding(\.monitorRAMAlertThreshold),
                        label: { $0.displayName }
                    )
                }

                rowDivider

                formRow(L10n.tr("温度告警阈值", "Temp Alert Threshold")) {
                    menuPicker(
                        options: MonitorThermalAlertThreshold.allCases,
                        selection: binding(\.monitorThermalAlertThreshold),
                        label: { $0.displayName }
                    )
                }
            }
        }
    }

    // MARK: - Tab 4: 关于 (About)

    private var aboutProductView: some View {
        VStack(alignment: .leading, spacing: 18) {
            formGroup(title: L10n.tr("关于应用", "About")) {
                HStack(spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(SoftLiveTheme.insetWell)
                            .overlay {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(SoftLiveTheme.hairline, lineWidth: 0.5)
                            }
                        Image(nsImage: BrandAssets.appIcon)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 56, height: 56)
                    }
                    .frame(width: 68, height: 68)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("SoftLive")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.primary)
                            Text("Version \(appVersionNumber)")
                                .font(.system(size: 11.5, weight: .regular).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Text(L10n.tr("macOS 实时逐字歌词、硬件监控与空间清理", "Real-time lyrics, telemetry, and disk cleaner for macOS"))
                            .font(.system(size: 12.5, weight: .regular))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Link(destination: Self.githubURL) {
                        HStack(spacing: 3) {
                            Text("GitHub")
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(SoftLiveTheme.accent)
                    }
                    .buttonStyle(.plain)
                    .fixedSize(horizontal: true, vertical: false)
                }
                .padding(16)
            }

            formGroup(title: L10n.tr("通用", "General")) {
                formRow(L10n.tr("界面语言", "Language")) {
                    segmentedControlPicker(
                        options: AppLanguage.allCases,
                        selection: binding(\.language),
                        label: { $0.displayName }
                    )
                }
            }

            formGroup(title: L10n.tr("快捷键与手势", "Shortcuts & Gestures")) {
                shortcutRow(
                    title: L10n.tr("唤醒悬浮歌词控制栏", "Wake desktop lyrics controls"),
                    shortcut: L10n.tr("⌘ + 悬停", "⌘ + Hover")
                )
                rowDivider
                shortcutRow(
                    title: L10n.tr("切下一首（悬浮歌词 / 桌面组件 / 舞台）", "Skip to next track (Lyrics / Widget / Stage)"),
                    shortcut: L10n.tr("双击", "Double-Click")
                )
                rowDivider
                shortcutRow(
                    title: L10n.tr("打开配置中心", "Open Control Center"),
                    shortcut: "⌘,"
                )
                rowDivider
                shortcutRow(
                    title: L10n.tr("切换配置分页", "Switch Control Center tab"),
                    shortcut: "⌘1–4"
                )
                rowDivider
                shortcutRow(
                    title: L10n.tr("关闭当前窗口", "Close active window"),
                    shortcut: "⌘W"
                )
            }
        }
    }

    private func shortcutRow(title: String, shortcut: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(shortcut)
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(SoftLiveTheme.insetWell, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(SoftLiveTheme.hairline, lineWidth: 0.5)
                }
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
    }

    // MARK: - Form Building Blocks

    private var rowDivider: some View {
        Rectangle()
            .fill(SoftLiveTheme.hairline)
            .frame(height: 0.5)
            .padding(.leading, 16)
    }

    private func formGroup<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
                .frame(height: 15, alignment: .leading)

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(SoftLiveTheme.surface)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(SoftLiveTheme.hairline, lineWidth: 0.5)
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

    private func menuPicker<Option: Hashable>(
        options: [Option],
        selection: Binding<Option>,
        label: @escaping (Option) -> String,
        icon: ((Option) -> NSImage?)? = nil
    ) -> some View {
        Picker("", selection: selection) {
            ForEach(options, id: \.self) { option in
                if let iconImage = icon?(option) {
                    Label {
                        Text(label(option))
                    } icon: {
                        Image(nsImage: Self.menuIcon(for: iconImage))
                    }
                    .tag(option)
                } else {
                    Text(label(option))
                        .tag(option)
                }
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
    }

    private func segmentedControlPicker<Option: Hashable>(
        options: [Option],
        selection: Binding<Option>,
        label: @escaping (Option) -> String
    ) -> some View {
        Picker("", selection: selection) {
            ForEach(options, id: \.self) { option in
                Text(label(option))
                    .tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    private func binding<Value>(
        _ keyPath: ReferenceWritableKeyPath<Preferences, Value>
    ) -> Binding<Value> {
        Binding(
            get: { preferences[keyPath: keyPath] },
            set: { preferences[keyPath: keyPath] = $0 }
        )
    }

    private static func menuIcon(for image: NSImage) -> NSImage {
        let copy = image.copy() as? NSImage ?? image
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }
}
