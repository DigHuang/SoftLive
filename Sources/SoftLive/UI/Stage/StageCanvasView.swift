import AppKit
import CoreText
import QuartzCore

/// High-impact, hardware-accelerated kinetic typography stage renderer.
///
/// Combines 3D perspective transforms (`CATransform3D`), decoupled squash-and-stretch (`scaleX`/`scaleY`),
/// four Folia-inspired per-word entrance physics modes (`pop3D`, `dropSmash`, `spinVortex`, `elasticWhip`),
/// EVA-style cross starbursts, expanding shockwave rings, CoreText vector laser stroke tracing with ghost echoes,
/// and whole-stage camera beat kicks — all compiled into normalized `CAKeyframeAnimation` timelines once per line.
final class StageCanvasView: NSView {
    struct WordUnit: Equatable {
        let text: String
        let start: TimeInterval
        let end: TimeInterval
    }

    private enum EnterMode: Int, CaseIterable {
        case pop3D = 0
        case dropSmash = 1
        case spinVortex = 2
        case elasticWhip = 3
    }

    private struct WordPose {
        var pos: CGPoint
        var scaleX: CGFloat
        var scaleY: CGFloat
        var rotZ: CGFloat
        var rotX: CGFloat
        var rotY: CGFloat
        var opacity: Float
        var glow: Float
    }

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

    private static let stageAnimKey = "stageKinetic"
    private static let cameraPulseKey = "stageCameraPulse"
    private static let orbDriftKey = "orbDrift"
    private static let vinylSpinKey = "vinylSpin"

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
    private(set) var activeWords: [WordUnit] = []
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
            contentLayer.removeAnimation(forKey: Self.cameraPulseKey)
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
        contentLayer.removeAnimation(forKey: Self.cameraPulseKey)
        footerLayer.sublayers?.forEach { $0.removeFromSuperlayer() }

        let nowTime = (playback?.position(at: .now) ?? 0) + offset
        let isPlaying = playback?.isPlaying == true

        if animateTransition, isPlaying, let prev = previousLine, !prev.text.isEmpty, key.interlude == nil {
            buildOutgoingAfterimage(prevLine: prev, key: key)
        }

        if let interlude = key.interlude {
            activeWords = []
            activeRowCount = 0
            buildVinylInterlude(interlude: interlude, nowTime: nowTime, isPlaying: isPlaying, key: key)
        } else if key.text.isEmpty {
            activeWords = []
            activeRowCount = 0
            buildVinylInterlude(
                interlude: Interlude(start: nowTime, end: nowTime + 6),
                nowTime: nowTime,
                isPlaying: isPlaying,
                key: key
            )
        } else {
            let words = Self.effectiveWords(for: line, nextLineTime: nextLineTime, perCharacter: true)
            activeWords = words
            switch key.style {
            case .luminous:
                activeRowCount = buildLuminousStage(words: words, nowTime: nowTime, isPlaying: isPlaying, key: key)
            case .inkTrace:
                activeRowCount = buildInkTraceStage(words: words, nowTime: nowTime, isPlaying: isPlaying, key: key)
            }
            if isPlaying {
                applyCameraBeatPulse(words: words, nowTime: nowTime, key: key)
            }
        }

        buildFooter(key: key)
        CATransaction.commit()
    }

    // MARK: - Outgoing Line Afterimage & Camera Beat Kick

    private func buildOutgoingAfterimage(prevLine: LyricLine, key: RenderKey) {
        let w = key.size.width
        let h = key.size.height
        let fontSize = min(54, max(30, round(w * 0.044)))
        let font = NSFont.systemFont(ofSize: fontSize, weight: .heavy)
        let boxSize = CGSize(width: floor(w * 0.84), height: ceil(fontSize * 1.8))
        guard let img = rasterizeWord(
            prevLine.text,
            font: font,
            size: boxSize,
            scale: key.backingScale,
            color: key.palette.accent.withAlphaComponent(0.36),
            glowColor: key.palette.accent,
            glowBlur: 18
        ) else { return }

        let ghost = CALayer()
        ghost.bounds = CGRect(origin: .zero, size: boxSize)
        ghost.position = CGPoint(x: w / 2, y: h * 0.54)
        ghost.contents = img
        ghost.contentsScale = key.backingScale
        ghost.opacity = 0
        echoStageLayer.addSublayer(ghost)

        let scaleAnim = CABasicAnimation(keyPath: "transform.scale")
        scaleAnim.fromValue = 0.96
        scaleAnim.toValue = 1.32

        let moveAnim = CABasicAnimation(keyPath: "position.y")
        moveAnim.fromValue = h * 0.52
        moveAnim.toValue = h * 0.62

        let fadeAnim = CAKeyframeAnimation(keyPath: "opacity")
        fadeAnim.keyTimes = [0, 0.2, 1.0]
        fadeAnim.values = [0.42, 0.28, 0.0]

        let group = CAAnimationGroup()
        group.animations = [scaleAnim, moveAnim, fadeAnim]
        group.duration = 0.46
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ghost.add(group, forKey: "afterimageExit")
    }

    private func applyCameraBeatPulse(words: [WordUnit], nowTime: TimeInterval, key: RenderKey) {
        guard !words.isEmpty else { return }
        let lineEnd = (words.last?.end ?? (nowTime + 2)) + 0.85
        let remaining = max(0.08, lineEnd - nowTime)
        let seed = floor(key.lineTime * 1000)

        var times: [TimeInterval] = [nowTime]
        var scales: [CGFloat] = [1.0]
        var tilts: [CGFloat] = [0.0]

        for (idx, word) in words.enumerated() {
            let isHeavy = idx == 0 || idx == words.count - 1 || (word.end - word.start) >= 0.45 || idx.isMultiple(of: 3)
            guard isHeavy, word.start > nowTime, word.start + 0.24 < lineEnd else { continue }
            let pre = max(nowTime, word.start - 0.03)
            let peak = word.start + 0.05
            let settle = word.start + 0.24
            if pre > (times.last ?? nowTime) {
                times.append(pre)
                scales.append(1.0)
                tilts.append(0.0)
            }
            if peak > (times.last ?? nowTime) {
                let kick: CGFloat = idx == words.count - 1 ? 1.052 : 1.032
                let tiltDir: CGFloat = Self.lineRandom(seed: seed + Double(idx), offset: 31) < 0.5 ? -1 : 1
                times.append(peak)
                scales.append(kick)
                tilts.append(tiltDir * (idx == words.count - 1 ? 0.018 : 0.010))
            }
            if settle > (times.last ?? nowTime) {
                times.append(settle)
                scales.append(1.0)
                tilts.append(0.0)
            }
        }

        guard times.count > 1 else { return }
        times.append(lineEnd)
        scales.append(1.0)
        tilts.append(0.0)

        let keyTimes = times.map { NSNumber(value: min(1, max(0, ($0 - nowTime) / remaining))) }

        let scaleAnim = CAKeyframeAnimation(keyPath: "transform.scale")
        scaleAnim.keyTimes = keyTimes
        scaleAnim.values = scales.map { NSNumber(value: Double($0)) }
        scaleAnim.duration = remaining

        let tiltAnim = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        tiltAnim.keyTimes = keyTimes
        tiltAnim.values = tilts.map { NSNumber(value: Double($0)) }
        tiltAnim.duration = remaining

        let group = CAAnimationGroup()
        group.animations = [scaleAnim, tiltAnim]
        group.duration = remaining
        contentLayer.add(group, forKey: Self.cameraPulseKey)
    }

    // MARK: - Word Segmentation & Math Curves

    static func effectiveWords(for line: LyricLine, nextLineTime: TimeInterval?, perCharacter: Bool = false) -> [WordUnit] {
        if let yrcWords = line.words, !yrcWords.isEmpty {
            guard perCharacter else {
                return yrcWords.map { w in
                    let d = max(0.12, w.duration)
                    return WordUnit(text: w.text, start: w.start, end: w.start + d)
                }
            }
            var units: [WordUnit] = []
            for w in yrcWords {
                let d = max(0.12, w.duration)
                let subTokens = segmentText(w.text)
                if subTokens.count <= 1 {
                    units.append(WordUnit(text: w.text, start: w.start, end: w.start + d))
                } else {
                    let step = d / Double(subTokens.count)
                    for (idx, tok) in subTokens.enumerated() {
                        let st = w.start + Double(idx) * step
                        units.append(WordUnit(text: tok, start: st, end: st + max(0.10, step)))
                    }
                }
            }
            return units
        }
        let tokens = segmentText(line.text)
        guard !tokens.isEmpty else { return [] }
        let span: TimeInterval
        if let next = nextLineTime, next > line.time {
            span = min(max((next - line.time) * 0.82, 1.6), 4.5)
        } else {
            span = 3.2
        }
        let totalChars = max(1, tokens.reduce(0) { $0 + max(1, $1.trimmingCharacters(in: .whitespaces).count) })
        var cursor = line.time
        return tokens.map { token in
            let weight = Double(max(1, token.trimmingCharacters(in: .whitespaces).count))
            let d = max(0.14, span * weight / Double(totalChars))
            let unit = WordUnit(text: token, start: cursor, end: cursor + d)
            cursor += d
            return unit
        }
    }

    static func segmentText(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty {
                out.append(current)
                current = ""
            }
        }
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespaces.contains(scalar) {
                if !current.isEmpty {
                    current.append(" ")
                    flush()
                }
            } else if isCJKScalar(scalar) {
                flush()
                out.append(String(scalar))
            } else {
                current.append(Character(scalar))
            }
        }
        flush()
        return out
    }

    private static func isCJKScalar(_ s: UnicodeScalar) -> Bool {
        switch s.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x3040...0x30FF, 0xAC00...0xD7AF, 0xFF00...0xFFEF, 0x3000...0x303F:
            return true
        default:
            return false
        }
    }

    static func lineRandom(seed: Double, offset: Double) -> CGFloat {
        let x = sin(seed + offset * 12.9898) * 43758.5453
        return CGFloat(x - floor(x))
    }

    static func springValue(at elapsed: Double) -> CGFloat {
        guard elapsed > 0 else { return 0 }
        let e = exp(-9.5 * elapsed)
        return CGFloat(1 - e * (cos(11.5 * elapsed) + 0.85 * sin(11.5 * elapsed)))
    }

    private static func easeOutBack(_ t: Double, overshoot: Double = 2.2) -> CGFloat {
        let q = min(1, max(0, t)) - 1
        return CGFloat(1 + (overshoot + 1) * q * q * q + overshoot * q * q)
    }

    private static func easeOutExpo(_ t: Double) -> CGFloat {
        let q = min(1, max(0, t))
        return q >= 1 ? 1 : CGFloat(1 - pow(2, -10 * q))
    }

    private static func easeOutCubic(_ t: Double) -> CGFloat {
        let c = min(1, max(0, t))
        let inv = 1 - c
        return CGFloat(1 - inv * inv * inv)
    }

    private static func dampedSin(_ q: Double, freq: Double, decay: Double) -> CGFloat {
        let c = min(1, max(0, q))
        return CGFloat(exp(-decay * c) * sin(freq * c) * (1 - c))
    }

    // MARK: - Style 1: 流光 (.luminous — Explosive 3D Scatter, Squash-Stretch & Starburst)

    private struct LuminousShape {
        var dx: CGFloat
        var dy: CGFloat
        var rotateDeg: CGFloat
        var driftDeg: CGFloat
        var scale: CGFloat
        var fontScale: CGFloat
        var mode: EnterMode
        var isAccentColored: Bool
        var margin: CGFloat
        var width: CGFloat
        var height: CGFloat
        var font: NSFont
    }

    private func buildLuminousStage(words: [WordUnit], nowTime: TimeInterval, isPlaying: Bool, key: RenderKey) -> Int {
        let w = key.size.width
        let h = key.size.height
        let baseFontSize = min(64, max(36, round(w * 0.054)))
        let seed = floor(key.lineTime * 1000) + Double(key.text.count * 73)

        var shapes: [LuminousShape] = []
        shapes.reserveCapacity(words.count)
        for (i, word) in words.enumerated() {
            let ws = seed + Double(i) * 17.31
            let r0 = Self.lineRandom(seed: ws, offset: 1)
            let r1 = Self.lineRandom(seed: ws, offset: 2)
            let r2 = Self.lineRandom(seed: ws, offset: 3)
            let r3 = Self.lineRandom(seed: ws, offset: 4)
            let r4 = Self.lineRandom(seed: ws, offset: 5)
            let r5 = Self.lineRandom(seed: ws, offset: 6)

            let isClimax = (i == words.count - 1) || (word.end - word.start >= 0.55)
            let fontScale: CGFloat = isClimax ? (1.24 + r3 * 0.28) : (0.86 + r3 * 0.42)
            let wordFont = NSFont.systemFont(ofSize: round(baseFontSize * fontScale), weight: .black)
            let size = measureWord(word.text, font: wordFont)
            let mode = EnterMode(rawValue: Int(r4 * 100) % EnterMode.allCases.count) ?? .pop3D
            let isAccent = isClimax || r5 < 0.34

            shapes.append(LuminousShape(
                dx: (r0 - 0.5) * 44,
                dy: (r1 - 0.5) * 56,
                rotateDeg: (r2 - 0.5) * 24,
                driftDeg: (r5 - 0.5) * 18,
                scale: 1.04 + r3 * 0.22,
                fontScale: fontScale,
                mode: mode,
                isAccentColored: isAccent,
                margin: 0,
                width: size.width,
                height: size.height,
                font: wordFont
            ))
        }

        let gap = baseFontSize * 0.14
        for i in shapes.indices {
            let grow = shapes[i].width * (shapes[i].scale * 1.48 - 1) / 2
            let nextGrow = i + 1 < shapes.count ? shapes[i + 1].width * (shapes[i + 1].scale * 1.48 - 1) / 2 : 0
            let toward = i + 1 < shapes.count ? max(0, shapes[i].dx - shapes[i + 1].dx) : 0
            shapes[i].margin = max(gap * 1.5, grow + nextGrow + toward + gap)
        }
        if !shapes.isEmpty { shapes[shapes.count - 1].margin = 0 }

        let maxRowWidth = w * 0.80
        var rows: [Range<Int>] = []
        var rowStart = 0
        var runningW: CGFloat = 0
        for i in shapes.indices {
            let itemW = shapes[i].width + shapes[i].margin
            if i > rowStart && runningW + itemW > maxRowWidth {
                rows.append(rowStart..<i)
                rowStart = i
                runningW = itemW
            } else {
                runningW += itemW
            }
        }
        if rowStart < shapes.count {
            rows.append(rowStart..<shapes.count)
        }

        let lineEnd = (words.last?.end ?? (nowTime + 2)) + 0.90
        let remaining = max(0.05, lineEnd - nowTime)
        let rowSpacing = baseFontSize * 1.68
        let totalH = CGFloat(rows.count) * rowSpacing

        let lineBiasX = (Self.lineRandom(seed: seed, offset: 11) - 0.5) * (w * 0.14)
        let lineBiasY = (Self.lineRandom(seed: seed, offset: 12) - 0.5) * (h * 0.14)
        let diagSlope = (Self.lineRandom(seed: seed, offset: 13) - 0.5) * 0.18
        let startY = floor((h - totalH) / 2 + totalH - rowSpacing / 2 + lineBiasY + 20)

        for (ri, rowRange) in rows.enumerated() {
            var rowW: CGFloat = 0
            for idx in rowRange {
                rowW += shapes[idx].width + (idx + 1 < rowRange.upperBound ? shapes[idx].margin : 0)
            }
            let rowStaggerX = (Self.lineRandom(seed: seed + Double(ri) * 29, offset: 14) - 0.5) * (w * 0.16)
            var cursorX = floor((w - rowW) / 2 + lineBiasX + rowStaggerX)
            let rowY = startY - CGFloat(ri) * rowSpacing

            for idx in rowRange {
                let s = shapes[idx]
                let word = words[idx]
                let diagLift = (cursorX - w / 2) * diagSlope
                let center = CGPoint(x: cursorX + s.width / 2 + s.dx, y: rowY + s.dy + diagLift)
                let isLast = idx == words.count - 1
                addLuminousWordLayer(
                    word: word,
                    wordIndex: idx,
                    shape: s,
                    center: center,
                    isLast: isLast,
                    nowTime: nowTime,
                    remaining: remaining,
                    isPlaying: isPlaying,
                    key: key
                )
                cursorX += s.width + s.margin
            }
        }
        return rows.count
    }

    private func addLuminousWordLayer(
        word: WordUnit,
        wordIndex: Int,
        shape: LuminousShape,
        center: CGPoint,
        isLast: Bool,
        nowTime: TimeInterval,
        remaining: TimeInterval,
        isPlaying: Bool,
        key: RenderKey
    ) {
        let pad: CGFloat = 26
        let boxSize = CGSize(width: ceil(shape.width + pad * 2), height: ceil(shape.height + pad * 2))
        let wordLayer = CALayer()
        wordLayer.bounds = CGRect(origin: .zero, size: boxSize)
        wordLayer.position = center

        let fgColor: NSColor = shape.isAccentColored
            ? (key.palette.accent.blended(withFraction: 0.35, of: .white) ?? .white)
            : .white
        let glowImage = rasterizeWord(
            word.text,
            font: shape.font,
            size: boxSize,
            scale: key.backingScale,
            color: key.palette.accent,
            glowColor: key.palette.accent,
            glowBlur: shape.font.pointSize * 0.36
        )
        let bodyImage = rasterizeWord(
            word.text,
            font: shape.font,
            size: boxSize,
            scale: key.backingScale,
            color: fgColor,
            glowColor: shape.isAccentColored ? key.palette.accent : NSColor.black.withAlphaComponent(0.65),
            glowBlur: shape.isAccentColored ? 12 : 7
        )

        let glowLayer = CALayer()
        glowLayer.frame = wordLayer.bounds
        glowLayer.contents = glowImage
        glowLayer.contentsScale = key.backingScale

        let bodyLayer = CALayer()
        bodyLayer.frame = wordLayer.bounds
        bodyLayer.contents = bodyImage
        bodyLayer.contentsScale = key.backingScale

        wordLayer.addSublayer(glowLayer)
        wordLayer.addSublayer(bodyLayer)
        contentLayer.addSublayer(wordLayer)

        let ws = floor(word.start * 1000) + Double(wordIndex * 53)
        let dirSign: CGFloat = Self.lineRandom(seed: ws, offset: 21) < 0.5 ? -1 : 1
        let settledRot = shape.rotateDeg * .pi / 180

        let stateAt = { (t: TimeInterval) -> WordPose in
            let lookahead = 0.09
            let start = word.start - lookahead
            let end = max(word.end, word.start + 0.22)
            let since = t - start
            let after = t - end
            let enterSpan = 0.46

            if since <= 0 {
                switch shape.mode {
                case .pop3D:
                    return WordPose(
                        pos: CGPoint(x: center.x + sin(shape.dy) * 95, y: center.y + cos(shape.dx) * 65),
                        scaleX: 0.22,
                        scaleY: 0.22,
                        rotZ: settledRot + dirSign * 0.65,
                        rotX: dirSign * 0.95,
                        rotY: -dirSign * 0.85,
                        opacity: 0,
                        glow: 0
                    )
                case .dropSmash:
                    return WordPose(
                        pos: CGPoint(x: center.x + dirSign * 28, y: center.y + 135),
                        scaleX: 0.55,
                        scaleY: 1.75,
                        rotZ: settledRot + dirSign * 0.35,
                        rotX: 0.55,
                        rotY: 0,
                        opacity: 0,
                        glow: 0
                    )
                case .spinVortex:
                    return WordPose(
                        pos: CGPoint(x: center.x + dirSign * 120, y: center.y - dirSign * 85),
                        scaleX: 0.18,
                        scaleY: 0.18,
                        rotZ: settledRot - dirSign * 2.4,
                        rotX: 0,
                        rotY: dirSign * 1.1,
                        opacity: 0,
                        glow: 0
                    )
                case .elasticWhip:
                    return WordPose(
                        pos: CGPoint(x: center.x - dirSign * 155, y: center.y + shape.dy * 0.8),
                        scaleX: 2.35,
                        scaleY: 0.42,
                        rotZ: settledRot - dirSign * 0.45,
                        rotX: 0,
                        rotY: -dirSign * 0.75,
                        opacity: 0,
                        glow: 0
                    )
                }
            }

            let q = min(1, since / enterSpan)
            let activePeakScale = shape.scale * (isLast ? 1.62 : 1.48)
            var pos = center
            var sx = activePeakScale
            var sy = activePeakScale
            var rz = settledRot
            var rx: CGFloat = 0
            var ry: CGFloat = 0

            switch shape.mode {
            case .pop3D:
                let sp = Self.springValue(at: since)
                let waitX = center.x + sin(shape.dy) * 95
                let waitY = center.y + cos(shape.dx) * 65
                pos = CGPoint(x: waitX + (center.x - waitX) * sp, y: waitY + (center.y - waitY) * sp)
                let baseS = 0.22 + (activePeakScale - 0.22) * Self.easeOutBack(q, overshoot: 2.5)
                let jelly = Self.dampedSin(q, freq: 15, decay: 3.2)
                sx = baseS * (1 - 0.18 * jelly)
                sy = baseS * (1 + 0.24 * jelly)
                rz = settledRot + dirSign * 0.65 * (1 - sp)
                rx = dirSign * 0.95 * (1 - Self.easeOutCubic(q))
                ry = -dirSign * 0.85 * (1 - Self.easeOutCubic(q))

            case .dropSmash:
                if q < 0.44 {
                    let f = q / 0.44
                    pos.y = center.y + 135 * CGFloat(1 - f * f)
                    sx = activePeakScale * CGFloat(0.62 + 0.20 * f)
                    sy = activePeakScale * CGFloat(1.65 - 0.35 * f)
                    rx = CGFloat(0.55 * (1 - f))
                } else {
                    let f = (q - 0.44) / 0.56
                    let bounce = abs(sin(f * .pi * 2)) * exp(-3.2 * f) * (1 - f)
                    pos.y = center.y + CGFloat(bounce) * 34
                    let squash = Self.dampedSin(f, freq: 16, decay: 3.8)
                    sx = activePeakScale * (1 + 0.32 * squash)
                    sy = activePeakScale * (1 - 0.28 * squash)
                    rz = settledRot + dirSign * 0.18 * squash
                }

            case .spinVortex:
                let e = Self.easeOutCubic(q)
                let radius = 120 * (1 - e)
                let angle = Double(dirSign) * .pi * 2.2 * Double(1 - e)
                pos = CGPoint(
                    x: center.x + CGFloat(cos(angle)) * radius,
                    y: center.y + CGFloat(sin(angle)) * radius * 0.75
                )
                let sc = 0.18 + (activePeakScale - 0.18) * Self.easeOutBack(q, overshoot: 2.1)
                sx = sc
                sy = sc
                rz = settledRot - dirSign * 2.4 * (1 - Self.easeOutBack(q, overshoot: 1.6))
                ry = dirSign * 1.1 * (1 - e)

            case .elasticWhip:
                let spring = CGFloat(exp(-4.5 * q) * cos(q * .pi * 4.5) * (1 - q))
                pos.x = center.x - dirSign * 155 * spring
                pos.y = center.y + 24 * abs(spring)
                sx = activePeakScale * (1 + 0.42 * abs(spring))
                sy = activePeakScale * (1 - 0.26 * abs(spring))
                rz = settledRot - dirSign * 0.45 * spring
                ry = -dirSign * 0.75 * (1 - Self.easeOutCubic(q))
            }

            var op = Float(min(1, since / 0.08))
            var gl = Float(min(1, since / 0.10))

            if after > 0 {
                let settleQ = Self.easeOutCubic(after / 0.45)
                let targetS = shape.scale
                sx = sx + (targetS - sx) * settleQ
                sy = sy + (targetS - sy) * settleQ
                op = Float(1.0 - 0.14 * settleQ)
                gl = Float(max(0.15, 1 - after / 0.65))
                let driftQ = min(1, CGFloat(after / 4.0))
                rz = settledRot + (shape.driftDeg * .pi / 180) * driftQ
                pos.y += driftQ * (dirSign * 8)
            }

            return WordPose(pos: pos, scaleX: sx, scaleY: sy, rotZ: rz, rotX: rx, rotY: ry, opacity: op, glow: gl)
        }

        applyWordPoseTimeline(
            wordLayer: wordLayer,
            glowLayer: glowLayer,
            word: word,
            nowTime: nowTime,
            remaining: remaining,
            isPlaying: isPlaying,
            stateAt: stateAt
        )

        if key.sparks {
            let wordSize = CGSize(width: shape.width, height: shape.height)
            addSparksIfNeeded(
                in: contentLayer,
                center: center,
                wordSize: wordSize,
                word: word,
                isLast: isLast,
                nowTime: nowTime,
                remaining: remaining,
                isPlaying: isPlaying,
                accent: key.palette.accent
            )
            if isLast || shape.isAccentColored {
                addCrossStarburst(
                    in: contentLayer,
                    center: center,
                    wordSize: wordSize,
                    word: word,
                    isLast: isLast,
                    nowTime: nowTime,
                    remaining: remaining,
                    isPlaying: isPlaying,
                    accent: key.palette.accent
                )
            }
            if isLast || wordIndex.isMultiple(of: 2) {
                addShockwaveRing(
                    in: contentLayer,
                    center: center,
                    wordSize: wordSize,
                    word: word,
                    isLast: isLast,
                    nowTime: nowTime,
                    remaining: remaining,
                    isPlaying: isPlaying,
                    accent: key.palette.accent
                )
            }
        }
    }

    // MARK: - Style 2: 描金 (.inkTrace — 3D Scatter & Flip: Faint Wireframe → Fast Golden Outline → Solid Pop)

    private func buildInkTraceStage(words: [WordUnit], nowTime: TimeInterval, isPlaying: Bool, key: RenderKey) -> Int {
        let w = key.size.width
        let h = key.size.height
        let baseFontSize = min(68, max(40, round(w * 0.058)))
        let seed = floor(key.lineTime * 1000) + Double(key.text.count * 41)
        let lineEnd = (words.last?.end ?? (nowTime + 2)) + 0.90
        let remaining = max(0.05, lineEnd - nowTime)

        let champagneGold = NSColor(deviceRed: 1.0, green: 0.84, blue: 0.38, alpha: 1.0)
        let goldAccent = key.palette.accent.blended(withFraction: 0.55, of: champagneGold) ?? champagneGold
        let brightCoreGold = NSColor(deviceRed: 1.0, green: 0.96, blue: 0.82, alpha: 1.0)

        struct InkWordLayout {
            var font: NSFont
            var size: CGSize
            var dx: CGFloat
            var dy: CGFloat
            var rotDeg: CGFloat
            var isClimax: Bool
            var margin: CGFloat
        }

        var layouts: [InkWordLayout] = []
        layouts.reserveCapacity(words.count)
        for (i, word) in words.enumerated() {
            let ws = seed + Double(i) * 23.7
            let r0 = Self.lineRandom(seed: ws, offset: 1)
            let r1 = Self.lineRandom(seed: ws, offset: 2)
            let r2 = Self.lineRandom(seed: ws, offset: 3)
            let r3 = Self.lineRandom(seed: ws, offset: 4)
            let isClimax = (i == words.count - 1) || (word.end - word.start >= 0.5) || i == 0
            let fontScale: CGFloat = isClimax ? (1.20 + r3 * 0.30) : (0.90 + r3 * 0.32)
            let font = NSFont.systemFont(ofSize: round(baseFontSize * fontScale), weight: .black)
            let sz = measureWord(word.text, font: font)
            layouts.append(InkWordLayout(
                font: font,
                size: sz,
                dx: (r0 - 0.5) * 30,
                dy: (r1 - 0.5) * 40,
                rotDeg: (r2 - 0.5) * 16,
                isClimax: isClimax,
                margin: round(font.pointSize * 0.18)
            ))
        }
        if !layouts.isEmpty { layouts[layouts.count - 1].margin = 0 }

        let maxRowWidth = w * 0.82
        var rows: [Range<Int>] = []
        var rowStart = 0
        var runningW: CGFloat = 0
        for i in layouts.indices {
            let itemW = layouts[i].size.width + layouts[i].margin
            if i > rowStart && runningW + itemW > maxRowWidth {
                rows.append(rowStart..<i)
                rowStart = i
                runningW = itemW
            } else {
                runningW += itemW
            }
        }
        if rowStart < layouts.count {
            rows.append(rowStart..<layouts.count)
        }

        let rowSpacing = baseFontSize * 1.62
        let totalH = CGFloat(rows.count) * rowSpacing
        let topY = floor((h - totalH) / 2 + totalH - rowSpacing / 2 + 20)

        for (ri, rowRange) in rows.enumerated() {
            var rowW: CGFloat = 0
            for idx in rowRange {
                rowW += layouts[idx].size.width + (idx + 1 < rowRange.upperBound ? layouts[idx].margin : 0)
            }
            let rowStagger = (Self.lineRandom(seed: seed + Double(ri) * 19, offset: 8) - 0.5) * (w * 0.16)
            var cursorX = floor((w - rowW) / 2 + rowStagger)
            let rowY = topY - CGFloat(ri) * rowSpacing

            for idx in rowRange {
                let word = words[idx]
                let item = layouts[idx]
                let isLast = idx == words.count - 1
                let center = CGPoint(x: cursorX + item.size.width / 2 + item.dx, y: rowY + item.dy)
                let pad: CGFloat = 24
                let boxSize = CGSize(width: ceil(item.size.width + pad * 2), height: ceil(item.size.height + pad * 2))
                let glyphCGPath = Self.glyphPath(for: word.text, font: item.font, in: boxSize)

                let wordLayer = CALayer()
                wordLayer.bounds = CGRect(origin: .zero, size: boxSize)
                wordLayer.position = center

                // 1. Faint Wireframe (`wireframeLayer`, 0.08 alpha) while waiting.
                let wireframeLayer = CAShapeLayer()
                wireframeLayer.frame = wordLayer.bounds
                wireframeLayer.path = glyphCGPath
                wireframeLayer.fillColor = nil
                wireframeLayer.strokeColor = NSColor.white.withAlphaComponent(0.08).cgColor
                wireframeLayer.lineWidth = 1.2
                wireframeLayer.lineJoin = .round
                wireframeLayer.lineCap = .round

                // 2. Main "描金" Chiseled Gold/Neon Outer Stroke (`goldStrokeLayer`):
                //    Drawn at 6.8 pt width beneath `interiorMaskLayer` so the outer 3.4 pt forms a clean,
                //    unbroken silhouette border with zero internal variable-font overlapping lines!
                let strokeColor = item.isClimax ? goldAccent : (key.palette.accent.blended(withFraction: 0.45, of: champagneGold) ?? goldAccent)
                let goldStrokeLayer = CAShapeLayer()
                goldStrokeLayer.frame = wordLayer.bounds
                goldStrokeLayer.path = glyphCGPath
                goldStrokeLayer.fillColor = nil
                goldStrokeLayer.strokeColor = strokeColor.cgColor
                goldStrokeLayer.lineWidth = item.isClimax ? 7.6 : 6.4
                goldStrokeLayer.lineJoin = .round
                goldStrokeLayer.lineCap = .round
                goldStrokeLayer.shadowColor = strokeColor.cgColor
                goldStrokeLayer.shadowRadius = 15
                goldStrokeLayer.shadowOpacity = 1.0
                goldStrokeLayer.shadowOffset = .zero

                // 3. Inner Razor-Sharp Champagne Gold Bevel (`innerGoldLayer`).
                let innerGoldLayer = CAShapeLayer()
                innerGoldLayer.frame = wordLayer.bounds
                innerGoldLayer.path = glyphCGPath
                innerGoldLayer.fillColor = nil
                innerGoldLayer.strokeColor = brightCoreGold.cgColor
                innerGoldLayer.lineWidth = 3.4
                innerGoldLayer.lineJoin = .round
                innerGoldLayer.lineCap = .round

                // 4. Traveling White-Hot Laser Nib (`cometLaserLayer`).
                let cometLaserLayer = CAShapeLayer()
                cometLaserLayer.frame = wordLayer.bounds
                cometLaserLayer.path = glyphCGPath
                cometLaserLayer.fillColor = nil
                cometLaserLayer.strokeColor = NSColor.white.cgColor
                cometLaserLayer.lineWidth = 9.0
                cometLaserLayer.lineCap = .round
                cometLaserLayer.shadowColor = brightCoreGold.cgColor
                cometLaserLayer.shadowRadius = 12
                cometLaserLayer.shadowOpacity = 1.0
                cometLaserLayer.shadowOffset = .zero
                cometLaserLayer.opacity = 0

                // 5. Dark-Glass Hollow Interior Mask (`interiorMaskLayer` with `.nonZero` winding):
                //    Only turns visible once `traceStart` begins so unsung characters stay faint!
                let interiorMaskLayer = CAShapeLayer()
                interiorMaskLayer.frame = wordLayer.bounds
                interiorMaskLayer.path = glyphCGPath
                interiorMaskLayer.fillRule = .nonZero
                interiorMaskLayer.fillColor = key.palette.backgroundBottom.blended(withFraction: 0.16, of: strokeColor)?.cgColor
                    ?? NSColor(deviceWhite: 0.06, alpha: 0.94).cgColor
                interiorMaskLayer.strokeColor = nil

                // 6. Solid Glowing Character Fill (`solidFillLayer`):
                //    Stays at opacity 0 while the gold laser rapidly traces the hollow outline (`strokeEnd: 0 → 1`),
                //    then flashes into a solid glowing character as soon as the outline closes!
                let solidColor: NSColor = item.isClimax
                    ? (brightCoreGold.blended(withFraction: 0.3, of: .white) ?? .white)
                    : .white
                let solidImage = rasterizeWord(
                    word.text,
                    font: item.font,
                    size: boxSize,
                    scale: key.backingScale,
                    color: solidColor,
                    glowColor: strokeColor,
                    glowBlur: 12
                )
                let solidFillLayer = CALayer()
                solidFillLayer.frame = wordLayer.bounds
                solidFillLayer.contents = solidImage
                solidFillLayer.contentsScale = key.backingScale

                wordLayer.addSublayer(wireframeLayer)
                wordLayer.addSublayer(goldStrokeLayer)
                wordLayer.addSublayer(innerGoldLayer)
                wordLayer.addSublayer(cometLaserLayer)
                wordLayer.addSublayer(interiorMaskLayer)
                wordLayer.addSublayer(solidFillLayer)
                contentLayer.addSublayer(wordLayer)

                let traceStart = word.start - 0.16
                let strokeDoneTime = traceStart + 0.28
                let traceEnd = max(word.end, strokeDoneTime + 0.16)

                let strokeProgress = CGFloat(min(1, max(0, (nowTime - traceStart) / 0.28)))
                let fillProgress = CGFloat(min(1, max(0, (nowTime - strokeDoneTime) / max(0.08, traceEnd - strokeDoneTime))))
                let activeOp = Float(strokeProgress > 0 ? 1.0 : 0.0)
                let rotRad = item.rotDeg * .pi / 180
                let dirSign: CGFloat = idx.isMultiple(of: 2) ? 1 : -1

                goldStrokeLayer.strokeEnd = isPlaying ? 1.0 : strokeProgress
                innerGoldLayer.strokeEnd = isPlaying ? 1.0 : strokeProgress
                goldStrokeLayer.opacity = isPlaying ? 1.0 : activeOp
                innerGoldLayer.opacity = isPlaying ? 1.0 : activeOp
                interiorMaskLayer.opacity = isPlaying ? 1.0 : activeOp
                solidFillLayer.opacity = isPlaying ? 1.0 : Float(fillProgress)
                wordLayer.transform = CATransform3DMakeRotation(rotRad, 0, 0, 1)

                if isPlaying, traceEnd + 0.5 > nowTime {
                    var times: [TimeInterval] = [nowTime]
                    var strokeVals: [CGFloat] = [strokeProgress]
                    var strokeOpVals: [Float] = [activeOp]
                    var fillOpVals: [Float] = [Float(fillProgress)]
                    var cometStartVals: [CGFloat] = [max(0, strokeProgress - 0.24)]
                    var cometEndVals: [CGFloat] = [strokeProgress]
                    var cometOpVals: [Float] = [strokeProgress > 0 && strokeProgress < 1 ? 1.0 : 0.0]
                    var scaleVals: [CGFloat] = [fillProgress > 0 ? 1.0 : 0.88]
                    var rotYVals: [CGFloat] = [strokeProgress > 0 ? 0 : dirSign * 0.48]

                    if traceStart > nowTime {
                        times.append(traceStart)
                        strokeVals.append(0.0)
                        strokeOpVals.append(1.0)
                        fillOpVals.append(0.0)
                        cometStartVals.append(0.0)
                        cometEndVals.append(0.05)
                        cometOpVals.append(1.0)
                        scaleVals.append(0.88)
                        rotYVals.append(dirSign * 0.48)
                    }

                    let strokeMidTime = (max(nowTime, traceStart) + strokeDoneTime) / 2
                    if strokeMidTime > (times.last ?? nowTime), strokeMidTime < strokeDoneTime {
                        times.append(strokeMidTime)
                        strokeVals.append(0.58)
                        strokeOpVals.append(1.0)
                        fillOpVals.append(0.0)
                        cometStartVals.append(0.32)
                        cometEndVals.append(0.62)
                        cometOpVals.append(1.0)
                        scaleVals.append(1.06)
                        rotYVals.append(dirSign * 0.16)
                    }

                    if strokeDoneTime > (times.last ?? nowTime) {
                        times.append(strokeDoneTime)
                        strokeVals.append(1.0)
                        strokeOpVals.append(1.0)
                        fillOpVals.append(0.06)
                        cometStartVals.append(0.78)
                        cometEndVals.append(1.0)
                        cometOpVals.append(1.0)
                        scaleVals.append(1.14)
                        rotYVals.append(0.0)
                    }

                    if traceEnd > (times.last ?? nowTime) {
                        times.append(traceEnd)
                        strokeVals.append(1.0)
                        strokeOpVals.append(1.0)
                        fillOpVals.append(1.0)
                        cometStartVals.append(1.0)
                        cometEndVals.append(1.0)
                        cometOpVals.append(0.0)
                        scaleVals.append(item.isClimax ? 1.44 : 1.30)
                        rotYVals.append(-dirSign * 0.10)
                    }

                    let settleTime = min(lineEnd, traceEnd + 0.24)
                    if settleTime > (times.last ?? nowTime) {
                        times.append(settleTime)
                        strokeVals.append(1.0)
                        strokeOpVals.append(1.0)
                        fillOpVals.append(1.0)
                        cometStartVals.append(1.0)
                        cometEndVals.append(1.0)
                        cometOpVals.append(0.0)
                        scaleVals.append(1.0)
                        rotYVals.append(0.0)
                    }

                    if lineEnd > (times.last ?? nowTime) {
                        times.append(lineEnd)
                        strokeVals.append(1.0)
                        strokeOpVals.append(1.0)
                        fillOpVals.append(0.94)
                        cometStartVals.append(1.0)
                        cometEndVals.append(1.0)
                        cometOpVals.append(0.0)
                        scaleVals.append(1.0)
                        rotYVals.append(0.0)
                    }

                    let keyTimes = times.map { NSNumber(value: min(1, max(0, ($0 - nowTime) / remaining))) }

                    let strokeAnim = CAKeyframeAnimation(keyPath: "strokeEnd")
                    strokeAnim.keyTimes = keyTimes
                    strokeAnim.values = strokeVals.map { NSNumber(value: Double($0)) }
                    strokeAnim.duration = remaining

                    let strokeOpAnim = CAKeyframeAnimation(keyPath: "opacity")
                    strokeOpAnim.keyTimes = keyTimes
                    strokeOpAnim.values = strokeOpVals.map { NSNumber(value: $0) }
                    strokeOpAnim.duration = remaining

                    let strokeGroup = CAAnimationGroup()
                    strokeGroup.animations = [strokeAnim, strokeOpAnim]
                    strokeGroup.duration = remaining
                    goldStrokeLayer.add(strokeGroup, forKey: Self.stageAnimKey)
                    innerGoldLayer.add(strokeGroup, forKey: Self.stageAnimKey)
                    interiorMaskLayer.add(strokeOpAnim, forKey: Self.stageAnimKey)

                    let fillOpAnim = CAKeyframeAnimation(keyPath: "opacity")
                    fillOpAnim.keyTimes = keyTimes
                    fillOpAnim.values = fillOpVals.map { NSNumber(value: $0) }
                    fillOpAnim.duration = remaining
                    solidFillLayer.add(fillOpAnim, forKey: Self.stageAnimKey)

                    let cometStartAnim = CAKeyframeAnimation(keyPath: "strokeStart")
                    cometStartAnim.keyTimes = keyTimes
                    cometStartAnim.values = cometStartVals.map { NSNumber(value: Double($0)) }
                    cometStartAnim.duration = remaining

                    let cometEndAnim = CAKeyframeAnimation(keyPath: "strokeEnd")
                    cometEndAnim.keyTimes = keyTimes
                    cometEndAnim.values = cometEndVals.map { NSNumber(value: Double($0)) }
                    cometEndAnim.duration = remaining

                    let cometOpAnim = CAKeyframeAnimation(keyPath: "opacity")
                    cometOpAnim.keyTimes = keyTimes
                    cometOpAnim.values = cometOpVals.map { NSNumber(value: $0) }
                    cometOpAnim.duration = remaining

                    let cometGroup = CAAnimationGroup()
                    cometGroup.animations = [cometStartAnim, cometEndAnim, cometOpAnim]
                    cometGroup.duration = remaining
                    cometLaserLayer.add(cometGroup, forKey: Self.stageAnimKey)

                    let scaleAnim = CAKeyframeAnimation(keyPath: "transform.scale")
                    scaleAnim.keyTimes = keyTimes
                    scaleAnim.values = scaleVals.map { NSNumber(value: Double($0)) }
                    scaleAnim.duration = remaining

                    let rotYAnim = CAKeyframeAnimation(keyPath: "transform.rotation.y")
                    rotYAnim.keyTimes = keyTimes
                    rotYAnim.values = rotYVals.map { NSNumber(value: Double($0)) }
                    rotYAnim.duration = remaining

                    let wordGroup = CAAnimationGroup()
                    wordGroup.animations = [scaleAnim, rotYAnim]
                    wordGroup.duration = remaining
                    wordLayer.add(wordGroup, forKey: Self.stageAnimKey)
                }

                // Only trigger the expanding ghost echo + starburst on climax/final characters, not on every character!
                if item.isClimax || isLast {
                    let echoOutlineLayer = CAShapeLayer()
                    echoOutlineLayer.frame = wordLayer.bounds
                    echoOutlineLayer.path = glyphCGPath
                    echoOutlineLayer.strokeColor = goldAccent.cgColor
                    echoOutlineLayer.fillColor = nil
                    echoOutlineLayer.lineWidth = 2.4
                    echoOutlineLayer.opacity = 0
                    wordLayer.insertSublayer(echoOutlineLayer, below: wireframeLayer)

                    if isPlaying, traceEnd + 0.45 > nowTime {
                        let echoStart = strokeDoneTime
                        let echoEnd = traceEnd + 0.40
                        var eTimes: [TimeInterval] = [nowTime]
                        var eScales: [CGFloat] = [1.0]
                        var eOps: [Float] = [0.0]
                        if echoStart > nowTime {
                            eTimes.append(echoStart)
                            eScales.append(1.0)
                            eOps.append(0.0)
                        }
                        let ePeak = min(echoEnd, max(nowTime, echoStart) + 0.06)
                        if ePeak > (eTimes.last ?? nowTime) {
                            eTimes.append(ePeak)
                            eScales.append(1.12)
                            eOps.append(0.90)
                        }
                        eTimes.append(echoEnd)
                        eScales.append(1.95)
                        eOps.append(0.0)
                        if lineEnd > echoEnd {
                            eTimes.append(lineEnd)
                            eScales.append(1.95)
                            eOps.append(0.0)
                        }
                        let eKeyTimes = eTimes.map { NSNumber(value: min(1, max(0, ($0 - nowTime) / remaining))) }
                        let eScaleAnim = CAKeyframeAnimation(keyPath: "transform.scale")
                        eScaleAnim.keyTimes = eKeyTimes
                        eScaleAnim.values = eScales.map { NSNumber(value: Double($0)) }
                        eScaleAnim.duration = remaining

                        let eOpAnim = CAKeyframeAnimation(keyPath: "opacity")
                        eOpAnim.keyTimes = eKeyTimes
                        eOpAnim.values = eOps.map { NSNumber(value: $0) }
                        eOpAnim.duration = remaining

                        let eGroup = CAAnimationGroup()
                        eGroup.animations = [eScaleAnim, eOpAnim]
                        eGroup.duration = remaining
                        echoOutlineLayer.add(eGroup, forKey: Self.stageAnimKey)
                    }

                    if key.sparks {
                        addGeometricOrnament(
                            in: contentLayer,
                            center: center,
                            wordSize: item.size,
                            word: word,
                            wordIndex: idx,
                            isLast: isLast,
                            nowTime: nowTime,
                            remaining: remaining,
                            isPlaying: isPlaying,
                            accent: goldAccent
                        )
                        addSparksIfNeeded(
                            in: contentLayer,
                            center: center,
                            wordSize: item.size,
                            word: word,
                            isLast: isLast,
                            nowTime: nowTime,
                            remaining: remaining,
                            isPlaying: isPlaying,
                            accent: goldAccent
                        )
                        addCrossStarburst(
                            in: contentLayer,
                            center: center,
                            wordSize: item.size,
                            word: word,
                            isLast: isLast,
                            nowTime: nowTime,
                            remaining: remaining,
                            isPlaying: isPlaying,
                            accent: goldAccent
                        )
                    }
                }
                cursorX += item.size.width + item.margin
            }
        }
        return rows.count
    }

    /// Extracts the combined CoreText vector `CGPath` for a word's glyphs centered in `boxSize`.
    static func glyphPath(for text: String, font: NSFont, in boxSize: CGSize) -> CGPath {
        let combined = CGMutablePath()
        let attr = NSAttributedString(string: text, attributes: [.font: font])
        let ctLine = CTLineCreateWithAttributedString(attr)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let lineW = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading))
        let originX = floor((boxSize.width - lineW) / 2)
        let baselineY = floor((boxSize.height - (ascent + descent)) / 2 + descent)

        let runs = CTLineGetGlyphRuns(ctLine) as? [CTRun] ?? []
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            let attrs = CTRunGetAttributes(run) as NSDictionary
            let runFont = (attrs[kCTFontAttributeName] as! CTFont?) ?? (font as CTFont)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRangeMake(0, count), &glyphs)
            CTRunGetPositions(run, CFRangeMake(0, count), &positions)
            for i in 0..<count {
                if let gp = CTFontCreatePathForGlyph(runFont, glyphs[i], nil) {
                    let transform = CGAffineTransform(translationX: originX + positions[i].x, y: baselineY + positions[i].y)
                    combined.addPath(gp, transform: transform)
                }
            }
        }
        return combined
    }

    // MARK: - 3D Pose Keyframe Compiler & Explosive Ornaments (Cross Starburst / Shockwave Ring / HUD Shapes)

    private func applyWordPoseTimeline(
        wordLayer: CALayer,
        glowLayer: CALayer,
        word: WordUnit,
        nowTime: TimeInterval,
        remaining: TimeInterval,
        isPlaying: Bool,
        stateAt: (TimeInterval) -> WordPose
    ) {
        let initial = stateAt(nowTime)
        let endState = stateAt(nowTime + remaining)
        let modelState = isPlaying ? endState : initial

        wordLayer.position = modelState.pos
        wordLayer.opacity = modelState.opacity
        wordLayer.transform = Self.makeTransform(modelState)
        glowLayer.opacity = modelState.glow

        guard isPlaying else { return }

        var sampleTimes: [TimeInterval] = [nowTime]
        let animStart = word.start - 0.09
        let animFinish = max(word.end + 0.70, word.start + 0.70)
        if animStart > nowTime {
            sampleTimes.append(animStart)
        }
        let steps = 14
        let windowFrom = max(nowTime, animStart)
        let windowTo = min(nowTime + remaining, animFinish)
        if windowTo > windowFrom {
            for s in 1...steps {
                let t = windowFrom + (windowTo - windowFrom) * Double(s) / Double(steps)
                sampleTimes.append(t)
            }
        }
        let finalTime = nowTime + remaining
        if sampleTimes.last != finalTime {
            sampleTimes.append(finalTime)
        }

        let keyTimes = sampleTimes.map { NSNumber(value: min(1, max(0, ($0 - nowTime) / remaining))) }
        let states = sampleTimes.map(stateAt)

        let posAnim = CAKeyframeAnimation(keyPath: "position")
        posAnim.keyTimes = keyTimes
        posAnim.values = states.map { NSValue(point: $0.pos) }
        posAnim.duration = remaining

        let transformAnim = CAKeyframeAnimation(keyPath: "transform")
        transformAnim.keyTimes = keyTimes
        transformAnim.values = states.map { NSValue(caTransform3D: Self.makeTransform($0)) }
        transformAnim.duration = remaining

        let opAnim = CAKeyframeAnimation(keyPath: "opacity")
        opAnim.keyTimes = keyTimes
        opAnim.values = states.map { NSNumber(value: $0.opacity) }
        opAnim.duration = remaining

        let group = CAAnimationGroup()
        group.animations = [posAnim, transformAnim, opAnim]
        group.duration = remaining
        wordLayer.add(group, forKey: Self.stageAnimKey)

        let glowAnim = CAKeyframeAnimation(keyPath: "opacity")
        glowAnim.keyTimes = keyTimes
        glowAnim.values = states.map { NSNumber(value: $0.glow) }
        glowAnim.duration = remaining
        glowLayer.add(glowAnim, forKey: Self.stageAnimKey)
    }

    private static func makeTransform(_ pose: WordPose) -> CATransform3D {
        var t = CATransform3DIdentity
        if pose.rotX != 0 {
            t = CATransform3DRotate(t, pose.rotX, 1, 0, 0)
        }
        if pose.rotY != 0 {
            t = CATransform3DRotate(t, pose.rotY, 0, 1, 0)
        }
        if pose.rotZ != 0 {
            t = CATransform3DRotate(t, pose.rotZ, 0, 0, 1)
        }
        t = CATransform3DScale(t, max(0.05, pose.scaleX), max(0.05, pose.scaleY), 1)
        return t
    }

    /// EVA / Lumiere-style 4-point cross flare (`✦`) that flashes white-hot when a key word lands.
    private func addCrossStarburst(
        in parent: CALayer,
        center: CGPoint,
        wordSize: CGSize,
        word: WordUnit,
        isLast: Bool,
        nowTime: TimeInterval,
        remaining: TimeInterval,
        isPlaying: Bool,
        accent: NSColor
    ) {
        let burstDuration = 0.52
        let burstEnd = word.start + burstDuration
        guard isPlaying, burstEnd > nowTime else { return }

        let armH = max(wordSize.width, 72) * (isLast ? 1.65 : 1.25)
        let armV = max(wordSize.height, 64) * (isLast ? 2.10 : 1.55)
        let diag = min(armH, armV) * 0.48

        let crossPath = CGMutablePath()
        crossPath.move(to: CGPoint(x: -armH, y: 0))
        crossPath.addLine(to: CGPoint(x: armH, y: 0))
        crossPath.move(to: CGPoint(x: 0, y: -armV))
        crossPath.addLine(to: CGPoint(x: 0, y: armV))
        crossPath.move(to: CGPoint(x: -diag, y: -diag))
        crossPath.addLine(to: CGPoint(x: diag, y: diag))
        crossPath.move(to: CGPoint(x: -diag, y: diag))
        crossPath.addLine(to: CGPoint(x: diag, y: -diag))

        let crossLayer = CAShapeLayer()
        crossLayer.path = crossPath
        crossLayer.position = center
        crossLayer.strokeColor = NSColor.white.cgColor
        crossLayer.lineWidth = isLast ? 2.6 : 1.8
        crossLayer.lineCap = .round
        crossLayer.shadowColor = accent.cgColor
        crossLayer.shadowRadius = 14
        crossLayer.shadowOpacity = 1.0
        crossLayer.shadowOffset = .zero
        crossLayer.opacity = 0
        parent.addSublayer(crossLayer)

        var times: [TimeInterval] = [nowTime]
        var scales: [CGFloat] = [0.1]
        var ops: [Float] = [0]

        if word.start > nowTime {
            times.append(word.start)
            scales.append(0.15)
            ops.append(0)
        }
        let flashPeak = min(burstEnd, max(nowTime, word.start) + 0.06)
        if flashPeak > (times.last ?? nowTime) {
            times.append(flashPeak)
            scales.append(1.15)
            ops.append(1.0)
        }
        times.append(burstEnd)
        scales.append(1.65)
        ops.append(0)

        let endT = nowTime + remaining
        if endT > burstEnd {
            times.append(endT)
            scales.append(1.65)
            ops.append(0)
        }

        let keyTimes = times.map { NSNumber(value: min(1, max(0, ($0 - nowTime) / remaining))) }

        let scaleAnim = CAKeyframeAnimation(keyPath: "transform.scale")
        scaleAnim.keyTimes = keyTimes
        scaleAnim.values = scales.map { NSNumber(value: Double($0)) }
        scaleAnim.duration = remaining

        let opAnim = CAKeyframeAnimation(keyPath: "opacity")
        opAnim.keyTimes = keyTimes
        opAnim.values = ops.map { NSNumber(value: $0) }
        opAnim.duration = remaining

        let group = CAAnimationGroup()
        group.animations = [scaleAnim, opAnim]
        group.duration = remaining
        crossLayer.add(group, forKey: Self.stageAnimKey)
    }

    /// Expanding concentric shockwave ring (`ringOrnament` from Folia `hanabi`).
    private func addShockwaveRing(
        in parent: CALayer,
        center: CGPoint,
        wordSize: CGSize,
        word: WordUnit,
        isLast: Bool,
        nowTime: TimeInterval,
        remaining: TimeInterval,
        isPlaying: Bool,
        accent: NSColor
    ) {
        let ringDuration = 0.68
        let ringEnd = word.start + ringDuration
        guard isPlaying, ringEnd > nowTime else { return }

        let baseR = max(wordSize.width, wordSize.height) * (isLast ? 0.85 : 0.62)
        let ringPath = CGMutablePath()
        ringPath.addEllipse(in: CGRect(x: -baseR, y: -baseR, width: baseR * 2, height: baseR * 2))

        let ringLayer = CAShapeLayer()
        ringLayer.path = ringPath
        ringLayer.position = center
        ringLayer.fillColor = nil
        ringLayer.strokeColor = accent.blended(withFraction: 0.35, of: .white)?.cgColor ?? accent.cgColor
        ringLayer.lineWidth = isLast ? 2.4 : 1.6
        if !isLast {
            ringLayer.lineDashPattern = [10, 6]
        }
        ringLayer.opacity = 0
        parent.addSublayer(ringLayer)

        var times: [TimeInterval] = [nowTime]
        var scales: [CGFloat] = [0.2]
        var ops: [Float] = [0]

        if word.start > nowTime {
            times.append(word.start)
            scales.append(0.25)
            ops.append(0)
        }
        let mid = min(ringEnd, max(nowTime, word.start) + 0.10)
        if mid > (times.last ?? nowTime) {
            times.append(mid)
            scales.append(0.85)
            ops.append(0.92)
        }
        times.append(ringEnd)
        scales.append(isLast ? 2.25 : 1.75)
        ops.append(0)

        let endT = nowTime + remaining
        if endT > ringEnd {
            times.append(endT)
            scales.append(2.25)
            ops.append(0)
        }

        let keyTimes = times.map { NSNumber(value: min(1, max(0, ($0 - nowTime) / remaining))) }

        let scaleAnim = CAKeyframeAnimation(keyPath: "transform.scale")
        scaleAnim.keyTimes = keyTimes
        scaleAnim.values = scales.map { NSNumber(value: Double($0)) }
        scaleAnim.duration = remaining

        let opAnim = CAKeyframeAnimation(keyPath: "opacity")
        opAnim.keyTimes = keyTimes
        opAnim.values = ops.map { NSNumber(value: $0) }
        opAnim.duration = remaining

        let group = CAAnimationGroup()
        group.animations = [scaleAnim, opAnim]
        group.duration = remaining
        ringLayer.add(group, forKey: Self.stageAnimKey)
    }

    /// Geometric PV ornaments (`◇` diamond frame, `⌜⌟` corner brackets, or diagonal slash) for `.inkTrace`.
    private func addGeometricOrnament(
        in parent: CALayer,
        center: CGPoint,
        wordSize: CGSize,
        word: WordUnit,
        wordIndex: Int,
        isLast: Bool,
        nowTime: TimeInterval,
        remaining: TimeInterval,
        isPlaying: Bool,
        accent: NSColor
    ) {
        let dur = 0.62
        let end = word.start + dur
        guard isPlaying, end > nowTime else { return }

        let path = CGMutablePath()
        let hw = wordSize.width / 2 + 12
        let hh = wordSize.height / 2 + 10
        let kind = (wordIndex + Int(floor(word.start * 10))) % 3

        switch kind {
        case 0:
            // Rotating diamond frame (`◇`).
            let r = max(hw, hh) * 1.15
            path.move(to: CGPoint(x: 0, y: r))
            path.addLine(to: CGPoint(x: r, y: 0))
            path.addLine(to: CGPoint(x: 0, y: -r))
            path.addLine(to: CGPoint(x: -r, y: 0))
            path.closeSubpath()
        case 1:
            // Corner HUD target brackets (`⌜ ⌟`).
            let arm: CGFloat = 14
            path.move(to: CGPoint(x: -hw, y: hh - arm))
            path.addLine(to: CGPoint(x: -hw, y: hh))
            path.addLine(to: CGPoint(x: -hw + arm, y: hh))
            path.move(to: CGPoint(x: hw - arm, y: -hh))
            path.addLine(to: CGPoint(x: hw, y: -hh))
            path.addLine(to: CGPoint(x: hw, y: -hh + arm))
        default:
            // Diagonal katana slash line across the word.
            let sx = hw * 1.45
            let sy = hh * 1.25
            path.move(to: CGPoint(x: -sx, y: -sy))
            path.addLine(to: CGPoint(x: sx, y: sy))
        }

        let layer = CAShapeLayer()
        layer.path = path
        layer.position = center
        layer.fillColor = nil
        layer.strokeColor = (isLast ? NSColor.white : accent).cgColor
        layer.lineWidth = isLast ? 2.2 : 1.6
        layer.opacity = 0
        parent.addSublayer(layer)

        var times: [TimeInterval] = [nowTime]
        var scales: [CGFloat] = [0.4]
        var rots: [CGFloat] = [-0.35]
        var ops: [Float] = [0]

        if word.start > nowTime {
            times.append(word.start)
            scales.append(0.45)
            rots.append(-0.35)
            ops.append(0)
        }
        let peak = min(end, max(nowTime, word.start) + 0.09)
        if peak > (times.last ?? nowTime) {
            times.append(peak)
            scales.append(1.08)
            rots.append(0.0)
            ops.append(0.90)
        }
        times.append(end)
        scales.append(1.42)
        rots.append(0.22)
        ops.append(0)

        let endT = nowTime + remaining
        if endT > end {
            times.append(endT)
            scales.append(1.42)
            rots.append(0.22)
            ops.append(0)
        }

        let keyTimes = times.map { NSNumber(value: min(1, max(0, ($0 - nowTime) / remaining))) }

        let scaleAnim = CAKeyframeAnimation(keyPath: "transform.scale")
        scaleAnim.keyTimes = keyTimes
        scaleAnim.values = scales.map { NSNumber(value: Double($0)) }
        scaleAnim.duration = remaining

        let rotAnim = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        rotAnim.keyTimes = keyTimes
        rotAnim.values = rots.map { NSNumber(value: Double($0)) }
        rotAnim.duration = remaining

        let opAnim = CAKeyframeAnimation(keyPath: "opacity")
        opAnim.keyTimes = keyTimes
        opAnim.values = ops.map { NSNumber(value: $0) }
        opAnim.duration = remaining

        let group = CAAnimationGroup()
        group.animations = [scaleAnim, rotAnim, opAnim]
        group.duration = remaining
        layer.add(group, forKey: Self.stageAnimKey)
    }

    private func addSparksIfNeeded(
        in parent: CALayer,
        center: CGPoint,
        wordSize: CGSize,
        word: WordUnit,
        isLast: Bool,
        nowTime: TimeInterval,
        remaining: TimeInterval,
        isPlaying: Bool,
        accent: NSColor
    ) {
        let sparkDuration = 0.62
        let sparkEnd = word.start + sparkDuration
        guard isPlaying, sparkEnd > nowTime else { return }

        let count = isLast ? 20 : 11
        let reach = max(wordSize.width, wordSize.height) * (isLast ? 1.55 : 0.98)
        let seed = floor(word.start * 1000)

        let sparkPath = CGMutablePath()
        for i in 0..<count {
            let jitter = Double(Self.lineRandom(seed: seed, offset: Double(i))) * 0.75
            let angle = 2 * .pi * (Double(i) + jitter) / Double(count)
            let dx = CGFloat(cos(angle))
            let dy = CGFloat(sin(angle))
            let inner = max(wordSize.width, wordSize.height) * 0.28
            let outer = inner + reach * (0.50 + 0.65 * Self.lineRandom(seed: seed, offset: Double(i) + 40))
            sparkPath.move(to: CGPoint(x: center.x + dx * inner, y: center.y + dy * inner))
            sparkPath.addLine(to: CGPoint(x: center.x + dx * outer, y: center.y + dy * outer))
        }

        let sparkLayer = CAShapeLayer()
        sparkLayer.path = sparkPath
        sparkLayer.strokeColor = accent.blended(withFraction: 0.5, of: .white)?.cgColor ?? accent.cgColor
        sparkLayer.fillColor = nil
        sparkLayer.lineWidth = isLast ? 2.4 : 1.7
        sparkLayer.lineCap = .round
        sparkLayer.shadowColor = accent.cgColor
        sparkLayer.shadowRadius = 8
        sparkLayer.shadowOpacity = 0.85
        sparkLayer.opacity = 0
        parent.addSublayer(sparkLayer)

        var times: [TimeInterval] = [nowTime]
        var headVals: [CGFloat] = [0]
        var tailVals: [CGFloat] = [0]
        var opVals: [Float] = [0]

        if word.start > nowTime {
            times.append(word.start)
            headVals.append(0)
            tailVals.append(0)
            opVals.append(0)
        }
        let peak = min(sparkEnd, max(nowTime, word.start) + sparkDuration * 0.28)
        if peak > nowTime {
            times.append(peak)
            headVals.append(0.88)
            tailVals.append(0.18)
            opVals.append(1.0)
        }
        times.append(sparkEnd)
        headVals.append(1.0)
        tailVals.append(0.95)
        opVals.append(0)

        let endT = nowTime + remaining
        if endT > sparkEnd {
            times.append(endT)
            headVals.append(1.0)
            tailVals.append(1.0)
            opVals.append(0)
        }

        let keyTimes = times.map { NSNumber(value: min(1, max(0, ($0 - nowTime) / remaining))) }

        let endAnim = CAKeyframeAnimation(keyPath: "strokeEnd")
        endAnim.keyTimes = keyTimes
        endAnim.values = headVals.map { NSNumber(value: Double($0)) }
        endAnim.duration = remaining

        let startAnim = CAKeyframeAnimation(keyPath: "strokeStart")
        startAnim.keyTimes = keyTimes
        startAnim.values = tailVals.map { NSNumber(value: Double($0)) }
        startAnim.duration = remaining

        let opAnim = CAKeyframeAnimation(keyPath: "opacity")
        opAnim.keyTimes = keyTimes
        opAnim.values = opVals.map { NSNumber(value: $0) }
        opAnim.duration = remaining

        let group = CAAnimationGroup()
        group.animations = [endAnim, startAnim, opAnim]
        group.duration = remaining
        sparkLayer.add(group, forKey: Self.stageAnimKey)
    }

    // MARK: - Vinyl Interlude Centerpiece

    private func buildVinylInterlude(interlude: Interlude, nowTime: TimeInterval, isPlaying: Bool, key: RenderKey) {
        let w = key.size.width
        let h = key.size.height
        let discRadius = min(105, max(68, min(w, h) * 0.20))
        let discCenter = CGPoint(x: w / 2, y: h * 0.56)

        let discContainer = CALayer()
        discContainer.bounds = CGRect(x: 0, y: 0, width: discRadius * 2, height: discRadius * 2)
        discContainer.position = discCenter

        let vinylLayer = CAShapeLayer()
        let vinylPath = CGMutablePath()
        vinylPath.addEllipse(in: discContainer.bounds)
        vinylLayer.path = vinylPath
        vinylLayer.fillColor = NSColor(deviceWhite: 0.06, alpha: 0.92).cgColor
        vinylLayer.strokeColor = key.palette.accent.withAlphaComponent(0.38).cgColor
        vinylLayer.lineWidth = 1.5
        vinylLayer.shadowColor = NSColor.black.cgColor
        vinylLayer.shadowRadius = 24
        vinylLayer.shadowOpacity = 0.65
        vinylLayer.shadowOffset = CGSize(width: 0, height: -8)
        discContainer.addSublayer(vinylLayer)

        let groovesLayer = CAShapeLayer()
        let groovesPath = CGMutablePath()
        for factor in [0.86, 0.74, 0.62, 0.50] as [CGFloat] {
            let r = discRadius * factor
            groovesPath.addEllipse(in: CGRect(x: discRadius - r, y: discRadius - r, width: r * 2, height: r * 2))
        }
        groovesLayer.path = groovesPath
        groovesLayer.fillColor = nil
        groovesLayer.strokeColor = NSColor.white.withAlphaComponent(0.08).cgColor
        groovesLayer.lineWidth = 1.0
        discContainer.addSublayer(groovesLayer)

        let labelRadius = discRadius * 0.38
        let labelLayer = CALayer()
        labelLayer.frame = CGRect(
            x: discRadius - labelRadius,
            y: discRadius - labelRadius,
            width: labelRadius * 2,
            height: labelRadius * 2
        )
        labelLayer.cornerRadius = labelRadius
        labelLayer.masksToBounds = true
        labelLayer.borderWidth = 2
        labelLayer.borderColor = key.palette.accent.withAlphaComponent(0.55).cgColor
        if let cgArt = artwork?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            labelLayer.contents = cgArt
            labelLayer.contentsGravity = .resizeAspectFill
        } else {
            labelLayer.backgroundColor = key.palette.orbPrimary.cgColor
        }
        discContainer.addSublayer(labelLayer)

        let holeRadius: CGFloat = 5
        let holeLayer = CALayer()
        holeLayer.frame = CGRect(x: discRadius - holeRadius, y: discRadius - holeRadius, width: holeRadius * 2, height: holeRadius * 2)
        holeLayer.cornerRadius = holeRadius
        holeLayer.backgroundColor = key.palette.backgroundBottom.cgColor
        discContainer.addSublayer(holeLayer)

        contentLayer.addSublayer(discContainer)

        if isPlaying {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -Double.pi * 2
            spin.duration = 9.0
            spin.repeatCount = .infinity
            discContainer.add(spin, forKey: Self.vinylSpinKey)
        }

        let span = max(0.3, interlude.end - interlude.start)
        let third = span / 3
        let remaining = max(0.05, interlude.end - nowTime)
        let dotSpacing: CGFloat = 24
        let dotSize: CGFloat = 11
        let dotsY = discCenter.y - discRadius - 34

        for i in 0..<3 {
            let dotStart = interlude.start + Double(i) * third
            let dotEnd = dotStart + third
            let progress = min(1, max(0, (nowTime - dotStart) / max(0.05, third)))

            let dotLayer = CALayer()
            dotLayer.bounds = CGRect(x: 0, y: 0, width: dotSize, height: dotSize)
            dotLayer.position = CGPoint(x: w / 2 + CGFloat(i - 1) * dotSpacing, y: dotsY)
            dotLayer.cornerRadius = dotSize / 2
            dotLayer.backgroundColor = key.palette.accent.cgColor
            dotLayer.shadowColor = key.palette.accent.cgColor
            dotLayer.shadowRadius = 8
            dotLayer.shadowOpacity = 0.8
            dotLayer.opacity = isPlaying ? 0.95 : Float(0.24 + 0.72 * progress)
            contentLayer.addSublayer(dotLayer)

            if isPlaying, dotEnd > nowTime {
                var pts: [(TimeInterval, Float)] = [(nowTime, Float(0.24 + 0.72 * progress))]
                if dotStart > nowTime { pts.append((dotStart, 0.24)) }
                pts.append((dotEnd, 0.96))
                if interlude.end > dotEnd { pts.append((interlude.end, 0.96)) }

                let opAnim = CAKeyframeAnimation(keyPath: "opacity")
                opAnim.keyTimes = pts.map { NSNumber(value: min(1, max(0, ($0.0 - nowTime) / remaining))) }
                opAnim.values = pts.map { NSNumber(value: $0.1) }
                opAnim.duration = remaining
                dotLayer.add(opAnim, forKey: Self.stageAnimKey)
            }
        }
    }

    // MARK: - Footer (Translation / Next Line Preview)

    private func buildFooter(key: RenderKey) {
        guard let sub = key.subline, !sub.isEmpty else { return }
        let w = key.size.width
        let fontSize = min(20, max(14, round(w * 0.020)))
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let boxSize = CGSize(width: floor(w * 0.84), height: ceil(fontSize * 1.6))
        let image = rasterizeWord(
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
        subLayer.position = CGPoint(x: w / 2, y: 84)
        subLayer.contents = image
        subLayer.contentsScale = key.backingScale
        footerLayer.addSublayer(subLayer)
    }

    // MARK: - CoreText Measurement & Bitmap Rasterization

    private func measureWord(_ text: String, font: NSFont) -> CGSize {
        let attr = NSAttributedString(string: text, attributes: [.font: font])
        let ctLine = CTLineCreateWithAttributedString(attr)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading))
        return CGSize(width: max(4, ceil(width)), height: max(4, ceil(ascent + descent)))
    }

    private func rasterizeWord(
        _ text: String,
        font: NSFont,
        size: CGSize,
        scale: CGFloat,
        color: NSColor,
        glowColor: NSColor,
        glowBlur: CGFloat
    ) -> CGImage? {
        let pixelW = max(1, Int(ceil(size.width * scale)))
        let pixelH = max(1, Int(ceil(size.height * scale)))
        guard let ctx = CGContext(
            data: nil,
            width: pixelW,
            height: pixelH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        ctx.scaleBy(x: scale, y: scale)
        let attr = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
        ])
        let ctLine = CTLineCreateWithAttributedString(attr)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let rawW = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading))
        let textScale = rawW > 0 ? min(1, max(0.5, (size.width - 16) / rawW)) : 1
        let drawW = rawW * textScale
        let originX = floor((size.width - drawW) / 2)
        let baselineY = floor((size.height - (ascent + descent) * textScale) / 2 + descent * textScale)

        ctx.translateBy(x: originX, y: baselineY)
        ctx.scaleBy(x: textScale, y: textScale)
        if glowBlur > 0 {
            ctx.setShadow(offset: .zero, blur: glowBlur, color: glowColor.cgColor)
        }
        ctx.textPosition = .zero
        CTLineDraw(ctLine, ctx)
        return ctx.makeImage()
    }
}
