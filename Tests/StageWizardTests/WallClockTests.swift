import XCTest
@testable import StageWizard

/// Phase D5: wall-clock triggers — "fire this cue at HH:MM:SS".
@MainActor
final class WallClockTests: XCTestCase {

    // MARK: - Cue.wallClock Codable

    func testWallClockRoundTripsThroughCueCodable() throws {
        let cue = Cue(number: "1", wallClock: 12345, body: .stop(StopBody()))
        let decoded = try JSONDecoder().decode(Cue.self, from: JSONEncoder().encode(cue))
        XCTAssertEqual(decoded.wallClock, 12345)
    }

    func testWallClockDefaultsToNilWhenKeyMissingFromOlderFiles() throws {
        // A pre-D5 show file predates the "wallClock" key entirely.
        var show = ShowFile()
        show.cues = [Cue(number: "1", wallClock: 100, body: .stop(StopBody()))]
        var json = try JSONSerialization.jsonObject(with: show.encoded()) as! [String: Any]
        var cues = json["cues"] as! [[String: Any]]
        cues[0].removeValue(forKey: "wallClock")
        json["cues"] = cues
        let decoded = try ShowFile.load(from: try JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.cues[0].wallClock, "pre-D5 cues predate wall-clock triggers")
    }

    func testWallClockClampsOutOfRangeValuesModulo() {
        // High: wraps past a day.
        XCTAssertEqual(Cue(number: "1", wallClock: 86400 + 3600, body: .stop(StopBody())).wallClock, 3600)
        // Negative: wraps backward from the next midnight.
        XCTAssertEqual(Cue(number: "2", wallClock: -10, body: .stop(StopBody())).wallClock, 86390)
        // In range: untouched.
        XCTAssertEqual(Cue(number: "3", wallClock: 72000, body: .stop(StopBody())).wallClock, 72000)
    }

    func testWallClockClampsOnDecodeToo() throws {
        // Round-trip a real cue through JSON, then hand-tamper the wallClock
        // value to something out of range before decoding — the clamp lives
        // in init(from:), not just the memberwise initializer.
        let cue = Cue(number: "1", wallClock: 100, body: .stop(StopBody()))
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(cue)) as! [String: Any]
        json["wallClock"] = 90000
        let decoded = try JSONDecoder().decode(Cue.self, from: try JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.wallClock, 90000 - 86400)
    }

    // MARK: - dueCues: pure scheduler core

    func testDueCuesFiresWhenTargetLandsInTickWindow() {
        let id = UUID()
        let cue = Cue(id: id, number: "1", wallClock: 100, body: .stop(StopBody()))
        XCTAssertEqual(
            TransportController.dueCues(between: 90, and: 110, in: [cue], already: []).map(\.id),
            [id]
        )
        // Boundary: previousTick itself must NOT fire (strictly greater-than).
        XCTAssertTrue(TransportController.dueCues(between: 100, and: 110, in: [cue], already: []).isEmpty)
        // Boundary: nowTick itself DOES fire (less-than-or-equal).
        let atNow = Cue(id: id, number: "1", wallClock: 110, body: .stop(StopBody()))
        XCTAssertEqual(
            TransportController.dueCues(between: 90, and: 110, in: [atNow], already: []).map(\.id),
            [id]
        )
    }

    func testDueCuesExcludesCuesAlreadyFiredToday() {
        let id = UUID()
        let cue = Cue(id: id, number: "1", wallClock: 100, body: .stop(StopBody()))
        XCTAssertTrue(
            TransportController.dueCues(between: 90, and: 110, in: [cue], already: [id]).isEmpty,
            "a cue already marked fired today must not fire again on a later tick the same day"
        )
    }

    func testDueCuesSkipsDisarmedAndUntaggedCues() {
        let disarmed = Cue(number: "1", armed: false, wallClock: 100, body: .stop(StopBody()))
        let untagged = Cue(number: "2", wallClock: nil, body: .stop(StopBody()))
        XCTAssertTrue(TransportController.dueCues(between: 90, and: 110, in: [disarmed, untagged], already: []).isEmpty)
    }

    func testDueCuesHandlesMidnightWraparound() {
        // Spec case: previous tick 23:59:55, now tick 00:00:05, cue targets 00:00:02.
        let id = UUID()
        let cue = Cue(id: id, number: "1", wallClock: 2, body: .stop(StopBody()))
        XCTAssertEqual(
            TransportController.dueCues(between: 86395, and: 5, in: [cue], already: []).map(\.id),
            [id],
            "a target just after midnight must fire when the tick window wraps across it"
        )
        // A target that was already due *before* the wrap (e.g. 23:59:58) must
        // also still be covered by the wrapped window.
        let lateCue = Cue(id: UUID(), number: "2", wallClock: 86398, body: .stop(StopBody()))
        XCTAssertEqual(
            TransportController.dueCues(between: 86395, and: 5, in: [lateCue], already: []).count,
            1
        )
        // A target well outside either half of the wrapped window must not fire.
        let midday = Cue(number: "3", wallClock: 43200, body: .stop(StopBody()))
        XCTAssertTrue(TransportController.dueCues(between: 86395, and: 5, in: [midday], already: []).isEmpty)
    }

    // MARK: - End-to-end: TransportController.wallClockTick() + injectable `now`

    /// Wraps MockProvider to count how many times each cue was actually armed,
    /// so "fires once" / "fires again tomorrow" can be verified precisely
    /// instead of just checking presence in a dictionary.
    @MainActor
    private final class CountingProvider: CuePlayerProviding {
        let inner = MockProvider()
        private(set) var armCounts: [UUID: Int] = [:]

        func armPlayer(for cue: Cue, showFolder: URL?) async throws -> MediaPlayback {
            armCounts[cue.id, default: 0] += 1
            return try await inner.armPlayer(for: cue, showFolder: showFolder)
        }
    }

    private var show = ShowFile()
    private var provider = CountingProvider()
    private var transport: TransportController!

    override func setUp() async throws {
        show = ShowFile()
        provider = CountingProvider()
        transport = TransportController(
            provider: provider,
            show: { [unowned self] in self.show },
            showFolder: { nil }
        )
    }

    private func wait(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    func testArmedCueFiresOnceNotTwiceOnANextTickSameDay() async {
        let cue = Cue(number: "1", wallClock: 100, body: .audio(AudioBody(media: MediaReference(absolutePath: "/fake/1.wav"))))
        provider.inner.durations[cue.id] = 0.2
        show.cues = [cue]

        // Ticks stay <=5s apart throughout (FIX 5's forward-gap guard treats
        // anything wider as a stale/sleep gap) — mirrors the real 1 Hz loop
        // closely enough while still landing cleanly on either side of the target.
        var t: TimeInterval = 96
        transport.now = { t }
        transport.wallClockTick()   // first tick only establishes a baseline
        await wait(0.02)
        XCTAssertEqual(provider.armCounts[cue.id] ?? 0, 0, "no baseline-tick firing")

        t = 101   // window (96, 101] crosses the target
        transport.wallClockTick()
        await wait(0.05)
        XCTAssertEqual(provider.armCounts[cue.id] ?? 0, 1, "fires once its target time is crossed")

        t = 106   // later the same day — already fired today
        transport.wallClockTick()
        await wait(0.05)
        XCTAssertEqual(provider.armCounts[cue.id] ?? 0, 1, "must not fire a second time later the same day")
    }

    func testDisarmedCueNeverFires() async {
        let cue = Cue(
            number: "1", armed: false, wallClock: 100,
            body: .audio(AudioBody(media: MediaReference(absolutePath: "/fake/1.wav")))
        )
        provider.inner.durations[cue.id] = 0.2
        show.cues = [cue]

        var t: TimeInterval = 96
        transport.now = { t }
        transport.wallClockTick()
        t = 101   // window (96, 101] crosses the target — a live tick, not a stale gap
        transport.wallClockTick()
        await wait(0.05)
        XCTAssertEqual(provider.armCounts[cue.id] ?? 0, 0, "a disarmed cue must never fire from the wall clock")
    }

    func testCueFiresAgainAfterTheLocalDayChanges() async {
        let cue = Cue(number: "1", wallClock: 100, body: .audio(AudioBody(media: MediaReference(absolutePath: "/fake/1.wav"))))
        provider.inner.durations[cue.id] = 0.2
        show.cues = [cue]

        var t: TimeInterval = 96
        transport.now = { t }
        transport.wallClockTick()   // baseline
        t = 101   // window (96, 101] crosses the target — a live (<=5s) tick
        transport.wallClockTick()   // fires today
        await wait(0.05)
        XCTAssertEqual(provider.armCounts[cue.id] ?? 0, 1)

        t = 86399   // a big forward jump toward end of day — same as the app
        transport.wallClockTick()   // just ticking along for hours; re-baselines, no fire.

        t = 1       // a small (<=5s) backward step across midnight — a
        transport.wallClockTick()   // genuine wrap: clears today's fired set.

        // Walk forward in <=5s hops (mirroring the real 1 Hz ticking loop)
        // until the window crosses the target again on the new day.
        while t < 103 {
            t = min(t + 5, 103)
            transport.wallClockTick()
        }
        await wait(0.05)
        XCTAssertEqual(provider.armCounts[cue.id] ?? 0, 2, "a new local day re-arms the cue for one more fire")
    }

    /// FIX 5(a): a stale forward gap (e.g. the Mac slept through the
    /// target) must not fire the cue it swallowed once ticking resumes —
    /// only a live, roughly-1s-wide window fires anything.
    func testSleepGapDoesNotBarrageFire() async {
        let cue = Cue(number: "1", wallClock: 50, body: .audio(AudioBody(media: MediaReference(absolutePath: "/fake/1.wav"))))
        provider.inner.durations[cue.id] = 0.2
        show.cues = [cue]

        var t: TimeInterval = 10
        transport.now = { t }
        transport.wallClockTick()   // baseline

        t = 100   // a 90s forward jump, well past the 5s guard — sleep/wake.
        transport.wallClockTick()
        await wait(0.05)
        XCTAssertEqual(provider.armCounts[cue.id] ?? 0, 0, "a stale forward gap must not fire cues whose target fell inside it")

        t = 103   // ticking resumes normally after the re-baseline.
        transport.wallClockTick()
        await wait(0.05)
        XCTAssertEqual(provider.armCounts[cue.id] ?? 0, 0, "target 50 already passed inside the stale gap — must not fire retroactively")
    }

    /// FIX 5(b): a backwards clock step that is NOT a genuine midnight
    /// rollover (an NTP correction, a manual time change) must leave
    /// firedToday alone, so a cue already fired today doesn't re-fire once
    /// the clock resumes ticking forward past its target a second time.
    func testBackwardsClockStepDoesNotRefireAnAlreadyFiredCue() async {
        let cue = Cue(number: "1", wallClock: 100, body: .audio(AudioBody(media: MediaReference(absolutePath: "/fake/1.wav"))))
        provider.inner.durations[cue.id] = 0.2
        show.cues = [cue]

        var t: TimeInterval = 96
        transport.now = { t }
        transport.wallClockTick()   // baseline
        t = 101   // window (96, 101] crosses the target — a live (<=5s) tick
        transport.wallClockTick()   // fires today
        await wait(0.05)
        XCTAssertEqual(provider.armCounts[cue.id] ?? 0, 1)

        t = 90   // clock stepped backwards ~11s — nowhere near a midnight
        transport.wallClockTick()   // wrap: must be treated as a clock step.
        await wait(0.05)
        XCTAssertEqual(provider.armCounts[cue.id] ?? 0, 1, "a backward clock step must not clear firedToday")

        t = 94    // small forward hop, window (90, 94] doesn't reach the target
        transport.wallClockTick()
        t = 99    // window (94, 99] still doesn't reach the target
        transport.wallClockTick()
        t = 103   // window (99, 103] crosses the target's time again
        transport.wallClockTick()
        await wait(0.05)
        XCTAssertEqual(provider.armCounts[cue.id] ?? 0, 1, "already fired today — the backward step must not have cleared firedToday, so this must not re-fire")
    }

    func testWallClockNeverFiresWhilePanicking() async {
        let cue = Cue(number: "1", wallClock: 100, body: .audio(AudioBody(media: MediaReference(absolutePath: "/fake/1.wav"))))
        provider.inner.durations[cue.id] = 0.2
        show.cues = [cue]
        show.settings.panicDuration = 5

        var t: TimeInterval = 96
        transport.now = { t }
        transport.wallClockTick()   // baseline
        transport.panic()          // soft panic: isPanicking stays true for the ramp window

        t = 101   // window (96, 101] crosses the target — a live (<=5s) tick,
        transport.wallClockTick()   // so this genuinely exercises the panic guard.
        await wait(0.05)
        XCTAssertTrue(transport.isPanicking, "still mid-ramp — the test would be meaningless otherwise")
        XCTAssertEqual(provider.armCounts[cue.id] ?? 0, 0, "a tick that lands while panicking must not fire")
    }
}
