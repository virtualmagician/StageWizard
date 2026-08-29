import CoreGraphics
import Vision

/// Pure, queue-agnostic classifier for the "open palm" shape that drives
/// gesture GO (D11 — experimental). Takes the per-hand joint dictionary
/// `CameraFrameProcessor` already extracts from a
/// `VNHumanHandPoseObservation` and answers a single yes/no question with no
/// Vision/AVFoundation runtime state, so it's directly unit-testable.
enum OpenPalmClassifier {
    /// One tracked joint: its normalized (0…1, bottom-left origin) location
    /// and Vision's confidence for it.
    struct JointPoint: Sendable {
        let location: CGPoint
        let confidence: Float
    }

    typealias HandJoints = [VNHumanHandPoseObservation.JointName: JointPoint]

    /// Every joint the classifier reads. `CameraFrameProcessor` only needs to
    /// extract these — anything Vision failed to detect (absent from the
    /// input dictionary) makes the hand read as closed.
    static let requiredJoints: [VNHumanHandPoseObservation.JointName] = [
        .wrist,
        .indexMCP, .indexPIP, .indexTip,
        .middlePIP, .middleTip,
        .ringPIP, .ringTip,
        .littlePIP, .littleTip,
        .thumbIP, .thumbTip
    ]

    /// Minimum Vision confidence a joint must clear before it's trusted at all.
    private static let minConfidence: Float = 0.3
    /// A finger counts "extended" when its tip sits at least this much
    /// farther from the wrist than its PIP joint. A simple distance ratio
    /// rather than a bone-angle computation — robust to hand rotation/scale
    /// and cheap enough to run every frame.
    private static let extensionRatio: Double = 1.15

    /// True when index/middle/ring/little are all extended and the thumb is
    /// splayed out — the open-palm shape gesture GO looks for. Any required
    /// joint that's missing (undetected by Vision) or below `minConfidence`
    /// fails the whole hand closed.
    static func isOpenPalm(joints: HandJoints) -> Bool {
        guard let wrist = point(.wrist, in: joints) else { return false }

        let fingers: [(tip: VNHumanHandPoseObservation.JointName, pip: VNHumanHandPoseObservation.JointName)] = [
            (.indexTip, .indexPIP),
            (.middleTip, .middlePIP),
            (.ringTip, .ringPIP),
            (.littleTip, .littlePIP)
        ]
        for (tipName, pipName) in fingers {
            guard let tip = point(tipName, in: joints), let pip = point(pipName, in: joints) else { return false }
            guard distance(wrist, tip) > distance(wrist, pip) * extensionRatio else { return false }
        }

        // Thumb "out": the tip sits farther from the index MCP than the
        // thumb's own IP joint does — a tucked thumb curls back toward the
        // palm (and the index MCP), an out-splayed one moves away from it.
        guard let indexMCP = point(.indexMCP, in: joints),
              let thumbTip = point(.thumbTip, in: joints),
              let thumbIP = point(.thumbIP, in: joints) else { return false }
        guard distance(indexMCP, thumbTip) > distance(indexMCP, thumbIP) * extensionRatio else { return false }

        return true
    }

    private static func point(_ name: VNHumanHandPoseObservation.JointName, in joints: HandJoints) -> CGPoint? {
        guard let joint = joints[name], joint.confidence > minConfidence else { return nil }
        return joint.location
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        Double(hypot(a.x - b.x, a.y - b.y))
    }
}

/// Debounced hold-to-fire state machine for gesture GO: requires an open
/// palm to be seen continuously for `holdDuration`, tolerating brief Vision
/// flicker (gaps ≤ `flickerTolerance`), then enters `cooldownDuration` during
/// which nothing fires. Time is injected (no `Date()`/`Timer` inside) so
/// it's directly unit-testable; the caller feeds it one sample per frame with
/// a monotonic timestamp (sample-buffer PTS, in seconds).
///
/// Cooldown semantics: firing always clears the hold accumulator, so the
/// frame that ends the cooldown starts counting from zero — a palm held
/// continuously through the whole cooldown does NOT fire the instant cooldown
/// ends; it needs a fresh full `holdDuration`, exactly like a palm that left
/// and came back.
struct GestureHoldDetector {
    private static let holdDuration: TimeInterval = 1.0
    private static let flickerTolerance: TimeInterval = 0.2
    private static let cooldownDuration: TimeInterval = 3.0

    /// When the current unbroken hold run began; nil while no palm is held.
    private var holdStartedAt: TimeInterval?
    /// Timestamp of the most recent frame where the palm was seen — used to
    /// measure the gap when a frame reports the palm missing.
    private var lastSeenAt: TimeInterval?
    /// Non-nil while cooling down; nothing can fire before this time.
    private var cooldownUntil: TimeInterval?

    init() {}

    /// Feed one frame's observation. Returns true exactly on the frame that
    /// completes a hold — fire GO once — and starts the cooldown.
    mutating func update(openPalmSeen: Bool, at time: TimeInterval) -> Bool {
        if let cooldownUntil {
            guard time >= cooldownUntil else { return false }
            self.cooldownUntil = nil   // cooldown just elapsed
        }

        if openPalmSeen {
            if let lastSeenAt, time - lastSeenAt > Self.flickerTolerance {
                holdStartedAt = time   // gap exceeded the flicker tolerance — restart
            } else if holdStartedAt == nil {
                holdStartedAt = time
            }
            lastSeenAt = time
        } else if let lastSeenAt, time - lastSeenAt > Self.flickerTolerance {
            // Gone longer than a flicker — the hold is over.
            holdStartedAt = nil
            self.lastSeenAt = nil
        }

        guard openPalmSeen, let holdStartedAt, time - holdStartedAt >= Self.holdDuration else { return false }
        self.holdStartedAt = nil
        self.lastSeenAt = nil
        self.cooldownUntil = time + Self.cooldownDuration
        return true
    }
}
