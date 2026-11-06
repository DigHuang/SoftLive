import AppKit
import QuartzCore

/// Ink-trace typography layout, gold outlines, laser tracing, and solid-fill timelines.
struct StageInkTraceRenderer {
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
        let baseFontSize = min(68, max(40, round(w * 0.058)))
        let seed = floor(lineTime * 1000) + Double(text.count * 41)
        let lineEnd = (words.last?.end ?? (nowTime + 2)) + 0.90
        let remaining = max(0.05, lineEnd - nowTime)

        let champagneGold = NSColor(deviceRed: 1.0, green: 0.84, blue: 0.38, alpha: 1.0)
        let goldAccent = palette.accent.blended(withFraction: 0.55, of: champagneGold) ?? champagneGold
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
            let r0 = StageWordAnimation.lineRandom(seed: ws, offset: 1)
            let r1 = StageWordAnimation.lineRandom(seed: ws, offset: 2)
            let r2 = StageWordAnimation.lineRandom(seed: ws, offset: 3)
            let r3 = StageWordAnimation.lineRandom(seed: ws, offset: 4)
            let isClimax = (i == words.count - 1) || (word.end - word.start >= 0.5) || i == 0
            let fontScale: CGFloat = isClimax ? (1.20 + r3 * 0.30) : (0.90 + r3 * 0.32)
            let font = NSFont.systemFont(ofSize: round(baseFontSize * fontScale), weight: .black)
            let sz = StageTextRenderer.measureWord(word.text, font: font)
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
            let rowStagger = (StageWordAnimation.lineRandom(seed: seed + Double(ri) * 19, offset: 8) - 0.5) * (w * 0.16)
            var cursorX = floor((w - rowW) / 2 + rowStagger)
            let rowY = topY - CGFloat(ri) * rowSpacing

            for idx in rowRange {
                let word = words[idx]
                let item = layouts[idx]
                let isLast = idx == words.count - 1
                let center = CGPoint(x: cursorX + item.size.width / 2 + item.dx, y: rowY + item.dy)
                let pad: CGFloat = 24
                let boxSize = CGSize(width: ceil(item.size.width + pad * 2), height: ceil(item.size.height + pad * 2))
                let glyphCGPath = StageTextRenderer.glyphPath(for: word.text, font: item.font, in: boxSize)

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
                let strokeColor = item.isClimax ? goldAccent : (palette.accent.blended(withFraction: 0.45, of: champagneGold) ?? goldAccent)
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
                interiorMaskLayer.fillColor = palette.backgroundBottom.blended(withFraction: 0.16, of: strokeColor)?.cgColor
                    ?? NSColor(deviceWhite: 0.06, alpha: 0.94).cgColor
                interiorMaskLayer.strokeColor = nil

                // 6. Solid Glowing Character Fill (`solidFillLayer`):
                //    Stays at opacity 0 while the gold laser rapidly traces the hollow outline (`strokeEnd: 0 → 1`),
                //    then flashes into a solid glowing character as soon as the outline closes!
                let solidColor: NSColor = item.isClimax
                    ? (brightCoreGold.blended(withFraction: 0.3, of: .white) ?? .white)
                    : .white
                let solidImage = StageTextRenderer.rasterizeWord(
                    word.text,
                    font: item.font,
                    size: boxSize,
                    scale: backingScale,
                    color: solidColor,
                    glowColor: strokeColor,
                    glowBlur: 12
                )
                let solidFillLayer = CALayer()
                solidFillLayer.frame = wordLayer.bounds
                solidFillLayer.contents = solidImage
                solidFillLayer.contentsScale = backingScale

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
                    goldStrokeLayer.add(strokeGroup, forKey: StageWordAnimation.key)
                    innerGoldLayer.add(strokeGroup, forKey: StageWordAnimation.key)
                    interiorMaskLayer.add(strokeOpAnim, forKey: StageWordAnimation.key)

                    let fillOpAnim = CAKeyframeAnimation(keyPath: "opacity")
                    fillOpAnim.keyTimes = keyTimes
                    fillOpAnim.values = fillOpVals.map { NSNumber(value: $0) }
                    fillOpAnim.duration = remaining
                    solidFillLayer.add(fillOpAnim, forKey: StageWordAnimation.key)

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
                    cometLaserLayer.add(cometGroup, forKey: StageWordAnimation.key)

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
                    wordLayer.add(wordGroup, forKey: StageWordAnimation.key)
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
                        echoOutlineLayer.add(eGroup, forKey: StageWordAnimation.key)
                    }

                    if sparks {
                        StageEffects.addGeometricOrnament(
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
                        StageEffects.addSparksIfNeeded(
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
                        StageEffects.addCrossStarburst(
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
}
