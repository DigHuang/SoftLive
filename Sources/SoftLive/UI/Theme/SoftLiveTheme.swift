import AppKit
import SwiftUI

/// Adaptive Frost Instrument color tokens and telemetry status helpers for SoftLive.
enum SoftLiveTheme {
    private typealias RGB = (r: CGFloat, g: CGFloat, b: CGFloat)

    /// Shared AppKit accent color aligned with macOS appearance and `NSMenu` selection highlight.
    static let accentNSColor: NSColor = .controlAccentColor

    /// Adaptive system accent color (`NSColor.controlAccentColor`, harmonious with native menus and controls).
    static let accent = Color(nsColor: accentNSColor)

    /// Muted Warm Amber for warnings, thermal warmth, `Check First`, and `Running`.
    static let warning = adaptive(
        light: (0.70, 0.40, 0.02),
        dark: (0.96, 0.72, 0.24)
    )

    /// Muted Crimson for critical threshold breaches, `Quit` confirmation, and destructive actions.
    static let critical = adaptive(
        light: (0.82, 0.19, 0.22),
        dark: (0.97, 0.43, 0.44)
    )

    /// Architectural detail-pane backdrop for Control Center.
    static let windowBackdrop = adaptive(
        light: (0.955, 0.965, 0.975),
        dark: (0.09, 0.10, 0.12)
    )

    /// Elevated card/container fill maintaining > 0.015 RGB channel delta against `windowBackdrop`.
    static let surface = adaptive(
        light: (1.0, 1.0, 1.0),
        dark: (0.14, 0.155, 0.18)
    )

    /// Recessed plate fill inside glass popovers, segmented tracks, and headers.
    static let insetWell = adaptivePrimary(lightAlpha: 0.04, darkAlpha: 0.055)

    /// Hover fill for compact interactive pills and menu triggers.
    static let controlHover = adaptivePrimary(lightAlpha: 0.075, darkAlpha: 0.095)

    /// Pressed or open-menu fill for compact interactive pills and menu triggers.
    static let controlActive = adaptivePrimary(lightAlpha: 0.11, darkAlpha: 0.14)

    /// Crisp `0.5 pt` divider and border stroke color.
    static let hairline = adaptivePrimary(lightAlpha: 0.08, darkAlpha: 0.10)

    /// Active row, pill, and scope highlight fill derived dynamically from `accentNSColor`.
    static let selectionFill = Color(
        nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let alpha: CGFloat = isDark ? 0.18 : 0.10
            var resolved = accentNSColor
            appearance.performAsCurrentDrawingAppearance {
                resolved = accentNSColor.usingColorSpace(.sRGB) ?? accentNSColor
            }
            return resolved.withAlphaComponent(alpha)
        }
    )

    /// Three-state CPU load color matching user alert thresholds.
    static func cpuColor(
        _ usage: Double,
        threshold: Double = MonitorCPUAlertThreshold.standard.fraction
    ) -> Color {
        if usage >= threshold { return critical }
        if usage >= max(0.55, threshold - 0.15) { return warning }
        return accent
    }

    /// Three-state memory status color derived from kernel pressure level and alert threshold.
    static func ramStatusColor(
        usage: Double,
        pressure: MemoryPressureLevel,
        threshold: Double = MonitorRAMAlertThreshold.standard.fraction
    ) -> Color {
        switch pressure {
        case .critical: critical
        case .warning: warning
        case .normal: usage >= threshold ? warning : accent
        }
    }

    /// Three-state SoC thermal color matching user alert thresholds.
    static func thermalColor(
        _ celsius: Double?,
        alertThreshold: Double = MonitorThermalAlertThreshold.standard.celsius
    ) -> Color {
        guard let celsius else { return accent }
        if celsius >= alertThreshold { return critical }
        if celsius >= max(55, alertThreshold - 10) { return warning }
        return accent
    }

    private static func adaptive(
        light: RGB,
        dark: RGB,
        lightAlpha: CGFloat = 1,
        darkAlpha: CGFloat = 1
    ) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let rgb = isDark ? dark : light
                let alpha = isDark ? darkAlpha : lightAlpha
                return NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: alpha)
            }
        )
    }

    private static func adaptivePrimary(lightAlpha: CGFloat, darkAlpha: CGFloat) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return NSColor.labelColor.withAlphaComponent(isDark ? darkAlpha : lightAlpha)
            }
        )
    }
}

/// Lightweight AppKit vibrancy backdrop for native sidebar and popover surfaces.
struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    init(
        material: NSVisualEffectView.Material = .sidebar,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    ) {
        self.material = material
        self.blendingMode = blendingMode
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        if view.material != material {
            view.material = material
        }
        if view.blendingMode != blendingMode {
            view.blendingMode = blendingMode
        }
        if view.state != .followsWindowActiveState {
            view.state = .followsWindowActiveState
        }
    }
}
