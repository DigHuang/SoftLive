import AppKit
import QuartzCore

/// Vinyl centerpiece and the three progressive interlude dots.
enum StageInterludeRenderer {
    private static let vinylSpinKey = "vinylSpin"

    static func render(
        interlude: Interlude,
        nowTime: TimeInterval,
        isPlaying: Bool,
        in contentLayer: CALayer,
        size: CGSize,
        palette: StagePalette,
        artwork: NSImage?
    ) {
        let w = size.width
        let h = size.height
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
        vinylLayer.strokeColor = palette.accent.withAlphaComponent(0.38).cgColor
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
        labelLayer.borderColor = palette.accent.withAlphaComponent(0.55).cgColor
        if let cgArt = artwork?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            labelLayer.contents = cgArt
            labelLayer.contentsGravity = .resizeAspectFill
        } else {
            labelLayer.backgroundColor = palette.orbPrimary.cgColor
        }
        discContainer.addSublayer(labelLayer)

        let holeRadius: CGFloat = 5
        let holeLayer = CALayer()
        holeLayer.frame = CGRect(x: discRadius - holeRadius, y: discRadius - holeRadius, width: holeRadius * 2, height: holeRadius * 2)
        holeLayer.cornerRadius = holeRadius
        holeLayer.backgroundColor = palette.backgroundBottom.cgColor
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
            dotLayer.backgroundColor = palette.accent.cgColor
            dotLayer.shadowColor = palette.accent.cgColor
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
                dotLayer.add(opAnim, forKey: StageWordAnimation.key)
            }
        }
    }
}
