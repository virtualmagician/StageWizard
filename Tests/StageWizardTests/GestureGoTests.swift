import XCTest
import Vision
@testable import StageWizard

/// D11 gesture GO (experimental): `CameraEffects.gestureGo` model coverage,
/// the pure `OpenPalmClassifier` shape test, and the pure `GestureHoldDetector`
/// hold/flicker/cooldown state machine. No live capture sessions or Vision
/// requests here — everything under test takes plain values and is
/// deterministic; see VideoEngineTests for camera pipeline integration
/// coverage.
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

    // MARK: - anyEnabled

    func testAnyEnabledIncludesGestureGo() {
        // gestureGo REQUIRES the hand-pose path (the processed capture path,
        // same as segmentation/magicDust/chromaKey), so it must count toward
        // anyEnabled even when every other effect is off.
        XCTAssertTrue(CameraEffects(gestureGo: true).anyEnabled)
        XCTAssertFalse(CameraEffects().anyEnabled)
        XCTAssertFalse(CameraEffects(gestureGo: false).anyEnabled)
    }

    // MARK: - OpenPalmClassifier: synthetic joint sets

    /// A plausible "hand pointing straight up, fingers spread" joint set —
    /// every finger's TIP well past its PIP (measured from the wrist) and
    /// the thumb splayed out from the index MCP. Normalized (0…1) Vision
    /// coordinates, bottom-left origin.
    private static func openPalmJoints(confidence: Float = 0.9) -> OpenPalmClassifier.HandJoints {
        func j(_ x: Double, _ y: Double) -> OpenPalmClassifier.JointPoint {
            OpenPalmClassifier.JointPoint(location: CGPoint(x: x, y: y), confidence: confidence)
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
    /// the thumb tucked in near the index MCP.
    private static func fistJoints(confidence: Float = 0.9) -> OpenPalmClassifier.HandJoints {
        func j(_ x: Double, _ y: Double) -> OpenPalmClassifier.JointPoint {
            OpenPalmClassifier.JointPoint(location: CGPoint(x: x, y: y), confidence: confidence)
        }
        return [
            .wrist: j(0.50, 0.10),
            .indexMCP: j(0.45, 0.35), .indexPIP: j(0.45, 0.35), .indexTip: j(0.47, 0.28),
            .middlePIP: j(0.50, 0.35), .middleTip: j(0.49, 0.27),
            .ringPIP: j(0.55, 0.35), .ringTip: j(0.53, 0.27),
            .littlePIP: j(0.60, 0.33), .littleTip: j(0.58, 0.26),
            .thumbIP: j(0.35, 0.30), .thumbTip: j(0.42, 0.33)   // tucked, near indexMCP
        ]
    }

    func testOpenPalmJointsClassifyAsOpenPalm() {
        XCTAssertTrue(OpenPalmClassifier.isOpenPalm(joints: Self.openPalmJoints()))
    }

    func testFistJointsDoNotClassifyAsOpenPalm() {
        XCTAssertFalse(OpenPalmClassifier.isOpenPalm(joints: Self.fistJoints()))
    }

    func testMissingJointFailsClosed() {
        var joints = Self.openPalmJoints()
        joints.removeValue(forKey: .littleTip)
        XCTAssertFalse(OpenPalmClassifier.isOpenPalm(joints: joints))
    }

    func testLowConfidenceJointFailsClosed() {
        var joints = Self.openPalmJoints()
        // Vision detected a point there, but with confidence below the 0.3
        // floor — must be treated the same as "not detected".
        joints[.middleTip] = OpenPalmClassifier.JointPoint(location: CGPoint(x: 0.50, y: 0.80), confidence: 0.2)
        XCTAssertFalse(OpenPalmClassifier.isOpenPalm(joints: joints))
    }

    func testThumbTuckedFailsClosedWithFingersStillExtended() {
        // Honest negative: all four fingers are still extended (unchanged
        // from the open-palm fixture) — only the thumb metric should be why
        // this reads as closed.
        var joints = Self.openPalmJoints()
        joints[.thumbTip] = OpenPalmClassifier.JointPoint(location: CGPoint(x: 0.42, y: 0.33), confidence: 0.9)
        XCTAssertFalse(OpenPalmClassifier.isOpenPalm(joints: joints))
    }

    // MARK: - GestureHoldDetector: continuous hold

    func testContinuousHoldFiresExactlyOnceAtOneSecond() {
        var detector = GestureHoldDetector()
        var results: [Bool] = []
        for i in 0...8 {   // 0.0, 0.125, …, 1.0
            results.append(detector.update(openPalmSeen: true, at: Double(i) * 0.125))
        }
        XCTAssertEqual(results, Array(repeating: false, count: 8) + [true])
    }

    func testHoldNeverStartedNeverFires() {
        var detector = GestureHoldDetector()
        for i in 0...16 {
            XCTAssertFalse(detector.update(openPalmSeen: false, at: Double(i) * 0.125))
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
            results.append(detector.update(openPalmSeen: seen, at: time))
        }
        XCTAssertEqual(results, Array(repeating: false, count: frames.count - 1) + [true])
    }

    func testGapBeyondToleranceResetsTheHold() {
        var detector = GestureHoldDetector()
        // Hold starts at 0.0, then a 0.5 s gap (well past the 0.2 s
        // tolerance) before the palm is seen again — that MUST reset the
        // accumulator. The discriminating check is at t=1.0: without a
        // reset, 1.0 s would already have elapsed since the original 0.0
        // start and this frame would (wrongly) fire; with a correct reset
        // (restart at 0.5) only 0.5 s has elapsed there, so it must NOT
        // fire. The hold only completes at t=1.5 — 1.0 s after the restart.
        XCTAssertFalse(detector.update(openPalmSeen: true, at: 0.0))
        XCTAssertFalse(detector.update(openPalmSeen: true, at: 0.5))   // gap > 0.2 s → reset
        var results: [Bool] = []
        for i in 1...8 {   // 0.625, 0.75, …, 1.5
            results.append(detector.update(openPalmSeen: true, at: 0.5 + Double(i) * 0.125))
        }
        XCTAssertEqual(results, Array(repeating: false, count: 7) + [true])
    }

    func testPalmAwayResetsTheHold() {
        var detector = GestureHoldDetector()
        XCTAssertFalse(detector.update(openPalmSeen: true, at: 0.0))
        XCTAssertFalse(detector.update(openPalmSeen: true, at: 0.5))
        // Palm leaves for well over the flicker tolerance — must reset.
        XCTAssertFalse(detector.update(openPalmSeen: false, at: 1.0))
        // A fresh sighting starts counting from scratch at the NEW start
        // time (2.0), not from the original 0.0 (which would already read
        // ≥ 1.0 s elapsed and fire immediately if the reset hadn't happened).
        var results: [Bool] = []
        for i in 0...8 {   // 2.0, 2.125, …, 3.0
            results.append(detector.update(openPalmSeen: true, at: 2.0 + Double(i) * 0.125))
        }
        XCTAssertEqual(results, Array(repeating: false, count: 8) + [true])
    }

    // MARK: - GestureHoldDetector: cooldown

    func testCooldownSuppressesFiringForThreeSecondsThenRequiresFreshHold() {
        var detector = GestureHoldDetector()
        // Complete the first hold, 0.0 → 1.0.
        for i in 0...7 {
            XCTAssertFalse(detector.update(openPalmSeen: true, at: Double(i) * 0.125))
        }
        XCTAssertTrue(detector.update(openPalmSeen: true, at: 1.0))   // first fire; cooldown until 4.0

        // Palm never leaves — held continuously straight through the
        // cooldown. Nothing may fire while time < 4.0.
        for i in 1...23 {   // 1.125 … 3.875
            let t = 1.0 + Double(i) * 0.125
            XCTAssertFalse(detector.update(openPalmSeen: true, at: t), "must stay silent during cooldown (t=\(t))")
        }

        // Cooldown lifts exactly at 4.0 — per spec this does NOT refire
        // instantly even though the palm was held the whole time: it needs
        // a fresh full 1.0 s accumulation starting from the cooldown boundary.
        XCTAssertFalse(detector.update(openPalmSeen: true, at: 4.0), "cooldown lifting must not itself fire")

        var results: [Bool] = []
        for i in 1...8 {   // 4.125 … 5.0
            results.append(detector.update(openPalmSeen: true, at: 4.0 + Double(i) * 0.125))
        }
        XCTAssertEqual(results, Array(repeating: false, count: 7) + [true], "fresh 1.0 s hold after cooldown must fire")
    }
}
