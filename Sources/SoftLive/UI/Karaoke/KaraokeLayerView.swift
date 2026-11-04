import AppKit
import CoreText
import QuartzCore

/// Renders one lyric line and its word-by-word fill without per-frame work in the app.
///
/// Each line is typeset with CoreText and rasterized once; a sung copy and a dimmed copy of that bitmap
/// are clipped by two layers whose split point follows a single `CAKeyframeAnimation` per line, which the
/// render server interpolates. The animation is rebuilt only when the line or the playback anchor changes.
final class KaraokeLayerView: NSView {
    private struct WordRange: Equatable {
        let startX: CGFloat
        let endX: CGFloat
    }

    private struct RenderKey: Equatable {
        let text: String
        let wordTexts: [String]
        let size: CGSize
        let backingScale: CGFloat
        let fontSize: CGFloat
        let weight: NSFont.Weight
        let color: NSColor
        let centered: Bool
        let hasShadow: Bool
    }

    private static let unsungOpacity: Float = 0.38
    private static let karaokeKey = "karaoke"
    private static let entranceKey = "lineEntrance"

    private let sungClipLayer = CALayer()
    private let sungImageLayer = CALayer()
    private let unsungClipLayer = CALayer()
    private let unsungImageLayer = CALayer()

    private var line = LyricLine(time: 0, text: "")
    private var playback: PlaybackState?
    private var offset: TimeInterval = 0
    private var fontSize: CGFloat = 19
    private var weight: NSFont.Weight = .bold
    private var color: NSColor = .labelColor
    private var centered = false
    private var hasShadow = false

    private var renderedKey: RenderKey?
    private var lastLineTime: TimeInterval?
    private var wordRanges: [WordRange] = []

    static func lineHeight(for fontSize: CGFloat) -> CGFloat {
        ceil(fontSize * 1.35)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.lineHeight(for: fontSize))
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never

        sungClipLayer.anchorPoint = .zero
        sungClipLayer.masksToBounds = true
        sungImageLayer.anchorPoint = .zero
        sungClipLayer.addSublayer(sungImageLayer)

        // Anchor at the right edge (x = 1) so setting bounds = (splitX, 0, W - splitX, H)
        // clips to [splitX, W] while keeping unsungImageLayer fixed at x = 0 in root space.
        unsungClipLayer.anchorPoint = CGPoint(x: 1, y: 0)
        unsungClipLayer.masksToBounds = true
        unsungImageLayer.anchorPoint = .zero
        unsungImageLayer.opacity = Self.unsungOpacity
        unsungClipLayer.addSublayer(unsungImageLayer)

        layer?.addSublayer(sungClipLayer)
        layer?.addSublayer(unsungClipLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(
        line: LyricLine,
        playback: PlaybackState?,
        offset: TimeInterval,
        fontSize: CGFloat,
        weight: NSFont.Weight,
        color: NSColor,
        centered: Bool,
        hasShadow: Bool
    ) {
        let timingChanged = self.playback != playback || self.offset != offset
        self.line = line
        self.playback = playback
        self.offset = offset
        self.fontSize = fontSize
        self.weight = weight
        self.color = color
        self.centered = centered
        self.hasShadow = hasShadow
        refreshIfNeeded(forceSync: timingChanged)
    }

    override func layout() {
        super.layout()
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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshIfNeeded(forceSync: false)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refreshIfNeeded(forceSync: false)
    }

    private func refreshIfNeeded(forceSync: Bool) {
        guard !isHiddenOrHasHiddenAncestor, bounds.width > 1, bounds.height > 1 else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        var resolvedColor = color
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolvedColor = color.usingColorSpace(.deviceRGB) ?? color
        }
        let words = line.words ?? []
        let key = RenderKey(
            text: line.text,
            wordTexts: words.map(\.text),
            size: bounds.size,
            backingScale: scale,
            fontSize: fontSize,
            weight: weight,
            color: resolvedColor,
            centered: centered,
            hasShadow: hasShadow
        )
        let lineChanged = lastLineTime != nil && (lastLineTime != line.time || renderedKey?.text != line.text)
        lastLineTime = line.time

        if key != renderedKey {
            renderedKey = key
            renderLine(key: key)
            syncAnimation()
            if lineChanged { animateEntrance() }
        } else if forceSync || lineChanged {
            syncAnimation()
            if lineChanged { animateEntrance() }
        }
    }

    private func animateEntrance() {
        guard let layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.2
        fade.toValue = 1.0

        let slide = CABasicAnimation(keyPath: "transform.translation.y")
        slide.fromValue = -4.0
        slide.toValue = 0.0

        let group = CAAnimationGroup()
        group.animations = [fade, slide]
        group.duration = 0.22
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(group, forKey: Self.entranceKey)
    }

    private func renderLine(key: RenderKey) {
        guard !key.text.isEmpty else {
            wordRanges = []
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            sungImageLayer.contents = nil
            unsungImageLayer.contents = nil
            CATransaction.commit()
            return
        }

        let font = NSFont.systemFont(ofSize: key.fontSize, weight: key.weight)

        let attrString = NSAttributedString(string: key.text, attributes: [
            .font: font,
            .foregroundColor: key.color
        ])
        let ctLine = CTLineCreateWithAttributedString(attrString)

        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let rawWidth = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading))
        let width = key.size.width
        let height = key.size.height
        let textScale = rawWidth > 0 ? min(1, max(0.5, width / rawWidth)) : 1
        let lineWidth = rawWidth * textScale
        let originX = key.centered ? floor((width - lineWidth) / 2) : 0
        let textHeight = (ascent + descent) * textScale
        let baselineY = floor((height - textHeight) / 2 + descent * textScale)

        let totalUTF16 = key.text.utf16.count
        var cursor = 0
        var ranges: [WordRange] = []
        ranges.reserveCapacity(key.wordTexts.count)
        for (index, wordText) in key.wordTexts.enumerated() {
            let startIdx = min(cursor, totalUTF16)
            let endIdx = min(startIdx + wordText.utf16.count, totalUTF16)
            cursor = endIdx
            let rawStart = originX + CTLineGetOffsetForStringIndex(ctLine, startIdx, nil) * textScale
            let rawEnd = originX + CTLineGetOffsetForStringIndex(ctLine, endIdx, nil) * textScale
            let pad: CGFloat = key.hasShadow ? 4 : 1
            let startX = index == 0 ? max(0, rawStart - pad) : rawStart
            let endX = index == key.wordTexts.count - 1 ? min(width, rawEnd + pad) : rawEnd
            ranges.append(WordRange(startX: startX, endX: max(startX, endX)))
        }
        wordRanges = ranges

        let pixelW = max(1, Int(ceil(width * key.backingScale)))
        let pixelH = max(1, Int(ceil(height * key.backingScale)))

        func rasterize(fillColor: NSColor, tightShadowAlpha: CGFloat, ambientShadowAlpha: CGFloat) -> CGImage? {
            guard let ctx = CGContext(
                data: nil,
                width: pixelW,
                height: pixelH,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return nil }

            ctx.scaleBy(x: key.backingScale, y: key.backingScale)
            ctx.translateBy(x: originX, y: baselineY)
            ctx.scaleBy(x: textScale, y: textScale)

            let drawLine = CTLineCreateWithAttributedString(NSAttributedString(string: key.text, attributes: [
                .font: font,
                .foregroundColor: fillColor
            ]))

            if key.hasShadow {
                // Soft ambient shadow pass for depth.
                ctx.saveGState()
                ctx.setShadow(
                    offset: CGSize(width: 0, height: -2),
                    blur: 8,
                    color: NSColor.black.withAlphaComponent(ambientShadowAlpha).cgColor
                )
                ctx.textPosition = .zero
                CTLineDraw(drawLine, ctx)
                ctx.restoreGState()

                // Crisp contact shadow pass for edge legibility on light backgrounds.
                ctx.saveGState()
                ctx.setShadow(
                    offset: CGSize(width: 0, height: -0.8),
                    blur: 2,
                    color: NSColor.black.withAlphaComponent(tightShadowAlpha).cgColor
                )
                ctx.textPosition = .zero
                CTLineDraw(drawLine, ctx)
                ctx.restoreGState()
            } else {
                ctx.textPosition = .zero
                CTLineDraw(drawLine, ctx)
            }
            return ctx.makeImage()
        }

        let sungImage = rasterize(fillColor: key.color, tightShadowAlpha: 0.62, ambientShadowAlpha: 0.45)
        let unsungImage = key.hasShadow
            ? rasterize(fillColor: NSColor(white: 1.0, alpha: 0.56), tightShadowAlpha: 0.52, ambientShadowAlpha: 0.36)
            : sungImage

        let fullRect = CGRect(origin: .zero, size: key.size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sungClipLayer.position = .zero
        unsungClipLayer.position = CGPoint(x: width, y: 0)
        sungImageLayer.frame = fullRect
        unsungImageLayer.frame = fullRect
        sungImageLayer.contents = sungImage
        unsungImageLayer.contents = unsungImage
        unsungImageLayer.opacity = key.hasShadow ? 1.0 : Self.unsungOpacity
        sungImageLayer.contentsScale = key.backingScale
        unsungImageLayer.contentsScale = key.backingScale
        CATransaction.commit()
    }

    private func syncAnimation() {
        let width = bounds.width
        let height = bounds.height
        guard width > 1, height > 1 else { return }

        sungClipLayer.removeAnimation(forKey: Self.karaokeKey)
        unsungClipLayer.removeAnimation(forKey: Self.karaokeKey)

        guard let words = line.words, !words.isEmpty, words.count == wordRanges.count, let last = words.last else {
            setClipWidth(width)
            return
        }

        let nowTime = (playback?.position(at: .now) ?? 0) + offset
        let currentX = splitX(at: nowTime, words: words)
        guard playback?.isPlaying == true else {
            setClipWidth(currentX)
            return
        }

        let lineEnd = last.start + max(last.duration, 0)
        let remaining = lineEnd - nowTime
        guard remaining > 0.02 else {
            setClipWidth(width)
            return
        }

        var points: [(t: TimeInterval, x: CGFloat)] = [(nowTime, currentX)]
        for (word, range) in zip(words, wordRanges) {
            let start = word.start
            let end = start + max(word.duration, 0)
            if start > nowTime {
                points.append((start, range.startX))
            }
            if end > nowTime {
                points.append((end, range.endX))
            }
        }
        if points.last?.x != width {
            points.append((lineEnd, width))
        }

        let keyTimes = points.map { NSNumber(value: min(max(($0.t - nowTime) / remaining, 0), 1)) }
        let sungValues = points.map { NSValue(rect: CGRect(x: 0, y: 0, width: $0.x, height: height)) }
        let unsungValues = points.map { NSValue(rect: CGRect(x: $0.x, y: 0, width: max(0, width - $0.x), height: height)) }

        // Model state is the finished state so the line stays fully lit after the animation completes.
        setClipWidth(width)

        let sungAnim = CAKeyframeAnimation(keyPath: "bounds")
        sungAnim.values = sungValues
        sungAnim.keyTimes = keyTimes
        sungAnim.duration = remaining
        sungAnim.calculationMode = .linear

        let unsungAnim = CAKeyframeAnimation(keyPath: "bounds")
        unsungAnim.values = unsungValues
        unsungAnim.keyTimes = keyTimes
        unsungAnim.duration = remaining
        unsungAnim.calculationMode = .linear

        sungClipLayer.add(sungAnim, forKey: Self.karaokeKey)
        unsungClipLayer.add(unsungAnim, forKey: Self.karaokeKey)
    }

    private func setClipWidth(_ x: CGFloat) {
        let width = bounds.width
        let height = bounds.height
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sungClipLayer.bounds = CGRect(x: 0, y: 0, width: x, height: height)
        unsungClipLayer.bounds = CGRect(x: x, y: 0, width: max(0, width - x), height: height)
        CATransaction.commit()
    }

    func splitX(at time: TimeInterval, words: [LyricWord]) -> CGFloat {
        let width = bounds.width
        guard let firstWord = words.first, let firstRange = wordRanges.first, let lastWord = words.last else {
            return width
        }
        if time <= firstWord.start { return firstRange.startX }
        let lineEnd = lastWord.start + max(lastWord.duration, 0)
        if time >= lineEnd { return width }

        for index in words.indices {
            let word = words[index]
            let range = wordRanges[index]
            let wordEnd = word.start + max(word.duration, 0)
            if time <= wordEnd {
                let progress = word.progress(at: time)
                return range.startX + (range.endX - range.startX) * progress
            }
            if index + 1 < words.count, time < words[index + 1].start {
                return range.endX
            }
        }
        return width
    }
}
