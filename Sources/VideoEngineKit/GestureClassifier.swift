import CoreGraphics
import Vision

/// Pure, queue-agnostic classifiers for the hand shapes gesture GO can wait
/// on (D11 open palm; D15 adds fist, thumbs up, hands together — see
/// `HandGesture`). Takes the per-hand joint dictionary `CameraFrameProcessor`
/// already extracts from a `VNHumanHandPoseObservation` and answers pure
/// yes/no questions with no Vision/AVFoundation runtime state, so it's
/// directly unit-testable.
enum GestureClassifier {
    /// One tracked joint: its normalized (0…1, bottom-left origin) location
    /// and Vision's confidence for it.
    struct JointPoint: Sendable {
        let location: CGPoint
        let confidence: Float
    }

    typealias HandJoints = [VNHumanHandPoseObservation.JointName: JointPoint]

    /// Every joint any classifier reads. `CameraFrameProcessor` only needs
    /// to extract these — anything Vision failed to detect (absent from the
    /// input dictionary) makes the relevant classifier fail closed.
    static let requiredJoints: [VNHumanHandPoseObservation.JointName] = [
        .wrist,
        .indexMCP, .indexPIP, .indexTip,
        .middleMCP, .middlePIP, .middleTip,
        .ringMCP, .ringPIP, .ringTip,
        .littleMCP, .littlePIP, .littleTip,
        .thumbIP, .thumbTip
    ]

    /// Minimum Vision confidence a joint must clear before it's trusted at all.
    private static let minConfidence: Float = 0.3
    /// A finger counts "extended" when its tip sits at least this much
    /// farther from the wrist than its PIP joint. A simple distance ratio
    /// rather than a bone-angle computation — robust to hand rotation/scale
    /// and cheap enough to run every frame.
    private static let extensionRatio: Double = 1.15
    /// A finger counts "folded" (fist) when its tip sits at least this much
    /// CLOSER to the wrist than its PIP joint — the inverse comparison of
    /// `extensionRatio`, with its own (looser) margin so a finger that's
    /// merely relaxed (neither clearly extended nor clearly folded) reads as
    /// neither open palm nor fist rather than flipping between them on noise.
    private static let foldRatio: Double = 0.95
    /// Thumb "extended" for thumbs-up: the tip sits farther from the wrist
    /// than the thumb's own IP joint does. Deliberately measured from the
    /// WRIST (not the index MCP, like open palm's thumb check) and ignores
    /// every other joint's orientation — a sideways or rotated thumbs-up
    /// still counts, on purpose; this gesture only cares that the thumb is
    /// sticking out while the rest of the hand is folded.
    private static let thumbUpRatio: Double = 1.15
    /// Two palm centers count as "together" when closer than this multiple
    /// of the larger hand's own size (wrist → middle MCP distance).
    private static let handsTogetherRatio: Double = 1.2

    /// True when index/middle/ring/little are all extended and the thumb is
    /// splayed out — the open-palm shape gesture GO looks for. Any required
    /// joint that's missing (undetected by Vision) or below `minConfidence`
    /// fails the whole hand closed.
    static func isOpenPalm(joints: HandJoints) -> Bool {
        guard let wrist = point(.wrist, in: joints) else { return false }

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

    /// True when index/middle/ring/little are all folded back toward the
    /// wrist — closer to it than their own PIP joints. The thumb is ignored
    /// (a thumb tucked over folded fingers and one sticking straight up are
    /// both still "a fist" as far as the four fingers are concerned — the
    /// thumb's position is what tells fist and thumbs-up apart, see
    /// `isThumbsUp`).
    static func isFist(joints: HandJoints) -> Bool {
        guard let wrist = point(.wrist, in: joints) else { return false }
        for (tipName, pipName) in fingers {
            guard let tip = point(tipName, in: joints), let pip = point(pipName, in: joints) else { return false }
            guard distance(wrist, tip) < distance(wrist, pip) * foldRatio else { return false }
        }
        return true
    }

    /// True when the four fingers are folded (the fist criterion) AND the
    /// thumb sticks out from the wrist. Orientation-independent on purpose —
    /// a thumbs-up rotated sideways still counts, since the check only
    /// compares distances-from-wrist, never a direction.
    static func isThumbsUp(joints: HandJoints) -> Bool {
        guard isFist(joints: joints) else { return false }
        guard let wrist = point(.wrist, in: joints),
              let thumbTip = point(.thumbTip, in: joints),
              let thumbIP = point(.thumbIP, in: joints) else { return false }
        return distance(wrist, thumbTip) > distance(wrist, thumbIP) * thumbUpRatio
    }

    /// True when two hands' palm centers (the mean of their four MCP joints)
    /// sit closer together than `handsTogetherRatio` times the larger hand's
    /// own size (wrist → middle MCP distance) — scale-relative so it reads
    /// the same whether the performer is close to or far from the camera.
    static func isHandsTogether(_ first: HandJoints, _ second: HandJoints) -> Bool {
        guard let center1 = palmCenter(first), let center2 = palmCenter(second),
              let size1 = handSize(first), let size2 = handSize(second) else { return false }
        let size = max(size1, size2)
        guard size > 0 else { return false }
        return distance(center1, center2) < size * handsTogetherRatio
    }

    /// Classifies every gesture visible in one frame across up to two hands.
    /// Per hand: thumbs-up SUPPRESSES fist (a folded-fingers-plus-raised-
    /// thumb hand reports only `.thumbsUp`, never both); open palm is
    /// independent and can coexist with either. `.handsTogether` is checked
    /// once across the pair (when exactly two hands are present) and can
    /// coexist with anything else already detected.
    static func classify(hands: [HandJoints]) -> Set<HandGesture> {
        var detected: Set<HandGesture> = []
        for hand in hands {
            if isThumbsUp(joints: hand) {
                detected.insert(.thumbsUp)
            } else if isFist(joints: hand) {
                detected.insert(.fist)
            }
            if isOpenPalm(joints: hand) {
                detected.insert(.openPalm)
            }
        }
        if hands.count >= 2, isHandsTogether(hands[0], hands[1]) {
            detected.insert(.handsTogether)
        }
        return detected
    }

    private static let fingers: [(tip: VNHumanHandPoseObservation.JointName, pip: VNHumanHandPoseObservation.JointName)] = [
        (.indexTip, .indexPIP),
        (.middleTip, .middlePIP),
        (.ringTip, .ringPIP),
        (.littleTip, .littlePIP)
    ]

    private static func palmCenter(_ joints: HandJoints) -> CGPoint? {
        guard let index = point(.indexMCP, in: joints), let middle = point(.middleMCP, in: joints),
              let ring = point(.ringMCP, in: joints), let little = point(.littleMCP, in: joints) else { return nil }
        return CGPoint(
            x: (index.x + middle.x + ring.x + little.x) / 4,
            y: (index.y + middle.y + ring.y + little.y) / 4
        )
    }

    private static func handSize(_ joints: HandJoints) -> Double? {
        guard let wrist = point(.wrist, in: joints), let middleMCP = point(.middleMCP, in: joints) else { return nil }
        return distance(wrist, middleMCP)
    }

    private static func point(_ name: VNHumanHandPoseObservation.JointName, in joints: HandJoints) -> CGPoint? {
        guard let joint = joints[name], joint.confidence > minConfidence else { return nil }
        return joint.location
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        Double(hypot(a.x - b.x, a.y - b.y))
    }
}

/// Debounced hold-to-fire state machine for gesture GO: requires the
/// CONFIGURED gesture to be seen continuously for `holdDuration`, tolerating
/// brief Vision flicker (gaps ≤ `flickerTolerance`), then enters
/// `cooldownDuration` during which nothing fires. Time is injected (no
/// `Date()`/`Timer` inside) so it's directly unit-testable; the caller feeds
/// it one sample per frame with a monotonic timestamp (sample-buffer PTS, in
/// seconds).
///
/// Cooldown semantics: firing always clears the hold accumulator, so the
/// frame that ends the cooldown starts counting from zero — a gesture held
/// continuously through the whole cooldown does NOT fire the instant
/// cooldown ends; it needs a fresh full `holdDuration`, exactly like a
/// gesture that left and came back.
struct GestureHoldDetector {
    private static let holdDuration: TimeInterval = 1.0
    private static let flickerTolerance: TimeInterval = 0.2
    private static let cooldownDuration: TimeInterval = 3.0

    /// D15: everything one `update` call reports — whether this frame
    /// completed a hold (fire GO once), plus enough state for the stage
    /// display's pre-warm timer: the hold's progress toward firing (0…1,
    /// 0 while idle or cooling down) and the remaining cooldown (seconds,
    /// 0 once a new hold may start).
    struct Result: Equatable {
        let fired: Bool
        let holdProgress: Double
        let cooldownRemaining: Double
    }

    /// When the current unbroken hold run began; nil while no gesture is held.
    private var holdStartedAt: TimeInterval?
    /// Timestamp of the most recent frame where the gesture was seen — used
    /// to measure the gap when a frame reports the gesture missing.
    private var lastSeenAt: TimeInterval?
    /// Non-nil while cooling down; nothing can fire before this time.
    private var cooldownUntil: TimeInterval?

    init() {}

    /// Feed one frame's observation. `fired` is true exactly on the frame
    /// that completes a hold — fire GO once — and starts the cooldown.
    mutating func update(gestureSeen: Bool, at time: TimeInterval) -> Result {
        if let cooldownUntil {
            if time < cooldownUntil {
                return Result(fired: false, holdProgress: 0, cooldownRemaining: cooldownUntil - time)
            }
            self.cooldownUntil = nil   // cooldown just elapsed
        }

        if gestureSeen {
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

        guard gestureSeen, let holdStartedAt else {
            return Result(fired: false, holdProgress: 0, cooldownRemaining: 0)
        }
        let elapsed = time - holdStartedAt
        guard elapsed >= Self.holdDuration else {
            return Result(fired: false, holdProgress: min(max(elapsed / Self.holdDuration, 0), 1), cooldownRemaining: 0)
        }
        self.holdStartedAt = nil
        self.lastSeenAt = nil
        self.cooldownUntil = time + Self.cooldownDuration
        return Result(fired: true, holdProgress: 1, cooldownRemaining: 0)
    }
}
