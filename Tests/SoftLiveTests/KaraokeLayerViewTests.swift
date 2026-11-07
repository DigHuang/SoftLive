import AppKit
import SwiftUI
import Testing
@testable import SoftLive

struct KaraokeLayerViewTests {
    @Test func splitAdvancesAcrossWordsAndHoldsAcrossGaps() {
        let words = [
            LyricWord(start: 10, duration: 1, text: "我的"),
            LyricWord(start: 12, duration: 1, text: "世界"),
        ]
        let view = KaraokeLayerView(frame: NSRect(x: 0, y: 0, width: 300, height: 32))
        view.configure(
            line: LyricLine(time: 10, text: "我的世界", words: words),
            playback: nil,
            offset: 0,
            fontSize: 20,
            weight: .bold,
            color: .white,
            centered: false,
            hasShadow: false
        )
        let before = view.splitX(at: 9.5, words: words)
        let midFirst = view.splitX(at: 10.5, words: words)
        let gapStart = view.splitX(at: 11.0, words: words)
        let gapEnd = view.splitX(at: 11.9, words: words)
        let midSecond = view.splitX(at: 12.5, words: words)
        let after = view.splitX(at: 13.0, words: words)

        #expect(before < midFirst)
        #expect(midFirst < gapStart)
        #expect(gapStart == gapEnd)
        #expect(gapEnd < midSecond)
        #expect(midSecond < after)
        #expect(after == 300)
    }

    @Test func leadingSpaceWordDoesNotShiftSubsequentWordRanges() throws {
        let line = try #require(YRCParser.lines("[1000,2000](1000,200,0) (1200,800,0)我的(2000,1000,0)世界").first)
        let words = try #require(line.words)
        let view = KaraokeLayerView(frame: NSRect(x: 0, y: 0, width: 300, height: 32))
        view.configure(
            line: line,
            playback: nil,
            offset: 0,
            fontSize: 20,
            weight: .bold,
            color: .white,
            centered: false,
            hasShadow: false
        )
        let afterLeadingSpace = view.splitX(at: 1.2, words: words)
        let afterFirstWord = view.splitX(at: 2.0, words: words)
        let midLastWord = view.splitX(at: 2.5, words: words)

        #expect(afterLeadingSpace < afterFirstWord)
        #expect(afterFirstWord < midLastWord)
    }

    @Test func defersRenderingWhileHiddenAndSyncsOnUnhide() {
        let words = [
            LyricWord(start: 10, duration: 1, text: "我的"),
            LyricWord(start: 12, duration: 1, text: "世界"),
        ]
        let view = KaraokeLayerView(frame: NSRect(x: 0, y: 0, width: 300, height: 32))
        view.isHidden = true
        view.configure(
            line: LyricLine(time: 10, text: "我的世界", words: words),
            playback: nil,
            offset: 0,
            fontSize: 20,
            weight: .bold,
            color: .white,
            centered: false,
            hasShadow: false
        )
        // While hidden, no word ranges are rasterized.
        #expect(view.splitX(at: 10.5, words: words) == 300)

        view.isHidden = false
        #expect(view.splitX(at: 10.5, words: words) < view.splitX(at: 12.5, words: words))
    }

    @Test func preservesRunningAnimationWhenReconfiguredWithUnchangedTiming() throws {
        let words = [
            LyricWord(start: 10, duration: 1, text: "我的"),
            LyricWord(start: 12, duration: 1, text: "世界"),
        ]
        let line = LyricLine(time: 10, text: "我的世界", words: words)
        let track = Track(id: "1", title: "Song", artist: "Artist", album: "", duration: 180, source: .netEase)
        let playback = PlaybackState(track: track, isPlaying: true, position: 10, at: .now)

        let view = KaraokeLayerView(frame: NSRect(x: 0, y: 0, width: 300, height: 32))
        view.configure(
            line: line,
            playback: playback,
            offset: 0,
            fontSize: 20,
            weight: .bold,
            color: .white,
            centered: false,
            hasShadow: false
        )
        let clipLayer = try #require(view.layer?.sublayers?.first)
        let initialAnim = try #require(clipLayer.animation(forKey: "karaoke"))

        // Re-configuring with identical line, playback and offset (e.g. hover/wake state change) must keep the animation.
        view.configure(
            line: line,
            playback: playback,
            offset: 0,
            fontSize: 20,
            weight: .bold,
            color: .white,
            centered: false,
            hasShadow: false
        )
        let unchangedAnim = try #require(clipLayer.animation(forKey: "karaoke"))
        #expect(initialAnim === unchangedAnim)

        // Changing offset must rebuild the animation.
        view.configure(
            line: line,
            playback: playback,
            offset: 0.5,
            fontSize: 20,
            weight: .bold,
            color: .white,
            centered: false,
            hasShadow: false
        )
        let updatedAnim = try #require(clipLayer.animation(forKey: "karaoke"))
        #expect(initialAnim !== updatedAnim)
    }

    @Test func lyricsInteractionIgnoresHiddenPanelAndDismissesAfterMouseUpOutside() {
        let panel = NSPanel(
            contentRect: NSRect(x: 100, y: 100, width: 664, height: 136),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let interaction = LyricsInteraction()
        interaction.attach(to: panel)

        let insidePoint = NSPoint(x: 200, y: 150)
        let outsidePoint = NSPoint(x: 20, y: 20)

        // While the panel is hidden, pressing Command inside its frame does not wake it.
        interaction.reevaluate(command: true, buttonsPressed: false, mouseLocation: insidePoint)
        #expect(interaction.isCommandHeld == false)
        #expect(interaction.isAwake == false)

        // Once visible, pressing Command inside the card wakes it up.
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        interaction.reevaluate(command: true, buttonsPressed: false, mouseLocation: insidePoint)
        #expect(interaction.isCommandHeld == true)
        #expect(interaction.isAwake == true)

        // Releasing Command while the cursor remains inside keeps the card awake.
        interaction.reevaluate(command: false, buttonsPressed: false, mouseLocation: insidePoint)
        #expect(interaction.isCommandHeld == false)
        #expect(interaction.isAwake == true)

        // Moving outside while a mouse button is held keeps it awake until the button is released.
        interaction.reevaluate(command: false, buttonsPressed: true, mouseLocation: outsidePoint)
        #expect(interaction.isAwake == true)
        interaction.reevaluate(command: false, buttonsPressed: false, mouseLocation: outsidePoint)
        #expect(interaction.isAwake == false)
    }

    @Test func rendersThreeDotInterludeAndAdvancesAcrossThirds() throws {
        let interlude = Interlude(start: 10, end: 25)
        let interludeWords = KaraokeLayerView.interludeWords(for: interlude)
        let track = Track(id: "1", title: "Song", artist: "Artist", album: "", duration: 180, source: .netEase)
        let playing = PlaybackState(track: track, isPlaying: true, position: 10, at: .now)

        let view = KaraokeLayerView(frame: NSRect(x: 0, y: 0, width: 300, height: 32))
        view.configure(
            line: LyricLine(time: 0, text: ""),
            playback: playing,
            offset: 0,
            interlude: interlude,
            fontSize: 24,
            weight: .semibold,
            color: .white,
            centered: true,
            hasShadow: true
        )

        #expect(view.layer?.animation(forKey: "interludeBreath") != nil)
        let dot1Mid = view.splitX(at: 12.5, words: interludeWords)
        let dot2Mid = view.splitX(at: 17.5, words: interludeWords)
        let dot3Mid = view.splitX(at: 22.5, words: interludeWords)
        let done = view.splitX(at: 25.0, words: interludeWords)
        #expect(dot1Mid < dot2Mid)
        #expect(dot2Mid < dot3Mid)
        #expect(dot3Mid < done)
        #expect(done == 300)

        // Exiting the interlude removes the breathing animation.
        view.configure(
            line: LyricLine(time: 25, text: "下一句"),
            playback: playing,
            offset: 0,
            interlude: nil,
            fontSize: 24,
            weight: .semibold,
            color: .white,
            centered: true,
            hasShadow: true
        )
        #expect(view.layer?.animation(forKey: "interludeBreath") == nil)
    }

    @Test func rendersDesktopWidgetLyricsAndStageHUDViewsAcrossStates() throws {
        let suiteName = "SoftLiveComponentRenderTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = Preferences(defaults: defaults)
        preferences.showsDesktopWidget = true
        preferences.showsDesktopLyrics = true
        preferences.showsStageWindow = true

        let model = PlaybackModel(sources: [])
        let interaction = LyricsInteraction()
        interaction.isAwake = true

        let widgetHost = NSHostingView(
            rootView: DesktopWidgetView(model: model, preferences: preferences)
        )
        widgetHost.frame = NSRect(origin: .zero, size: DesktopWidgetView.panelSize)
        widgetHost.layoutSubtreeIfNeeded()
        let widgetRep = try #require(widgetHost.bitmapImageRepForCachingDisplay(in: widgetHost.bounds))
        widgetHost.cacheDisplay(in: widgetHost.bounds, to: widgetRep)
        #expect(widgetRep.pixelsWide >= Int(DesktopWidgetView.panelSize.width))

        let lyricsHost = NSHostingView(
            rootView: DesktopLyricsView(model: model, preferences: preferences, interaction: interaction)
        )
        lyricsHost.frame = NSRect(origin: .zero, size: DesktopLyricsView.panelSize)
        lyricsHost.layoutSubtreeIfNeeded()
        let lyricsRep = try #require(lyricsHost.bitmapImageRepForCachingDisplay(in: lyricsHost.bounds))
        lyricsHost.cacheDisplay(in: lyricsHost.bounds, to: lyricsRep)
        #expect(lyricsRep.pixelsWide >= Int(DesktopLyricsView.panelSize.width))

        let stageState = StageWindowState()
        stageState.isHovered = true
        let stageHost = NSHostingView(
            rootView: StageWindowView(
                model: model,
                preferences: preferences,
                windowState: stageState,
                onToggleZoom: {},
                onClose: {}
            )
        )
        stageHost.frame = NSRect(origin: .zero, size: StageWindow.defaultSize)
        stageHost.layoutSubtreeIfNeeded()
        let stageRep = try #require(stageHost.bitmapImageRepForCachingDisplay(in: stageHost.bounds))
        stageHost.cacheDisplay(in: stageHost.bounds, to: stageRep)
        #expect(stageRep.pixelsWide >= Int(StageWindow.defaultSize.width))

        let monitor = SystemMonitor(preferences: preferences)
        let centerState = ControlCenterState()
        centerState.isOpen = true
        for section in ControlCenterSection.allCases {
            centerState.selectedSection = section
            let centerHost = NSHostingView(
                rootView: ControlCenterView(
                    model: model,
                    monitor: monitor,
                    preferences: preferences,
                    state: centerState
                )
            )
            centerHost.frame = NSRect(origin: .zero, size: ControlCenterWindow.windowSize)
            centerHost.layoutSubtreeIfNeeded()
            let centerRep = try #require(centerHost.bitmapImageRepForCachingDisplay(in: centerHost.bounds))
            centerHost.cacheDisplay(in: centerHost.bounds, to: centerRep)
            #expect(centerRep.pixelsWide >= Int(ControlCenterWindow.windowSize.width))
        }
    }
}
