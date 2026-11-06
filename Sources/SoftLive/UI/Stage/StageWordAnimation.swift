import AppKit
import QuartzCore

/// Deterministic motion primitives and compilation of sampled poses into Core Animation.
enum StageWordAnimation {
    static let key = "stageKinetic"

    struct Pose {
        var pos: CGPoint
        var scaleX: CGFloat
        var scaleY: CGFloat
        var rotZ: CGFloat
        var rotX: CGFloat
        var rotY: CGFloat
        var opacity: Float
        var glow: Float
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

    static func applyWordPoseTimeline(
        wordLayer: CALayer,
        glowLayer: CALayer,
        word: StageWordTimeline.WordUnit,
        nowTime: TimeInterval,
        remaining: TimeInterval,
        isPlaying: Bool,
        stateAt: (TimeInterval) -> Pose
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
        wordLayer.add(group, forKey: Self.key)

        let glowAnim = CAKeyframeAnimation(keyPath: "opacity")
        glowAnim.keyTimes = keyTimes
        glowAnim.values = states.map { NSNumber(value: $0.glow) }
        glowAnim.duration = remaining
        glowLayer.add(glowAnim, forKey: Self.key)
    }

    private static func makeTransform(_ pose: Pose) -> CATransform3D {
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
}
