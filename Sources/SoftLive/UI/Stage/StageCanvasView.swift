import AppKit
import QuartzCore

/// High-impact, hardware-accelerated kinetic typography stage renderer.
///
/// Combines 3D perspective transforms (`CATransform3D`), decoupled squash-and-stretch (`scaleX`/`scaleY`),
/// four Folia-inspired per-word entrance physics modes (`pop3D`, `dropSmash`, `spinVortex`, `elasticWhip`),
/// EVA-style cross starbursts, expanding shockwave rings, CoreText vector laser stroke tracing with ghost echoes,
/// and whole-stage camera beat kicks — all compiled into normalized `CAKeyframeAnimation` timelines once per line.
final class StageCanvasView: NSView {
    private struct RenderKey: Equatable {
        let lineTime: TimeInterval
        let text: String
        let subline: String?
        let interlude: Interlude?
        let style: StageStyle
        let sparks: Bool
        let size: CGSize
        let backingScale: CGFloat
        let palette: StagePalette
    }

    private static let orbDriftKey = "orbDrift"

    private let backdropLayer = CAGradientLayer()
    private let orbPrimaryLayer = CAGradientLayer()
    private let orbSecondaryLayer = CAGradientLayer()
    private let echoStageLayer = CALayer()
    private let contentLayer = CALayer()
    private let footerLayer = CALayer()

    private var line = LyricLine(time: 0, text: "")
    private var previousLine: LyricLine?
    private var nextLineTime: TimeInterval?
    private var subline: String?
    private var interlude: Interlude?
    private var playback: PlaybackState?
    private var offset: TimeInterval = 0
    private var style: StageStyle = .luminous
    private var sparksEnabled = true
    private var palette: StagePalette = .fallback
    private var artwork: NSImage?

    private var renderedKey: RenderKey?
    private(set) var activeWords: [StageWordTimeline.WordUnit] = []
    private(set) var activeRowCount: Int = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        setupBaseLayers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(
        line: LyricLine,
        nextLineTime: TimeInterval?,
        subline: String?,
        interlude: Interlude?,
        playback: PlaybackState?,
        offset: TimeInterval,
        style: StageStyle,
        sparks: Bool,
        palette: StagePalette,
        artwork: NSImage?
    ) {
        let timingChanged = self.playback != playback || self.offset != offset || self.interlude != interlude
        let artworkChanged = self.artwork !== artwork
        if self.line.time != line.time || self.line.text != line.text {
            if !self.line.text.isEmpty {
                self.previousLine = self.line
            }
        }
        self.line = line
        self.nextLineTime = nextLineTime
        self.subline = subline
        self.interlude = interlude
        self.playback = playback
        self.offset = offset
        self.style = style
        self.sparksEnabled = sparks
        self.palette = palette
        self.artwork = artwork
        refreshIfNeeded(forceSync: timingChanged || artworkChanged)
    }

    override func layout() {
        super.layout()
        layoutBackdropLayers()
        refreshIfNeeded(forceSync: false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshIfNeeded(forceSync: true)
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        refreshIfNeeded(forceSync: true)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refreshIfNeeded(forceSync: false)
    }

    // MARK: - Backdrop & 3D Camera Setup

    private func setupBaseLayers() {
        guard let root = layer else { return }
        root.masksToBounds = true

        backdropLayer.startPoint = CGPoint(x: 0.12, y: 1.0)
        backdropLayer.endPoint = CGPoint(x: 0.88, y: 0.0)
        root.addSublayer(backdropLayer)

        for orb in [orbPrimaryLayer, orbSecondaryLayer] {
            orb.type = .radial
            orb.startPoint = CGPoint(x: 0.5, y: 0.5)
            orb.endPoint = CGPoint(x: 1.0, y: 1.0)
            root.addSublayer(orb)
        }

        var perspective = CATransform3DIdentity
        perspective.m34 = -1.0 / 640.0
        contentLayer.sublayerTransform = perspective

        root.addSublayer(echoStageLayer)
        root.addSublayer(contentLayer)
        root.addSublayer(footerLayer)
        applyPalette(palette)
    }

    private func layoutBackdropLayers() {
        let w = bounds.width
        let h = bounds.height
        guard w > 1, h > 1 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdropLayer.frame = bounds
        echoStageLayer.frame = bounds
        contentLayer.bounds = bounds
        contentLayer.position = CGPoint(x: w / 2, y: h / 2)
        footerLayer.frame = bounds

        let orbSize = max(w, h) * 0.85
        orbPrimaryLayer.bounds = CGRect(x: 0, y: 0, width: orbSize, height: orbSize)
        orbSecondaryLayer.bounds = CGRect(x: 0, y: 0, width: orbSize * 0.92, height: orbSize * 0.92)
        orbPrimaryLayer.position = CGPoint(x: w * 0.26, y: h * 0.70)
        orbSecondaryLayer.position = CGPoint(x: w * 0.76, y: h * 0.30)
        CATransaction.commit()
        updateOrbDriftAnimation()
    }

    private func applyPalette(_ p: StagePalette) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.5)
        backdropLayer.colors = [p.backgroundTop.cgColor, p.backgroundBottom.cgColor]
        orbPrimaryLayer.colors = [p.orbPrimary.cgColor, p.orbPrimary.withAlphaComponent(0).cgColor]
        orbSecondaryLayer.colors = [p.orbSecondary.cgColor, p.orbSecondary.withAlphaComponent(0).cgColor]
        CATransaction.commit()
    }

    private func updateOrbDriftAnimation() {
        let w = bounds.width
        let h = bounds.height
        guard !isHiddenOrHasHiddenAncestor, w > 1, h > 1, playback?.isPlaying == true else {
            orbPrimaryLayer.removeAnimation(forKey: Self.orbDriftKey)
            orbSecondaryLayer.removeAnimation(forKey: Self.orbDriftKey)
            return
        }
        if orbPrimaryLayer.animation(forKey: Self.orbDriftKey) == nil {
            let drift1 = CAKeyframeAnimation(keyPath: "position")
            drift1.values = [
                NSValue(point: CGPoint(x: w * 0.25, y: h * 0.72)),
                NSValue(point: CGPoint(x: w * 0.52, y: h * 0.58)),
                NSValue(point: CGPoint(x: w * 0.30, y: h * 0.36)),
                NSValue(point: CGPoint(x: w * 0.25, y: h * 0.72)),
            ]
            drift1.duration = 14
            drift1.repeatCount = .infinity
            drift1.calculationMode = .cubicPaced
            orbPrimaryLayer.add(drift1, forKey: Self.orbDriftKey)

            let drift2 = CAKeyframeAnimation(keyPath: "position")
            drift2.values = [
                NSValue(point: CGPoint(x: w * 0.76, y: h * 0.28)),
                NSValue(point: CGPoint(x: w * 0.48, y: h * 0.44)),
                NSValue(point: CGPoint(x: w * 0.72, y: h * 0.68)),
                NSValue(point: CGPoint(x: w * 0.76, y: h * 0.28)),
            ]
            drift2.duration = 17
            drift2.repeatCount = .infinity
            drift2.calculationMode = .cubicPaced
            orbSecondaryLayer.add(drift2, forKey: Self.orbDriftKey)
        }
    }

    // MARK: - Refresh & Rebuild

    private func refreshIfNeeded(forceSync: Bool) {
        guard !isHiddenOrHasHiddenAncestor, bounds.width > 1, bounds.height > 1 else {
            orbPrimaryLayer.removeAnimation(forKey: Self.orbDriftKey)
            orbSecondaryLayer.removeAnimation(forKey: Self.orbDriftKey)
            contentLayer.removeAnimation(forKey: StageEffects.cameraPulseKey)
            return
        }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let key = RenderKey(
            lineTime: line.time,
            text: line.text,
            subline: subline,
            interlude: interlude,
            style: style,
            sparks: sparksEnabled,
            size: bounds.size,
            backingScale: scale,
            palette: palette
        )
        let paletteChanged = renderedKey?.palette != palette
        let lineChanged = renderedKey != nil && (renderedKey?.lineTime != key.lineTime || renderedKey?.text != key.text || renderedKey?.interlude != key.interlude)

        if paletteChanged {
            applyPalette(palette)
        }
        updateOrbDriftAnimation()

        guard key != renderedKey || forceSync else { return }
        renderedKey = key
        rebuildStage(key: key, animateTransition: lineChanged)
    }

    private func rebuildStage(key: RenderKey, animateTransition: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        echoStageLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        contentLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        contentLayer.removeAnimation(forKey: StageEffects.cameraPulseKey)
        footerLayer.sublayers?.forEach { $0.removeFromSuperlayer() }

        let nowTime = (playback?.position(at: .now) ?? 0) + offset
        let isPlaying = playback?.isPlaying == true

        if animateTransition, isPlaying, let prev = previousLine, !prev.text.isEmpty, key.interlude == nil {
            StageEffects.addOutgoingAfterimage(
                for: prev,
                in: echoStageLayer,
                size: key.size,
                backingScale: key.backingScale,
                accent: key.palette.accent
            )
        }

        if let interlude = key.interlude {
            activeWords = []
            activeRowCount = 0
            StageInterludeRenderer.render(
                interlude: interlude,
                nowTime: nowTime,
                isPlaying: isPlaying,
                in: contentLayer,
                size: key.size,
                palette: key.palette,
                artwork: artwork
            )
        } else if key.text.isEmpty {
            activeWords = []
            activeRowCount = 0
            StageInterludeRenderer.render(
                interlude: Interlude(start: nowTime, end: nowTime + 6),
                nowTime: nowTime,
                isPlaying: isPlaying,
                in: contentLayer,
                size: key.size,
                palette: key.palette,
                artwork: artwork
            )
        } else {
            let words = StageWordTimeline.effectiveWords(for: line, nextLineTime: nextLineTime, perCharacter: true)
            activeWords = words
            switch key.style {
            case .luminous:
                activeRowCount = StageLuminousRenderer(
                    size: key.size,
                    backingScale: key.backingScale,
                    palette: key.palette,
                    sparks: key.sparks
                ).render(
                    words: words,
                    lineTime: key.lineTime,
                    text: key.text,
                    nowTime: nowTime,
                    isPlaying: isPlaying,
                    in: contentLayer
                )
            case .inkTrace:
                activeRowCount = StageInkTraceRenderer(
                    size: key.size,
                    backingScale: key.backingScale,
                    palette: key.palette,
                    sparks: key.sparks
                ).render(
                    words: words,
                    lineTime: key.lineTime,
                    text: key.text,
                    nowTime: nowTime,
                    isPlaying: isPlaying,
                    in: contentLayer
                )
            }
            if isPlaying {
                StageEffects.applyCameraBeatPulse(
                    in: contentLayer,
                    words: words,
                    nowTime: nowTime,
                    lineTime: key.lineTime
                )
            }
        }

        buildFooter(key: key)
        CATransaction.commit()
    }

    // MARK: - Footer (Translation / Next Line Preview)

    private func buildFooter(key: RenderKey) {
        guard let sub = key.subline, !sub.isEmpty else { return }
        let w = key.size.width
        let fontSize = min(20, max(14, round(w * 0.020)))
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let boxSize = CGSize(width: floor(w * 0.84), height: ceil(fontSize * 1.6))
        let image = StageTextRenderer.rasterizeWord(
            sub,
            font: font,
            size: boxSize,
            scale: key.backingScale,
            color: NSColor.white.withAlphaComponent(0.68),
            glowColor: NSColor.black.withAlphaComponent(0.65),
            glowBlur: 6
        )
        let subLayer = CALayer()
        subLayer.bounds = CGRect(origin: .zero, size: boxSize)
        subLayer.position = CGPoint(x: w / 2, y: 98)
        subLayer.contents = image
        subLayer.contentsScale = key.backingScale
        footerLayer.addSublayer(subLayer)
    }
}
