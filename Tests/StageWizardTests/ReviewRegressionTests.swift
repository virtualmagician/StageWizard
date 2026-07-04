import XCTest
@testable import StageWizard

/// Regression tests for the show-critical defects found in the final review.
@MainActor
final class ReviewRegressionTests: XCTestCase {
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

    private func audioCue(_ number: String, duration: TimeInterval = 0.3, follow: FollowAction = .none) -> Cue {
        let cue = Cue(number: number, follow: follow,
                      body: .audio(AudioBody(media: MediaReference(absolutePath: "/fake/\(number).wav"))))
        provider.durations[cue.id] = duration
        return cue
    }

    private func wait(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    // MARK: - Stop must never fire follows

    func testStopCueDoesNotFireTargetsAutoFollow() async {
        let a = audioCue("1", duration: 5, follow: .autoFollow)
        let b = audioCue("2")
        let stopCue = Cue(number: "3", body: .stop(StopBody(targetID: a.id)))
        show.cues = [a, b, stopCue]
        transport.go()
        await wait(0.05)
        transport.fire(cueID: stopCue.id)
        await wait(0.2)
        XCTAssertNil(provider.players[b.id], "stopping a cue must NOT launch its auto-follow")
        XCTAssertEqual(transport.registry.instances.count, 0)
    }

    func testPanicDoesNotFireAutoFollow() async {
        let a = audioCue("1", duration: 5, follow: .autoFollow)
        let b = audioCue("2")
        show.cues = [a, b]
        transport.go()
        await wait(0.05)
        transport.panic()
        transport.panic()   // hard stop immediately
        await wait(0.3)
        XCTAssertNil(provider.players[b.id], "panic must NOT launch the next cue")
    }

    // MARK: - End of list

    func testGoAtEndOfListDoesNotWrapAround() async {
        let a = audioCue("1", duration: 0.1)
        show.cues = [a]
        transport.go()
        await wait(0.3)
        XCTAssertNil(transport.standingByCue, "past the end: nothing stands by")
        transport.go()
        await wait(0.1)
        XCTAssertEqual(provider.players.count, 1, "GO past the end must not restart the show")
        // Stepping back re-arms the last cue.
        transport.movePlayhead(by: -1)
        XCTAssertEqual(transport.standingByCue?.id, a.id)
    }

    // MARK: - Fade cue semantics

    func testFadeCueWithoutTargetIsNoOp() async {
        let a = audioCue("1", duration: 5)
        let fadeCue = Cue(number: "2", body: .fade(FadeBody(targetID: nil)))
        show.cues = [a, fadeCue]
        var warnings: [String] = []
        transport.onOperatorWarning = { warnings.append($0) }
        transport.go()
        await wait(0.05)
        transport.fire(cueID: fadeCue.id)
        await wait(0.1)
        let player = provider.players[a.id]!
        XCTAssertTrue(player.fadeOutRequests.isEmpty, "unconfigured fade must not touch anything")
        XCTAssertEqual(player.stopCount, 0)
        XCTAssertEqual(warnings.count, 1)
    }

    func testFadeCueTargetingGroupStopsItsChildren() async {
        let group = Cue(number: "10", body: .group(GroupBody(mode: .fireAll)))
        var child = audioCue("10.1", duration: 5)
        child.parentID = group.id
        let fadeCue = Cue(number: "20", body: .fade(FadeBody(targetID: group.id, duration: 0.15)))
        show.cues = [group, child, fadeCue]
        transport.go()
        await wait(0.1)
        transport.fire(cueID: fadeCue.id)
        await wait(0.6)
        XCTAssertEqual(provider.players[child.id]?.stopCount, 1, "group fade must reach the audible child")
        XCTAssertEqual(transport.registry.instances.count, 0, "faded group must terminate, not zombify")
    }

    func testFadeCueOnPreWaitInstanceStopsIt() async {
        var a = audioCue("1", duration: 5)
        a.preWait = 5
        let fadeCue = Cue(number: "2", body: .fade(FadeBody(targetID: a.id, duration: 0.1)))
        show.cues = [a, fadeCue]
        transport.go()
        await wait(0.05)
        transport.fire(cueID: fadeCue.id)
        await wait(0.3)
        XCTAssertEqual(transport.registry.instances.count, 0, "pre-waiting target must stop, not zombify")
        await wait(0.3)
        XCTAssertNil(provider.players[a.id], "its action must never fire afterwards")
    }

    // MARK: - Holding instances

    func testHoldingVideoInstanceCanBeStopped() async {
        // Mock a holdLastFrame video: natural finish → .holding (stays active),
        // then stop() must terminate it even though the player's once-only
        // onFinished already fired.
        var cue = Cue(number: "V1", body: .video(VideoBody(
            media: MediaReference(absolutePath: "/fake/v.mov"),
            endBehavior: .holdLastFrame
        )))
        cue.name = "hold"
        provider.durations[cue.id] = 0.15
        show.cues = [cue]
        transport.go()
        await wait(0.4)
        let instance = transport.registry.instances.first
        XCTAssertEqual(instance?.state, .holding, "after natural end the instance holds")
        instance?.stop()
        await wait(0.05)
        XCTAssertEqual(transport.registry.instances.count, 0, "stop must terminate a holding instance")
    }

    // MARK: - Pause while arming

    func testPauseWhileArmingDefersStartToResume() async {
        provider.armDelay = 0.25
        let a = audioCue("1", duration: 0.3)
        show.cues = [a]
        transport.go()
        await wait(0.05)
        transport.pauseAll()
        await wait(0.4)   // arm completes while paused
        let player = provider.players[a.id]
        XCTAssertNotNil(player, "armed player is kept")
        XCTAssertFalse(player!.started, "…but must not start while paused")
        transport.resumeAll()
        await wait(0.1)
        XCTAssertTrue(player!.started, "resume performs the deferred start")
        await wait(0.4)
        XCTAssertEqual(transport.registry.instances.count, 0, "then finishes normally")
    }

    // MARK: - Document switch resets transport

    func testTransportResetSilencesAndClearsPlayhead() async {
        let a = audioCue("1", duration: 5)
        show.cues = [a]
        transport.go()
        await wait(0.05)
        XCTAssertFalse(transport.registry.isEmpty)
        transport.reset()
        await wait(0.05)
        XCTAssertTrue(transport.registry.isEmpty)
        XCTAssertNil(transport.playheadID)
    }

    // MARK: - Cue list structure maintenance

    func testMoveCueIntoGroupAdoptsParent() {
        let document = ShowDocumentController()
        let group = Cue(number: "10", body: .group(GroupBody()))
        var c1 = Cue(number: "10.1", body: .stop(StopBody()))
        c1.parentID = group.id
        let loose = Cue(number: "1", body: .stop(StopBody()))
        document.mutate { $0.cues = [group, c1, loose] }

        // Move "loose" (index 2) to directly after the header (index 1).
        CueFactory.moveCues(in: document, from: IndexSet(integer: 2), to: 1)
        let moved = document.show.cue(withID: loose.id)
        XCTAssertEqual(moved?.parentID, group.id, "cue dropped under a header joins the group")
        // Invariant: children immediately follow their header.
        XCTAssertEqual(document.show.cues.map(\.number), ["10", "1", "10.1"])
    }

    func testMoveGroupHeaderKeepsChildrenAttached() {
        let document = ShowDocumentController()
        let group = Cue(number: "10", body: .group(GroupBody()))
        var c1 = Cue(number: "10.1", body: .stop(StopBody()))
        c1.parentID = group.id
        let after = Cue(number: "20", body: .stop(StopBody()))
        document.mutate { $0.cues = [group, c1, after] }

        // Drag the header below "20": the child block must travel with it.
        CueFactory.moveCues(in: document, from: IndexSet(integer: 0), to: 3)
        XCTAssertEqual(document.show.cues.map(\.number), ["20", "10", "10.1"])
        XCTAssertEqual(document.show.cue(withID: c1.id)?.parentID, group.id)
    }

    func testInsertAfterGroupHeaderLandsAfterChildBlock() {
        let document = ShowDocumentController()
        let group = Cue(number: "10", body: .group(GroupBody()))
        var c1 = Cue(number: "10.1", body: .stop(StopBody()))
        c1.parentID = group.id
        document.mutate { $0.cues = [group, c1] }
        document.selection = [group.id]

        let newCue = Cue(number: "11", body: .stop(StopBody()))
        CueFactory.insert(newCue, into: document)
        XCTAssertEqual(document.show.cues.map(\.number), ["10", "10.1", "11"],
                       "insert with a group selected lands after the whole block")
        XCTAssertNil(document.show.cues.last?.parentID)
    }
}
