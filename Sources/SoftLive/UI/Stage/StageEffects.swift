import AppKit
import QuartzCore

/// Transient scene and word accents, independent of the view lifecycle and typography style.
enum StageEffects {
    static let cameraPulseKey = "stageCameraPulse"

    static func addOutgoingAfterimage(
        for prevLine: LyricLine,
        in parent: CALayer,
        size: CGSize,
        backingScale: CGFloat,
        accent: NSColor
    ) {
        let w = size.width
        let h = size.height
        let fontSize = min(54, max(30, round(w * 0.044)))
        let font = NSFont.systemFont(ofSize: fontSize, weight: .heavy)
        let boxSize = CGSize(width: floor(w * 0.84), height: ceil(fontSize * 1.8))
        guard let img = StageTextRenderer.rasterizeWord(
            prevLine.text,
            font: font,
            size: boxSize,
            scale: backingScale,
            color: accent.withAlphaComponent(0.36),
            glowColor: accent,
            glowBlur: 18
        ) else { return }

        let ghost = CALayer()
        ghost.bounds = CGRect(origin: .zero, size: boxSize)
        ghost.position = CGPoint(x: w / 2, y: h * 0.54)
        ghost.contents = img
        ghost.contentsScale = backingScale
        ghost.opacity = 0
        parent.addSublayer(ghost)

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

    static func applyCameraBeatPulse(
        in parent: CALayer,
        words: [StageWordTimeline.WordUnit],
        nowTime: TimeInterval,
        lineTime: TimeInterval
    ) {
        guard !words.isEmpty else { return }
        let lineEnd = (words.last?.end ?? (nowTime + 2)) + 0.85
        let remaining = max(0.08, lineEnd - nowTime)
        let seed = floor(lineTime * 1000)

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
                let tiltDir: CGFloat = StageWordAnimation.lineRandom(seed: seed + Double(idx), offset: 31) < 0.5 ? -1 : 1
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
        parent.add(group, forKey: Self.cameraPulseKey)
    }

    /// EVA / Lumiere-style 4-point cross flare (`✦`) that flashes white-hot when a key word lands.
    static func addCrossStarburst(
        in parent: CALayer,
        center: CGPoint,
        wordSize: CGSize,
        word: StageWordTimeline.WordUnit,
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
        crossLayer.add(group, forKey: StageWordAnimation.key)
    }

    /// Expanding concentric shockwave ring (`ringOrnament` from Folia `hanabi`).
    static func addShockwaveRing(
        in parent: CALayer,
        center: CGPoint,
        wordSize: CGSize,
        word: StageWordTimeline.WordUnit,
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
        ringLayer.add(group, forKey: StageWordAnimation.key)
    }

    /// Geometric PV ornaments (`◇` diamond frame, `⌜⌟` corner brackets, or diagonal slash) for `.inkTrace`.
    static func addGeometricOrnament(
        in parent: CALayer,
        center: CGPoint,
        wordSize: CGSize,
        word: StageWordTimeline.WordUnit,
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
        layer.add(group, forKey: StageWordAnimation.key)
    }

    static func addSparksIfNeeded(
        in parent: CALayer,
        center: CGPoint,
        wordSize: CGSize,
        word: StageWordTimeline.WordUnit,
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
            let jitter = Double(StageWordAnimation.lineRandom(seed: seed, offset: Double(i))) * 0.75
            let angle = 2 * .pi * (Double(i) + jitter) / Double(count)
            let dx = CGFloat(cos(angle))
            let dy = CGFloat(sin(angle))
            let inner = max(wordSize.width, wordSize.height) * 0.28
            let outer = inner + reach * (0.50 + 0.65 * StageWordAnimation.lineRandom(seed: seed, offset: Double(i) + 40))
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
        sparkLayer.add(group, forKey: StageWordAnimation.key)
    }
}
