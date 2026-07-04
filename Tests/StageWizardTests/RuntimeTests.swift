import XCTest
@testable import StageWizard

/// Scripted MediaPlayback: "plays" for a fixed wall-clock duration, so the
/// transport's sequencing/panic logic is tested with zero AV dependencies.
@MainActor
final class MockPlayer: MediaPlayback {
    let playDuration: TimeInterval
    private(set) var started = false
    private(set) var stopCount = 0
    private(set) var fadeOutRequests: [(toDB: Double, duration: TimeInterval, thenStop: Bool)] = []
    private var endTask: Task<Void, Never>?
    private var finished = false

    var duration: TimeInterval? { playDuration }
    var currentTime: TimeInterval = 0
    var isPaused = false
    var currentVolumeDB: Double = 0
    var onFinished: (@MainActor (PlaybackEndReason) -> Void)?

    init(playDuration: TimeInterval) {
        self.playDuration = playDuration
    }

    func start() {
        started = true
        endTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(playDuration))
            guard !Task.isCancelled else { return }
            self.finishOnce(.natural)
        }
    }

    func pause() { isPaused = true; endTask?.cancel() }

    func resume() {
        isPaused = false
        endTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(playDuration))
            guard !Task.isCancelled else { return }
            self.finishOnce(.natural)
        }
    }

    func stop() {
        stopCount += 1
        endTask?.cancel()
        finishOnce(.stopped)
    }

    func setVolume(dB: Double) { currentVolumeDB = dB }

    func fadeVolume(toDB: Double, duration: TimeInterval, curve: FadeCurve, thenStop: Bool) {
        fadeOutRequests.append((toDB, duration, thenStop))
        if thenStop {
            // Simulate the ramp completing, then the hard stop.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(duration))
                self?.currentVolumeDB = toDB
                self?.stop()
            }
        } else {
            currentVolumeDB = toDB
        }
    }

    func fadeOpacity(to opacity: Double, duration: TimeInterval) {}
    func exitLoop() {}

    private func finishOnce(_ reason: PlaybackEndReason) {
        guard !finished else { return }
        finished = true
        onFinished?(reason)
    }
}

@MainActor
final class MockProvider: CuePlayerProviding {
    /// Playback duration per cue id; default 0.3 s.
    var durations: [UUID: TimeInterval] = [:]
    var armDelay: TimeInterval = 0
    private(set) var players: [UUID: MockPlayer] = [:]
    var failFor: Set<UUID> = []

    func armPlayer(for cue: Cue, showFolder: URL?) async throws -> MediaPlayback {
        if armDelay > 0 { try? await Task.sleep(for: .seconds(armDelay)) }
        if failFor.contains(cue.id) { throw ArmError.mediaMissing(cueName: cue.displayName) }
        let player = MockPlayer(playDuration: durations[cue.id] ?? 0.3)
        players[cue.id] = player
        return player
    }
}

@MainActor
final class RuntimeTests: XCTestCase {
    private var show = ShowFile()
    private var provider = MockProvider()
    private var transport: TransportController!

    override func setUp() async throws {
        show = ShowFile()
        show.settings.panicDuration = 0.2
        provider = MockProvider()
        transport = TransportController(
            provider: provider,
            show: { [unowned self] in self.show },
            showFolder: { nil }
        )
    }

    private func audioCue(_ number: String, duration: TimeInterval = 0.3, follow: FollowAction = .none, preWait: TimeInterval = 0) -> Cue {
        var cue = Cue(
            number: number,
            preWait: preWait,
            follow: follow,
            body: .audio(AudioBody(media: MediaReference(absolutePath: "/fake/\(number).wav")))
        )
        cue.name = "Cue \(number)"
        provider.durations[cue.id] = duration
        return cue
    }

    private func wait(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    // MARK: - GO / playhead

    func testGoFiresStandingCueAndAdvancesPlayhead() async {
        let a = audioCue("1"), b = audioCue("2")
        show.cues = [a, b]
        transport.go()
        await wait(0.05)
        XCTAssertEqual(transport.registry.instances.count, 1)
        XCTAssertEqual(transport.registry.instances.first?.cue.id, a.id)
        XCTAssertEqual(transport.playheadID, b.id)
    }

    func testPlayheadSkipsFollowChain() async {
        let a = audioCue("1", follow: .autoContinue(postWait: 10))
        let b = audioCue("2", follow: .autoFollow)
        let c = audioCue("3")
        let d = audioCue("4")
        show.cues = [a, b, c, d]
        transport.go()
        await wait(0.02)
        // a chains b, b chains c → playhead must land on d.
        XCTAssertEqual(transport.playheadID, d.id)
    }

    func testDoubleGOProtection() async {
        show.settings.doubleGOProtection = 0.5
        let a = audioCue("1"), b = audioCue("2")
        show.cues = [a, b]
        transport.go()
        transport.go()   // inside protection window — ignored
        await wait(0.05)
        XCTAssertEqual(transport.registry.instances.count, 1)
    }

    // MARK: - Follow semantics

    func testAutoContinueAnchorsToStartNotCompletion() async {
        // a plays 1.0s but post-wait is 0.15s → b fires long before a ends.
        let a = audioCue("1", duration: 1.0, follow: .autoContinue(postWait: 0.15))
        let b = audioCue("2")
        show.cues = [a, b]
        transport.go()
        await wait(0.05)
        XCTAssertNil(provider.players[b.id], "b must not fire before post-wait")
        await wait(0.2)
        XCTAssertNotNil(provider.players[b.id], "b fires at post-wait while a still plays")
        XCTAssertEqual(transport.registry.instances.count, 2)
    }

    func testAutoFollowFiresOnCompletion() async {
        let a = audioCue("1", duration: 0.2, follow: .autoFollow)
        let b = audioCue("2")
        show.cues = [a, b]
        transport.go()
        await wait(0.1)
        XCTAssertNil(provider.players[b.id], "b must not fire while a plays")
        await wait(0.25)
        XCTAssertNotNil(provider.players[b.id], "b fires when a completes")
    }

    func testPreWaitDelaysAction() async {
        let a = audioCue("1", preWait: 0.2)
        show.cues = [a]
        transport.go()
        await wait(0.1)
        XCTAssertNil(provider.players[a.id])
        XCTAssertEqual(transport.registry.instances.first?.state, .preWait)
        await wait(0.2)
        XCTAssertNotNil(provider.players[a.id])
    }

    func testPauseDuringPreWaitHoldsRemaining() async {
        let a = audioCue("1", preWait: 0.25)
        show.cues = [a]
        transport.go()
        await wait(0.1)
        transport.pauseAll()
        await wait(0.3)   // well past the original pre-wait
        XCTAssertNil(provider.players[a.id], "paused pre-wait must not elapse")
        transport.resumeAll()
        await wait(0.25)
        XCTAssertNotNil(provider.players[a.id])
    }

    func testPausedAutoContinueDoesNotFire() async {
        let a = audioCue("1", duration: 1.0, follow: .autoContinue(postWait: 0.2))
        let b = audioCue("2")
        show.cues = [a, b]
        transport.go()
        await wait(0.05)
        transport.pauseAll()
        await wait(0.4)
        XCTAssertNil(provider.players[b.id], "paused follow must not fire")
        transport.resumeAll()
        await wait(0.25)
        XCTAssertNotNil(provider.players[b.id])
    }

    // MARK: - Groups

    func testFireAllGroupStartsChildrenTogether() async {
        let group = Cue(number: "10", body: .group(GroupBody(mode: .fireAll)))
        var c1 = audioCue("10.1", duration: 0.3)
        var c2 = audioCue("10.2", duration: 0.3)
        c1.parentID = group.id
        c2.parentID = group.id
        show.cues = [group, c1, c2]
        transport.go()
        await wait(0.1)
        XCTAssertNotNil(provider.players[c1.id])
        XCTAssertNotNil(provider.players[c2.id])
        // group + 2 children active
        XCTAssertEqual(transport.registry.instances.count, 3)
        await wait(0.4)
        XCTAssertEqual(transport.registry.instances.count, 0, "group completes when children do")
    }

    func testTimelineGroupHonorsOffsets() async {
        var body = GroupBody(mode: .timeline)
        let group = Cue(number: "10", body: .group(body))
        var c1 = audioCue("10.1", duration: 0.2)
        var c2 = audioCue("10.2", duration: 0.2)
        c1.parentID = group.id
        c2.parentID = group.id
        body.childOffsets = [c2.id: 0.3]
        var groupCue = group
        groupCue.body = .group(body)
        show.cues = [groupCue, c1, c2]
        transport.go()
        await wait(0.1)
        XCTAssertNotNil(provider.players[c1.id], "offset-0 child starts at group start")
        XCTAssertNil(provider.players[c2.id], "offset child waits")
        await wait(0.3)
        XCTAssertNotNil(provider.players[c2.id])
    }

    func testStoppingGroupStopsChildren() async {
        let group = Cue(number: "10", body: .group(GroupBody(mode: .fireAll)))
        var c1 = audioCue("10.1", duration: 5)
        c1.parentID = group.id
        show.cues = [group, c1]
        transport.go()
        await wait(0.1)
        let groupInstance = transport.registry.instances.first { $0.cue.id == group.id }
        groupInstance?.stop()
        await wait(0.05)
        XCTAssertEqual(provider.players[c1.id]?.stopCount, 1)
        XCTAssertEqual(transport.registry.instances.count, 0)
    }

    // MARK: - Stop & fade cues

    func testStopCueStopsTarget() async {
        let a = audioCue("1", duration: 5)
        var stopBody = StopBody()
        stopBody.targetID = a.id
        let stopCue = Cue(number: "2", body: .stop(stopBody))
        show.cues = [a, stopCue]
        transport.go()
        await wait(0.05)
        transport.go()
        await wait(0.1)
        XCTAssertEqual(provider.players[a.id]?.stopCount, 1)
        XCTAssertEqual(transport.registry.instances.count, 0)
    }

    func testStopAllCueStopsEverything() async {
        let a = audioCue("1", duration: 5, follow: .autoContinue(postWait: 0))
        let b = audioCue("2", duration: 5)
        let stopCue = Cue(number: "3", body: .stop(StopBody()))   // nil target = all
        show.cues = [a, b, stopCue]
        transport.go()
        await wait(0.1)
        XCTAssertEqual(transport.registry.instances.count, 2)
        transport.go()
        await wait(0.1)
        XCTAssertEqual(transport.registry.instances.count, 0)
    }

    func testFadeCueFadesAndStopsTarget() async {
        let a = audioCue("1", duration: 5)
        let fadeCue = Cue(number: "2", body: .fade(FadeBody(targetID: a.id, duration: 0.15)))
        show.cues = [a, fadeCue]
        transport.go()
        await wait(0.05)
        let player = provider.players[a.id]!
        transport.go()
        await wait(0.05)
        XCTAssertEqual(player.fadeOutRequests.count, 1)
        XCTAssertEqual(player.fadeOutRequests[0].thenStop, true)
        XCTAssertEqual(transport.registry.instances.first { $0.cue.id == a.id }?.state, .fadingOut)
        await wait(0.3)
        XCTAssertEqual(player.stopCount, 1, "fade-to-silence stops the target after settling")
    }

    func testFadeCueOnStoppedTargetIsGracefulNoOp() async {
        let a = audioCue("1", duration: 5)
        let fadeCue = Cue(number: "2", body: .fade(FadeBody(targetID: a.id, duration: 0.1)))
        show.cues = [a, fadeCue]
        var warnings: [String] = []
        transport.onOperatorWarning = { warnings.append($0) }
        // Fire the fade with nothing running: must warn, not crash.
        transport.fire(cueID: fadeCue.id)
        await wait(0.2)
        XCTAssertEqual(warnings.count, 1)
        XCTAssertEqual(transport.registry.instances.count, 0)
    }

    // MARK: - Panic

    func testSoftPanicFadesThenStops() async {
        let a = audioCue("1", duration: 5)
        show.cues = [a]
        transport.go()
        await wait(0.05)
        let player = provider.players[a.id]!
        transport.panic()
        XCTAssertTrue(transport.isPanicking)
        XCTAssertEqual(player.fadeOutRequests.count, 1)
        XCTAssertEqual(player.fadeOutRequests[0].duration, 0.2, accuracy: 0.001)
        await wait(0.6)
        XCTAssertEqual(player.stopCount, 1)
        XCTAssertFalse(transport.isPanicking)
        XCTAssertEqual(transport.registry.instances.count, 0)
    }

    func testDoublePanicHardStopsImmediately() async {
        let a = audioCue("1", duration: 5)
        show.cues = [a]
        transport.go()
        await wait(0.05)
        let player = provider.players[a.id]!
        transport.panic()
        transport.panic()   // second within window → hard stop now
        await wait(0.05)
        XCTAssertEqual(player.stopCount, 1)
        XCTAssertEqual(transport.registry.instances.count, 0)
        XCTAssertFalse(transport.isPanicking)
    }

    func testPanicCancelsPendingFollows() async {
        let a = audioCue("1", duration: 0.1, follow: .autoContinue(postWait: 0.3))
        let b = audioCue("2")
        show.cues = [a, b]
        transport.go()
        await wait(0.05)
        transport.panic()
        await wait(0.5)
        XCTAssertNil(provider.players[b.id], "panic must cancel the pending auto-continue")
    }

    // MARK: - Errors

    func testFailedArmStillFiresAutoFollow() async {
        let a = audioCue("1", follow: .autoFollow)
        provider.failFor = [a.id]
        let b = audioCue("2")
        show.cues = [a, b]
        var warnings: [String] = []
        transport.onOperatorWarning = { warnings.append($0) }
        transport.go()
        await wait(0.2)
        XCTAssertFalse(warnings.isEmpty, "arm failure surfaces a warning")
        XCTAssertNotNil(provider.players[b.id], "the show must go on: follow fires despite the error")
    }

    func testDisarmedCueSkipsActionButChains() async {
        var a = audioCue("1", follow: .autoFollow)
        a.armed = false
        let b = audioCue("2")
        show.cues = [a, b]
        transport.go()
        await wait(0.1)
        XCTAssertNil(provider.players[a.id], "disarmed cue must not play")
        XCTAssertNotNil(provider.players[b.id], "disarmed cue still chains")
    }
}
