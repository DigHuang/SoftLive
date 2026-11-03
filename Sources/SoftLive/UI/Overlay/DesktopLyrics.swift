import AppKit
import SwiftUI

/// Floating desktop lyrics: above all windows (full-screen apps included). While unlocked they can be
/// dragged and right-clicked; locked they let every click through.
enum DesktopLyrics {
    static func makePanel(model: AppModel, preferences: Preferences, menu: NSMenu) -> OverlayPanel {
        OverlayPanel(
            frameName: "SoftLiveDesktopLyrics",
            size: NSSize(width: 820, height: 120),
            level: .floating,
            extraBehavior: .fullScreenAuxiliary,
            menu: menu,
            content: DesktopLyricsView(model: model)
        ) { screen, size in
            NSPoint(x: screen.midX - size.width / 2, y: screen.minY + 60)
        }
        .bind { (preferences.showsDesktopLyrics && model.playback != nil, preferences.desktopLyricsLocked) }
    }
}

private struct DesktopLyricsView: View {
    let model: AppModel
    @State private var isHovering = false

    private var activeLine: LyricLine {
        if let line = model.currentLine, !line.text.isEmpty { return line }
        return LyricLine(time: 0, text: model.headline)
    }

    var body: some View {
        VStack(spacing: 6) {
            KaraokeText(
                line: activeLine,
                model: model,
                fontSize: 30,
                weight: .semibold,
                color: .white,
                centered: true,
                hasShadow: true
            )

            if let subline = model.subline {
                Text(subline)
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
                    .shadow(color: .black.opacity(0.65), radius: 3, y: 1)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Glass on hover shows the panel can be dragged (locked panels get no mouse events).
        .background {
            if isHovering {
                Color.clear.glassEffect(.regular, in: .rect(cornerRadius: 22))
            }
        }
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.2), value: isHovering)
    }
}
