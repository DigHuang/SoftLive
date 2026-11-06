import AppKit
import QuartzCore

/// Luminous typography layout and four squash-and-stretch entrance physics modes.
struct StageLuminousRenderer {
    private enum EnterMode: Int, CaseIterable {
        case pop3D = 0
        case dropSmash = 1
        case spinVortex = 2
        case elasticWhip = 3
    }

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

    private let size: CGSize
    private let backingScale: CGFloat
    private let palette: StagePalette
    private let sparks: Bool

    init(size: CGSize, backingScale: CGFloat, palette: StagePalette, sparks: Bool) {
        self.size = size
        self.backingScale = backingScale
        self.palette = palette
        self.sparks = sparks
    }

    func render(
        words: [StageWordTimeline.WordUnit],
        lineTime: TimeInterval,
        text: String,
        nowTime: TimeInterval,
        isPlaying: Bool,
        in contentLayer: CALayer
    ) -> Int {
        let w = size.width
        let h = size.height
        let baseFontSize = min(64, max(36, round(w * 0.054)))
        let seed = floor(lineTime * 1000) + Double(text.count * 73)

        var shapes: [LuminousShape] = []
        shapes.reserveCapacity(words.count)
        for (i, word) in words.enumerated() {
            let ws = seed + Double(i) * 17.31
            let r0 = StageWordAnimation.lineRandom(seed: ws, offset: 1)
            let r1 = StageWordAnimation.lineRandom(seed: ws, offset: 2)
            let r2 = StageWordAnimation.lineRandom(seed: ws, offset: 3)
            let r3 = StageWordAnimation.lineRandom(seed: ws, offset: 4)
            let r4 = StageWordAnimation.lineRandom(seed: ws, offset: 5)
            let r5 = StageWordAnimation.lineRandom(seed: ws, offset: 6)

            let isClimax = (i == words.count - 1) || (word.end - word.start >= 0.55)
            let fontScale: CGFloat = isClimax ? (1.24 + r3 * 0.28) : (0.86 + r3 * 0.42)
            let wordFont = NSFont.systemFont(ofSize: round(baseFontSize * fontScale), weight: .black)
            let size = StageTextRenderer.measureWord(word.text, font: wordFont)
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

        let lineBiasX = (StageWordAnimation.lineRandom(seed: seed, offset: 11) - 0.5) * (w * 0.14)
        let lineBiasY = (StageWordAnimation.lineRandom(seed: seed, offset: 12) - 0.5) * (h * 0.14)
        let diagSlope = (StageWordAnimation.lineRandom(seed: seed, offset: 13) - 0.5) * 0.18
        let startY = floor((h - totalH) / 2 + totalH - rowSpacing / 2 + lineBiasY + 20)

        for (ri, rowRange) in rows.enumerated() {
            var rowW: CGFloat = 0
            for idx in rowRange {
                rowW += shapes[idx].width + (idx + 1 < rowRange.upperBound ? shapes[idx].margin : 0)
            }
            let rowStaggerX = (StageWordAnimation.lineRandom(seed: seed + Double(ri) * 29, offset: 14) - 0.5) * (w * 0.16)
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
                    in: contentLayer
                )
                cursorX += s.width + s.margin
            }
        }
        return rows.count
    }

    private func addLuminousWordLayer(
        word: StageWordTimeline.WordUnit,
        wordIndex: Int,
        shape: LuminousShape,
        center: CGPoint,
        isLast: Bool,
        nowTime: TimeInterval,
        remaining: TimeInterval,
        isPlaying: Bool,
        in contentLayer: CALayer
    ) {
        let pad: CGFloat = 26
        let boxSize = CGSize(width: ceil(shape.width + pad * 2), height: ceil(shape.height + pad * 2))
        let wordLayer = CALayer()
        wordLayer.bounds = CGRect(origin: .zero, size: boxSize)
        wordLayer.position = center

        let fgColor: NSColor = shape.isAccentColored
            ? (palette.accent.blended(withFraction: 0.35, of: .white) ?? .white)
            : .white
        let glowImage = StageTextRenderer.rasterizeWord(
            word.text,
            font: shape.font,
            size: boxSize,
            scale: backingScale,
            color: palette.accent,
            glowColor: palette.accent,
            glowBlur: shape.font.pointSize * 0.36
        )
        let bodyImage = StageTextRenderer.rasterizeWord(
            word.text,
            font: shape.font,
            size: boxSize,
            scale: backingScale,
            color: fgColor,
            glowColor: shape.isAccentColored ? palette.accent : NSColor.black.withAlphaComponent(0.65),
            glowBlur: shape.isAccentColored ? 12 : 7
        )

        let glowLayer = CALayer()
        glowLayer.frame = wordLayer.bounds
        glowLayer.contents = glowImage
        glowLayer.contentsScale = backingScale

        let bodyLayer = CALayer()
        bodyLayer.frame = wordLayer.bounds
        bodyLayer.contents = bodyImage
        bodyLayer.contentsScale = backingScale

        wordLayer.addSublayer(glowLayer)
        wordLayer.addSublayer(bodyLayer)
        contentLayer.addSublayer(wordLayer)

        let ws = floor(word.start * 1000) + Double(wordIndex * 53)
        let dirSign: CGFloat = StageWordAnimation.lineRandom(seed: ws, offset: 21) < 0.5 ? -1 : 1
        let settledRot = shape.rotateDeg * .pi / 180

        let stateAt = { (t: TimeInterval) -> StageWordAnimation.Pose in
            let lookahead = 0.09
            let start = word.start - lookahead
            let end = max(word.end, word.start + 0.22)
            let since = t - start
            let after = t - end
            let enterSpan = 0.46

            if since <= 0 {
                switch shape.mode {
                case .pop3D:
                    return StageWordAnimation.Pose(
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
                    return StageWordAnimation.Pose(
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
                    return StageWordAnimation.Pose(
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
                    return StageWordAnimation.Pose(
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
                let sp = StageWordAnimation.springValue(at: since)
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

            return StageWordAnimation.Pose(pos: pos, scaleX: sx, scaleY: sy, rotZ: rz, rotX: rx, rotY: ry, opacity: op, glow: gl)
        }

        StageWordAnimation.applyWordPoseTimeline(
            wordLayer: wordLayer,
            glowLayer: glowLayer,
            word: word,
            nowTime: nowTime,
            remaining: remaining,
            isPlaying: isPlaying,
            stateAt: stateAt
        )

        if sparks {
            let wordSize = CGSize(width: shape.width, height: shape.height)
            StageEffects.addSparksIfNeeded(
                in: contentLayer,
                center: center,
                wordSize: wordSize,
                word: word,
                isLast: isLast,
                nowTime: nowTime,
                remaining: remaining,
                isPlaying: isPlaying,
                accent: palette.accent
            )
            if isLast || shape.isAccentColored {
                StageEffects.addCrossStarburst(
                    in: contentLayer,
                    center: center,
                    wordSize: wordSize,
                    word: word,
                    isLast: isLast,
                    nowTime: nowTime,
                    remaining: remaining,
                    isPlaying: isPlaying,
                    accent: palette.accent
                )
            }
            if isLast || wordIndex.isMultiple(of: 2) {
                StageEffects.addShockwaveRing(
                    in: contentLayer,
                    center: center,
                    wordSize: wordSize,
                    word: word,
                    isLast: isLast,
                    nowTime: nowTime,
                    remaining: remaining,
                    isPlaying: isPlaying,
                    accent: palette.accent
                )
            }
        }
    }

    private static func easeOutBack(_ t: Double, overshoot: Double = 2.2) -> CGFloat {
        let q = min(1, max(0, t)) - 1
        return CGFloat(1 + (overshoot + 1) * q * q * q + overshoot * q * q)
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
}
