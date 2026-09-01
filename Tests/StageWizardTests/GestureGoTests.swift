import XCTest
import Vision
@testable import StageWizard

/// D11/D15 gesture GO (experimental): `CameraEffects.gestureGo`/`goGesture`
/// model coverage, the pure `GestureClassifier` shape tests (open palm,
/// fist, thumbs up, hands together, and their precedence), and the pure
/// `GestureHoldDetector` hold/flicker/cooldown/readout state machine. No
/// live capture sessions or Vision requests here — everything under test
/// takes plain values and is deterministic; see VideoEngineTests for camera
/// pipeline integration coverage.
///
/// Timing note: every time-walking loop below advances in EXACT steps of
/// 0.125 s (1/8, exactly representable in binary floating point) from an
/// exact base, so accumulated `Double` rounding can never nudge a sample
/// across a `>=` threshold the test didn't intend to cross.
final class GestureGoTests: XCTestCase {

    // MARK: - CameraEffects: defaults for older files

    func testGestureGoDefaultsOffForOlderFiles() throws {
        // Pre-D11 files predate gesture GO entirely — bare `{}`.
        let old = try JSONDecoder().decode(CameraEffects.self, from: Data("{}".utf8))
        XCTAssertFalse(old.gestureGo)
        XCTAssertEqual(old.goGesture, .openPalm)
    }

    func testGestureGoStripKeyDefaultsMatchOlderFiles() throws {
        // A CameraEffects payload with the new key stripped out (simulating
        // a file saved before D11 that still has other effect fields set).
        let effects = CameraEffects(magicDust: true, chromaKey: true)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(effects)) as! [String: Any]
        json.removeValue(forKey: "gestureGo")
        let decoded = try JSONDecoder().decode(
            CameraEffects.self, from: try JSONSerialization.data(withJSONObject: json)
        )
        XCTAssertFalse(decoded.gestureGo)
        // Untouched sibling fields still round-trip.
        XCTAssertTrue(decoded.magicDust)
        XCTAssertTrue(decoded.chromaKey)
    }

    func testGestureGoRoundTrip() throws {
        let effects = CameraEffects(gestureGo: true)
        let decoded = try JSONDecoder().decode(CameraEffects.self, from: JSONEncoder().encode(effects))
        XCTAssertEqual(decoded, effects)
        XCTAssertTrue(decoded.gestureGo)
    }

    // MARK: - D15: goGesture — defaults for older files, strip-key, round-trip

    func testGoGestureDefaultsOpenPalmForOlderFiles() throws {
        // Pre-D15 files predate the gesture picker entirely — bare `{}`.
        let old = try JSONDecoder().decode(CameraEffects.self, from: Data("{}".utf8))
        XCTAssertEqual(old.goGesture, .openPalm)
    }

    func testGoGestureStripKeyDefaultsToOpenPalmMatchingD11Behavior() throws {
        // A D11-era file: gestureGo:true, but no goGesture key at all — D11
        // only ever recognized an open palm, so that must be exactly what
        // this decodes to (unchanged GO behavior for every existing show).
        let effects = CameraEffects(gestureGo: true, goGesture: .thumbsUp)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(effects)) as! [String: Any]
        json.removeValue(forKey: "goGesture")
        let decoded = try JSONDecoder().decode(
            CameraEffects.self, from: try JSONSerialization.data(withJSONObject: json)
        )
        XCTAssertTrue(decoded.gestureGo)
        XCTAssertEqual(decoded.goGesture, .openPalm)
    }

    func testGoGestureRoundTrip() throws {
        for gesture in HandGesture.allCases {
            let effects = CameraEffects(gestureGo: true, goGesture: gesture)
            let decoded = try JSONDecoder().decode(CameraEffects.self, from: JSONEncoder().encode(effects))
            XCTAssertEqual(decoded, effects)
            XCTAssertEqual(decoded.goGesture, gesture)
        }
    }

    // MARK: - D25: gestureHoldSeconds — defaults for older files, clamp, strip-key, round-trip

    func testGestureHoldSecondsDefaultsToOneSecondForOlderFiles() throws {
        // Pre-D25 files predate the selectable warm-up time entirely — bare `{}`.
        let old = try JSONDecoder().decode(CameraEffects.self, from: Data("{}".utf8))
        XCTAssertEqual(old.gestureHoldSeconds, 1.0)
    }

    func testGestureHoldSecondsStripKeyDefaultsToOneSecondMatchingPreD25Behavior() throws {
        // A pre-D25 file: gestureGo:true, but no gestureHoldSeconds key at
        // all — every file before D25 used a fixed 1 s hold, so that must be
        // exactly what this decodes to (unchanged GO timing for every show).
        let effects = CameraEffects(gestureGo: true, gestureHoldSeconds: 3.5)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(effects)) as! [String: Any]
        json.removeValue(forKey: "gestureHoldSeconds")
        let decoded = try JSONDecoder().decode(
            CameraEffects.self, from: try JSONSerialization.data(withJSONObject: json)
        )
        XCTAssertTrue(decoded.gestureGo)
        XCTAssertEqual(decoded.gestureHoldSeconds, 1.0)
    }

    func testGestureHoldSecondsClampsToValidRangeOnInit() {
        XCTAssertEqual(CameraEffects(gestureHoldSeconds: 0).gestureHoldSeconds, 0.25)
        XCTAssertEqual(CameraEffects(gestureHoldSeconds: 0.1).gestureHoldSeconds, 0.25)
        XCTAssertEqual(CameraEffects(gestureHoldSeconds: 5).gestureHoldSeconds, 5)
        XCTAssertEqual(CameraEffects(gestureHoldSeconds: 99).gestureHoldSeconds, 5)
        XCTAssertEqual(CameraEffects(gestureHoldSeconds: 2.5).gestureHoldSeconds, 2.5)
    }

    func testGestureHoldSecondsClampsOnDecodeToo() throws {
        // A hand-edited (or future-app-written) file with an out-of-range
        // value must still clamp on the way in, exactly like every other
        // clamped field in this struct.
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(CameraEffects())) as! [String: Any]
        json["gestureHoldSeconds"] = 42.0
        let decoded = try JSONDecoder().decode(
            CameraEffects.self, from: try JSONSerialization.data(withJSONObject: json)
        )
        XCTAssertEqual(decoded.gestureHoldSeconds, 5)
    }

    func testGestureHoldSecondsRoundTrip() throws {
        let effects = CameraEffects(gestureGo: true, gestureHoldSeconds: 2.25)
        let decoded = try JSONDecoder().decode(CameraEffects.self, from: JSONEncoder().encode(effects))
        XCTAssertEqual(decoded, effects)
        XCTAssertEqual(decoded.gestureHoldSeconds, 2.25)
    }

    // MARK: - HandGesture: display metadata

    func testHandGestureHasFourCases() {
        XCTAssertEqual(HandGesture.allCases.count, 4)
        XCTAssertEqual(Set(HandGesture.allCases), [.openPalm, .fist, .thumbsUp, .handsTogether])
    }

    func testHandGestureLabelsAreNonEmptyAndDistinct() {
        let labels = HandGesture.allCases.map(\.label)
        XCTAssertEqual(Set(labels).count, labels.count, "every gesture has its own label")
        XCTAssertTrue(labels.allSatisfy { !$0.isEmpty })
    }

    func testHandGestureSymbolNamesAreNonEmptyAndDistinct() {
        let symbols = HandGesture.allCases.map(\.symbolName)
        XCTAssertEqual(Set(symbols).count, symbols.count, "every gesture has its own SF Symbol")
        XCTAssertTrue(symbols.allSatisfy { !$0.isEmpty })
    }

    // MARK: - anyEnabled

    func testAnyEnabledIncludesGestureGo() {
        // gestureGo REQUIRES the hand-pose path (the processed capture path,
        // same as segmentation/magicDust/chromaKey), so it must count toward
        // anyEnabled even when every other effect is off.
        XCTAssertTrue(CameraEffects(gestureGo: true).anyEnabled)
        XCTAssertFalse(CameraEffects().anyEnabled)
        XCTAssertFalse(CameraEffects(gestureGo: false).anyEnabled)
    }

    // MARK: - GestureClassifier: synthetic joint sets

    /// A plausible "hand pointing straight up, fingers spread" joint set —
    /// every finger's TIP well past its PIP (measured from the wrist) and
    /// the thumb splayed out from the index MCP. Normalized (0…1) Vision
    /// coordinates, bottom-left origin.
    private static func openPalmJoints(confidence: Float = 0.9) -> GestureClassifier.HandJoints {
        func j(_ x: Double, _ y: Double) -> GestureClassifier.JointPoint {
            GestureClassifier.JointPoint(location: CGPoint(x: x, y: y), confidence: confidence)
        }
        return [
            .wrist: j(0.50, 0.10),
            .indexMCP: j(0.45, 0.35), .indexPIP: j(0.45, 0.55), .indexTip: j(0.45, 0.75),
            .middlePIP: j(0.50, 0.60), .middleTip: j(0.50, 0.80),
            .ringPIP: j(0.55, 0.55), .ringTip: j(0.55, 0.75),
            .littlePIP: j(0.60, 0.50), .littleTip: j(0.60, 0.68),
            .thumbIP: j(0.35, 0.30), .thumbTip: j(0.25, 0.25)
        ]
    }

    /// Same wrist/thumb-base as the open palm, but every fingertip folded
    /// back toward the wrist — closer to it than its own PIP joint — and
    /// the thumb tucked in near the index MCP (and close to the wrist too,
    /// so it also fails the D15 thumbs-up "thumb extended from wrist" check).
    private static func fistJoints(confidence: Float = 0.9) -> GestureClassifier.HandJoints {
        func j(_ x: Double, _ y: Double) -> GestureClassifier.JointPoint {
            GestureClassifier.JointPoint(location: CGPoint(x: x, y: y), confidence: confidence)
        }
        return [
            .wrist: j(0.50, 0.10),
            .indexMCP: j(0.45, 0.35), .indexPIP: j(0.45, 0.35), .indexTip: j(0.47, 0.28),
            .middlePIP: j(0.50, 0.35), .middleTip: j(0.49, 0.27),
            .ringPIP: j(0.55, 0.35), .ringTip: j(0.53, 0.27),
            .littlePIP: j(0.60, 0.33), .littleTip: j(0.58, 0.26),
            .thumbIP: j(0.35, 0.30), .thumbTip: j(0.42, 0.33)   // tucked, near indexMCP AND the wrist
        ]
    }

    /// A fist with the thumb stuck straight OUT from the wrist instead of
    /// tucked — the thumbs-up shape. Fingers unchanged from `fistJoints`.
    private static func thumbsUpJoints(confidence: Float = 0.9) -> GestureClassifier.HandJoints {
        var joints = fistJoints(confidence: confidence)
        // distance(wrist, thumbIP) == 0.25; this puts thumbTip at ~0.354 —
        // comfortably past the 1.15× threshold (0.2875).
        joints[.thumbTip] = GestureClassifier.JointPoint(location: CGPoint(x: 0.15, y: 0.05), confidence: confidence)
        return joints
    }

    /// A small synthetic hand — wrist plus the four MCP joints handsTogether
    /// needs — centered at `(wristX, wristY)`, with a wrist→middleMCP "hand
    /// size" of 0.10.
    private static func palmJoints(wristX: Double, wristY: Double, confidence: Float = 0.9) -> GestureClassifier.HandJoints {
        func j(_ x: Double, _ y: Double) -> GestureClassifier.JointPoint {
            GestureClassifier.JointPoint(location: CGPoint(x: x, y: y), confidence: confidence)
        }
        return [
            .wrist: j(wristX, wristY),
            .indexMCP: j(wristX - 0.03, wristY + 0.09),
            .middleMCP: j(wristX, wristY + 0.10),
            .ringMCP: j(wristX + 0.03, wristY + 0.09),
            .littleMCP: j(wristX + 0.06, wristY + 0.08)
        ]
    }

    func testOpenPalmJointsClassifyAsOpenPalm() {
        XCTAssertTrue(GestureClassifier.isOpenPalm(joints: Self.openPalmJoints()))
    }

    func testFistJointsDoNotClassifyAsOpenPalm() {
        XCTAssertFalse(GestureClassifier.isOpenPalm(joints: Self.fistJoints()))
    }

    func testMissingJointFailsClosed() {
        var joints = Self.openPalmJoints()
        joints.removeValue(forKey: .littleTip)
        XCTAssertFalse(GestureClassifier.isOpenPalm(joints: joints))
    }

    func testLowConfidenceJointFailsClosed() {
        var joints = Self.openPalmJoints()
        // Vision detected a point there, but with confidence below the 0.3
        // floor — must be treated the same as "not detected".
        joints[.middleTip] = GestureClassifier.JointPoint(location: CGPoint(x: 0.50, y: 0.80), confidence: 0.2)
        XCTAssertFalse(GestureClassifier.isOpenPalm(joints: joints))
    }

    func testThumbTuckedFailsClosedWithFingersStillExtended() {
        // Honest negative: all four fingers are still extended (unchanged
        // from the open-palm fixture) — only the thumb metric should be why
        // this reads as closed.
        var joints = Self.openPalmJoints()
        joints[.thumbTip] = GestureClassifier.JointPoint(location: CGPoint(x: 0.42, y: 0.33), confidence: 0.9)
        XCTAssertFalse(GestureClassifier.isOpenPalm(joints: joints))
    }

    // MARK: - GestureClassifier: fist (D15)

    func testFistJointsClassifyAsFist() {
        XCTAssertTrue(GestureClassifier.isFist(joints: Self.fistJoints()))
    }

    func testOpenPalmJointsDoNotClassifyAsFist() {
        XCTAssertFalse(GestureClassifier.isFist(joints: Self.openPalmJoints()))
    }

    func testFistMissingJointFailsClosed() {
        var joints = Self.fistJoints()
        joints.removeValue(forKey: .ringTip)
        XCTAssertFalse(GestureClassifier.isFist(joints: joints))
    }

    // MARK: - GestureClassifier: thumbs up (D15)

    func testFistWithExtendedThumbClassifiesAsThumbsUp() {
        XCTAssertTrue(GestureClassifier.isThumbsUp(joints: Self.thumbsUpJoints()))
    }

    func testOpenPalmDoesNotClassifyAsThumbsUp() {
        XCTAssertFalse(GestureClassifier.isThumbsUp(joints: Self.openPalmJoints()))
    }

    func testFistWithTuckedThumbDoesNotClassifyAsThumbsUp() {
        XCTAssertFalse(GestureClassifier.isThumbsUp(joints: Self.fistJoints()))
    }

    // MARK: - GestureClassifier: hands together (D15)

    func testOverlappingHandsClassifyAsHandsTogether() {
        let hand1 = Self.palmJoints(wristX: 0.40, wristY: 0.40)
        let hand2 = Self.palmJoints(wristX: 0.46, wristY: 0.40)
        XCTAssertTrue(GestureClassifier.isHandsTogether(hand1, hand2))
    }

    func testFarApartHandsDoNotClassifyAsHandsTogether() {
        let hand1 = Self.palmJoints(wristX: 0.10, wristY: 0.40)
        let hand2 = Self.palmJoints(wristX: 0.90, wristY: 0.40)
        XCTAssertFalse(GestureClassifier.isHandsTogether(hand1, hand2))
    }

    func testSingleHandNeverClassifiesAsHandsTogetherViaClassify() {
        let hand1 = Self.palmJoints(wristX: 0.40, wristY: 0.40)
        XCTAssertFalse(GestureClassifier.classify(hands: [hand1]).contains(.handsTogether))
    }

    // MARK: - GestureClassifier.classify: precedence + set semantics

    func testClassifyThumbsUpSuppressesFist() {
        let detected = GestureClassifier.classify(hands: [Self.thumbsUpJoints()])
        XCTAssertTrue(detected.contains(.thumbsUp))
        XCTAssertFalse(detected.contains(.fist), "thumbsUp must suppress fist for the same hand")
    }

    func testClassifyPlainFistReportsFistNotThumbsUp() {
        let detected = GestureClassifier.classify(hands: [Self.fistJoints()])
        XCTAssertEqual(detected, [.fist])
    }

    func testClassifyOpenPalmReportsOpenPalmOnly() {
        let detected = GestureClassifier.classify(hands: [Self.openPalmJoints()])
        XCTAssertEqual(detected, [.openPalm])
    }

    /// Translates every joint in `joints` by `(dx, dy)` — distances (and so
    /// every classifier that only compares distances between a fixture's OWN
    /// joints) are unaffected, but the fixture's absolute position moves.
    /// Used to build two hands that are each independently still a
    /// self-consistent fist while sitting at chosen palm-center positions —
    /// naively overwriting just the palm-center joints (wrist/MCPs) on a
    /// fixed fingertip layout would measure those fingertips relative to a
    /// DIFFERENT wrist than they were authored against, silently breaking
    /// the fist geometry.
    private static func translate(_ joints: GestureClassifier.HandJoints, dx: Double, dy: Double) -> GestureClassifier.HandJoints {
        joints.mapValues {
            GestureClassifier.JointPoint(location: CGPoint(x: $0.location.x + dx, y: $0.location.y + dy), confidence: $0.confidence)
        }
    }

    /// A complete fist — including the middle/ring/little MCPs
    /// `isHandsTogether` needs, which `fistJoints()` alone doesn't have —
    /// translated so its wrist sits at `(wristX, wristY)`.
    private static func positionedFist(wristX: Double, wristY: Double, confidence: Float = 0.9) -> GestureClassifier.HandJoints {
        var joints = translate(fistJoints(confidence: confidence), dx: wristX - 0.50, dy: wristY - 0.10)
        joints[.middleMCP] = GestureClassifier.JointPoint(location: CGPoint(x: wristX, y: wristY + 0.25), confidence: confidence)
        joints[.ringMCP] = GestureClassifier.JointPoint(location: CGPoint(x: wristX + 0.05, y: wristY + 0.25), confidence: confidence)
        joints[.littleMCP] = GestureClassifier.JointPoint(location: CGPoint(x: wristX + 0.10, y: wristY + 0.23), confidence: confidence)
        return joints
    }

    func testClassifyTwoHandsTogetherAlsoReportsPerHandGestures() {
        // Two overlapping fists: handsTogether coexists with fist detected
        // on each hand (a set, so it's still just {.fist, .handsTogether}).
        let hand1 = Self.positionedFist(wristX: 0.40, wristY: 0.40)
        let hand2 = Self.positionedFist(wristX: 0.46, wristY: 0.40)
        let detected = GestureClassifier.classify(hands: [hand1, hand2])
        XCTAssertEqual(detected, [.fist, .handsTogether])
    }

    func testClassifyEmptyHandsReturnsEmptySet() {
        XCTAssertTrue(GestureClassifier.classify(hands: []).isEmpty)
    }

    // MARK: - GestureHoldDetector: continuous hold

    func testContinuousHoldFiresExactlyOnceAtOneSecond() {
        var detector = GestureHoldDetector()
        var results: [Bool] = []
        for i in 0...8 {   // 0.0, 0.125, …, 1.0
            results.append(detector.update(gestureSeen: true, at: Double(i) * 0.125).fired)
        }
        XCTAssertEqual(results, Array(repeating: false, count: 8) + [true])
    }

    func testHoldNeverStartedNeverFires() {
        var detector = GestureHoldDetector()
        for i in 0...16 {
            XCTAssertFalse(detector.update(gestureSeen: false, at: Double(i) * 0.125).fired)
        }
    }

    // MARK: - GestureHoldDetector: flicker tolerance (gap ≤ 0.2 s)

    func testFlickerGapWithinToleranceStillFires() {
        var detector = GestureHoldDetector()
        // Continuous 0.0…0.375, one missed frame at 0.4, then true again at
        // 0.5 — a 0.125 s gap between the two true observations either side
        // of the flicker (comfortably inside the 0.2 s tolerance) — must NOT
        // reset the hold. Continues on to 1.0, where a full 1.0 s has
        // elapsed since the original 0.0 start.
        let frames: [(TimeInterval, Bool)] = [
            (0.000, true), (0.125, true), (0.250, true), (0.375, true),
            (0.400, false),
            (0.500, true), (0.625, true), (0.750, true), (0.875, true), (1.000, true)
        ]
        var results: [Bool] = []
        for (time, seen) in frames {
            results.append(detector.update(gestureSeen: seen, at: time).fired)
        }
        XCTAssertEqual(results, Array(repeating: false, count: frames.count - 1) + [true])
    }

    func testGapBeyondToleranceResetsTheHold() {
        var detector = GestureHoldDetector()
        // Hold starts at 0.0, then a 0.5 s gap (well past the 0.2 s
        // tolerance) before the gesture is seen again — that MUST reset the
        // accumulator. The discriminating check is at t=1.0: without a
        // reset, 1.0 s would already have elapsed since the original 0.0
        // start and this frame would (wrongly) fire; with a correct reset
        // (restart at 0.5) only 0.5 s has elapsed there, so it must NOT
        // fire. The hold only completes at t=1.5 — 1.0 s after the restart.
        XCTAssertFalse(detector.update(gestureSeen: true, at: 0.0).fired)
        XCTAssertFalse(detector.update(gestureSeen: true, at: 0.5).fired)   // gap > 0.2 s → reset
        var results: [Bool] = []
        for i in 1...8 {   // 0.625, 0.75, …, 1.5
            results.append(detector.update(gestureSeen: true, at: 0.5 + Double(i) * 0.125).fired)
        }
        XCTAssertEqual(results, Array(repeating: false, count: 7) + [true])
    }

    func testGestureAwayResetsTheHold() {
        var detector = GestureHoldDetector()
        XCTAssertFalse(detector.update(gestureSeen: true, at: 0.0).fired)
        XCTAssertFalse(detector.update(gestureSeen: true, at: 0.5).fired)
        // Gesture leaves for well over the flicker tolerance — must reset.
        XCTAssertFalse(detector.update(gestureSeen: false, at: 1.0).fired)
        // A fresh sighting starts counting from scratch at the NEW start
        // time (2.0), not from the original 0.0 (which would already read
        // ≥ 1.0 s elapsed and fire immediately if the reset hadn't happened).
        var results: [Bool] = []
        for i in 0...8 {   // 2.0, 2.125, …, 3.0
            results.append(detector.update(gestureSeen: true, at: 2.0 + Double(i) * 0.125).fired)
        }
        XCTAssertEqual(results, Array(repeating: false, count: 8) + [true])
    }

    // MARK: - GestureHoldDetector: cooldown

    func testCooldownSuppressesFiringForThreeSecondsThenRequiresFreshHold() {
        var detector = GestureHoldDetector()
        // Complete the first hold, 0.0 → 1.0.
        for i in 0...7 {
            XCTAssertFalse(detector.update(gestureSeen: true, at: Double(i) * 0.125).fired)
        }
        XCTAssertTrue(detector.update(gestureSeen: true, at: 1.0).fired)   // first fire; cooldown until 4.0

        // Gesture never leaves — held continuously straight through the
        // cooldown. Nothing may fire while time < 4.0.
        for i in 1...23 {   // 1.125 … 3.875
            let t = 1.0 + Double(i) * 0.125
            XCTAssertFalse(detector.update(gestureSeen: true, at: t).fired, "must stay silent during cooldown (t=\(t))")
        }

        // Cooldown lifts exactly at 4.0 — per spec this does NOT refire
        // instantly even though the gesture was held the whole time: it needs
        // a fresh full 1.0 s accumulation starting from the cooldown boundary.
        XCTAssertFalse(detector.update(gestureSeen: true, at: 4.0).fired, "cooldown lifting must not itself fire")

        var results: [Bool] = []
        for i in 1...8 {   // 4.125 … 5.0
            results.append(detector.update(gestureSeen: true, at: 4.0 + Double(i) * 0.125).fired)
        }
        XCTAssertEqual(results, Array(repeating: false, count: 7) + [true], "fresh 1.0 s hold after cooldown must fire")
    }

    // MARK: - GestureHoldDetector: readout (D15 — holdProgress / cooldownRemaining)

    func testHoldProgressRampsZeroToOneAcrossOneSecondHold() {
        var detector = GestureHoldDetector()
        var progresses: [Double] = []
        for i in 0...8 {   // 0.0, 0.125, …, 1.0
            progresses.append(detector.update(gestureSeen: true, at: Double(i) * 0.125).holdProgress)
        }
        XCTAssertEqual(progresses.first ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(progresses.last ?? -1, 1, accuracy: 0.0001)
        // Strictly increasing (or equal) — a monotonic ramp, never bouncing.
        for i in 1..<progresses.count {
            XCTAssertGreaterThanOrEqual(progresses[i], progresses[i - 1])
        }
        // Roughly the fraction of the hold elapsed midway through.
        XCTAssertEqual(progresses[4], 0.5, accuracy: 0.0001)   // t = 0.5 s
    }

    func testHoldProgressIsZeroWhileIdle() {
        var detector = GestureHoldDetector()
        XCTAssertEqual(detector.update(gestureSeen: false, at: 0.0).holdProgress, 0)
        XCTAssertEqual(detector.update(gestureSeen: false, at: 1.0).holdProgress, 0)
    }

    func testHoldProgressResetsOnGestureLoss() {
        var detector = GestureHoldDetector()
        // Sampled every 0.125 s (comfortably inside the 0.2 s flicker
        // tolerance) so the hold accumulates continuously up to t=0.5 —
        // a sparser sampling would itself look like a flicker gap and reset
        // the hold before this test ever gets to "midway".
        var midway = GestureHoldDetector.Result(fired: false, holdProgress: 0, cooldownRemaining: 0)
        for i in 0...4 {   // 0.0, 0.125, …, 0.5
            midway = detector.update(gestureSeen: true, at: Double(i) * 0.125)
        }
        XCTAssertGreaterThan(midway.holdProgress, 0)
        // Gone longer than the flicker tolerance — progress must drop back
        // to zero, not merely pause.
        let afterLoss = detector.update(gestureSeen: false, at: 0.9)
        XCTAssertEqual(afterLoss.holdProgress, 0)
    }

    func testCooldownRemainingCountsDownAfterFiring() {
        var detector = GestureHoldDetector()
        for i in 0...7 {
            _ = detector.update(gestureSeen: true, at: Double(i) * 0.125)
        }
        let fireResult = detector.update(gestureSeen: true, at: 1.0)
        XCTAssertTrue(fireResult.fired)
        XCTAssertEqual(fireResult.cooldownRemaining, 0, "the firing frame itself reports ready, not cooling down")

        let early = detector.update(gestureSeen: false, at: 1.5)
        XCTAssertEqual(early.cooldownRemaining, 2.5, accuracy: 0.0001)   // 4.0 - 1.5

        let late = detector.update(gestureSeen: false, at: 3.9)
        XCTAssertEqual(late.cooldownRemaining, 0.1, accuracy: 0.0001)   // 4.0 - 3.9

        let ready = detector.update(gestureSeen: false, at: 4.0)
        XCTAssertEqual(ready.cooldownRemaining, 0)
    }

    // MARK: - GestureHoldDetector: D25 selectable warm-up time

    func testHalfSecondHoldFiresAfterHalfSecondContinuous() {
        var detector = GestureHoldDetector(holdDuration: 0.5)
        var results: [Bool] = []
        for i in 0...4 {   // 0.0, 0.125, 0.25, 0.375, 0.5
            results.append(detector.update(gestureSeen: true, at: Double(i) * 0.125).fired)
        }
        XCTAssertEqual(results, Array(repeating: false, count: 4) + [true])
    }

    func testThreeSecondHoldDoesNotFireAtTwoPointNineSeconds() {
        var detector = GestureHoldDetector(holdDuration: 3.0)
        // Dense continuous sampling (well within the 0.2 s flicker
        // tolerance — sparse calls with real gaps between them would
        // themselves look like a flicker and reset the hold) up to 2.875 s,
        // then a direct check at 2.9 s — still short of the 3 s hold —
        // before the final sample completes it at 3.0 s.
        for i in 0...23 {   // 0.0, 0.125, …, 2.875
            XCTAssertFalse(detector.update(gestureSeen: true, at: Double(i) * 0.125).fired)
        }
        XCTAssertFalse(detector.update(gestureSeen: true, at: 2.9).fired, "0.1 s short of a 3 s hold must not fire")
        XCTAssertTrue(detector.update(gestureSeen: true, at: 3.0).fired)
    }

    func testHoldProgressNormalizesToTheConfiguredDurationNotAFixedOneSecond() {
        // Half of a 3 s hold should read 0.5, not 0.5/1.0 — progress is
        // relative to whatever `holdDuration` this detector was configured
        // with, whatever that length is. Sampled every 0.125 s like
        // `testHoldProgressRampsZeroToOneAcrossOneSecondHold` above, just at
        // 3× the span.
        var detector = GestureHoldDetector(holdDuration: 3.0)
        var progresses: [Double] = []
        for i in 0...24 {   // 0.0, 0.125, …, 3.0
            progresses.append(detector.update(gestureSeen: true, at: Double(i) * 0.125).holdProgress)
        }
        XCTAssertEqual(progresses.first ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(progresses.last ?? -1, 1, accuracy: 0.0001)
        XCTAssertEqual(progresses[12], 0.5, accuracy: 0.0001)   // t = 1.5 s, half of 3.0 s
    }

    // MARK: - D25: CameraCuePlayer.effectiveEffects (sensor-only effect reduction)

    func testEffectiveEffectsPassesThroughUnchangedWhenNotSensorOnly() {
        let effects = CameraEffects(segmentation: true, magicDust: true, chromaKey: true, gestureGo: true)
        XCTAssertEqual(CameraCuePlayer.effectiveEffects(effects, sensorOnly: false), effects)
    }

    func testEffectiveEffectsForcesVisualEffectsOffWhenSensorOnly() {
        let effects = CameraEffects(
            segmentation: true, magicDust: true, chromaKey: true,
            gestureGo: true, goGesture: .fist, gestureHoldSeconds: 2.0
        )
        let reduced = CameraCuePlayer.effectiveEffects(effects, sensorOnly: true)
        XCTAssertFalse(reduced.segmentation)
        XCTAssertFalse(reduced.magicDust)
        XCTAssertFalse(reduced.chromaKey)
        // Gesture controls (enable/pose/hold) are left completely alone —
        // gesture tracking is the entire point of sensor-only mode.
        XCTAssertTrue(reduced.gestureGo)
        XCTAssertEqual(reduced.goGesture, .fist)
        XCTAssertEqual(reduced.gestureHoldSeconds, 2.0)
    }

    func testEffectiveEffectsLeavesAGestureOnlyConfigurationUnchanged() {
        let effects = CameraEffects(gestureGo: true)
        let reduced = CameraCuePlayer.effectiveEffects(effects, sensorOnly: true)
        XCTAssertEqual(reduced, effects)
        XCTAssertTrue(reduced.anyEnabled, "gestureGo alone still counts toward anyEnabled after reduction")
    }
}
