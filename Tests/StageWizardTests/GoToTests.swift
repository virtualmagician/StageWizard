import XCTest
@testable import StageWizard

/// D31: the GoTo cue — moves the playhead to another cue, optionally firing
/// it. Covers the model (Codable round trip, stripped-key defaults) and the
/// runtime action (playhead movement, andFire's fire+advance, deleted/self
/// target guards, enter-group header resolution) via the Mock harness
/// (mirrors OSCSendTests'/MIDISendTests' Harness pattern).
///
/// Several tests deliberately place a DISTRACTOR cue between the GoTo cue
/// and its target in document order. Without that distractor, a bug where
/// `go()`'s own post-fire `advancePlayheadPastChain(from: theGoToCueItself)`
/// clobbers whatever the GoTo cue's arm just did to the playhead would pass
/// undetected purely by cue adjacency — see `TransportController.go()`'s
/// `goToRepositionedPlayhead` flag, which exists specifically to prevent that.
final class GoToTests: XCTestCase {

    // MARK: - Codable

    func testGoToBodyRoundTrips() throws {
        let body = GoToBody(targetID: UUID(), andFire: true)
        let cue = Cue(number: "1", body: .goTo(body))
        let data = try JSONEncoder().encode(cue)
        let decoded = try JSONDecoder().decode(Cue.self, from: data)
        XCTAssertEqual(decoded, cue)
    }

    func testGoToBodyDefaultsWhenKeysAreStripped() throws {
        let json = """
        {"type": "goTo"}
        """
        let decoded = try JSONDecoder().decode(CueBody.self, from: Data(json.utf8))
        guard case .goTo(let body) = decoded else {
            return XCTFail("expected .goTo, got \(decoded)")
        }
        XCTAssertNil(body.targetID)
        XCTAssertFalse(body.andFire)
    }

    func testGoToDefaultNameIsConstant() {
        XCTAssertEqual(CueBody.goTo(GoToBody()).defaultName, "Go To")
        XCTAssertEqual(CueBody.goTo(GoToBody(targetID: UUID(), andFire: true)).defaultName, "Go To")
    }

    /// Forward-compat pin, same shape as OSCSendTests' — confirms the
    /// decoder's unknown-type fallback still works for a type string that
    /// isn't "goTo" after adding this type.
    func testUnrelatedUnknownTypeStillDecodesToBrokenAfterAddingGoTo() throws {
        let json = """
        {"type": "goToFromTheFuture"}
        """
        let decoded = try JSONDecoder().decode(CueBody.self, from: Data(json.utf8))
        guard case .broken(let body) = decoded else {
            return XCTFail("expected .broken, got \(decoded)")
        }
        XCTAssertEqual(body.originalType, "goToFromTheFuture")
    }

    // MARK: - Runtime harness (mirrors OSCSendTests'/MIDISendTests' Harness pattern)

    @MainActor
    private final class Harness {
        var show = ShowFile()
        let provider = MockProvider()
        var transport: TransportController!
        private(set) var warnings: [String] = []

        init() {
            transport = TransportController(
                provider: provider,
                show: { [unowned self] in self.show },
                showFolder: { nil }
            )
            transport.onOperatorWarning = { [weak self] message in self?.warnings.append(message) }
        }

        func wait(_ seconds: TimeInterval) async {
            try? await Task.sleep(for: .seconds(seconds))
        }
    }

    private func audioCue(_ number: String) -> Cue {
        Cue(number: number, body: .audio(AudioBody(media: MediaReference(absolutePath: "/fake/\(number).wav"))))
    }

    // MARK: - Plain (no andFire): playhead moves, nothing fires

    @MainActor
    func testGoToMovesPlayheadWithoutFiring() async {
        let harness = Harness()
        let distractor = audioCue("2")
        let target = audioCue("3")
        let goTo = Cue(number: "1", body: .goTo(GoToBody(targetID: target.id, andFire: false)))
        harness.show.cues = [goTo, distractor, target]
        harness.transport.go()
        await harness.wait(0.05)
        XCTAssertEqual(
            harness.transport.standingByCue?.id, target.id,
            "the playhead must land on the target, not on the distractor sitting right after the GoTo cue"
        )
        XCTAssertEqual(harness.provider.players.count, 0, "without andFire, the target must never be armed/fired")
        XCTAssertTrue(harness.warnings.isEmpty)
    }

    @MainActor
    func testGoToCueItselfCompletesInstantlyLikeAStopCue() async {
        let harness = Harness()
        let target = audioCue("2")
        let goTo = Cue(number: "1", body: .goTo(GoToBody(targetID: target.id)))
        harness.show.cues = [goTo, target]
        harness.transport.go()
        await harness.wait(0.05)
        XCTAssertEqual(harness.transport.registry.instances.count, 0, "a GoTo cue must not linger in the active-cues registry")
    }

    // MARK: - andFire: fires exactly once, playhead advances past the fired chain

    @MainActor
    func testAndFireFiresTargetExactlyOnceAndAdvancesPlayheadPastIt() async {
        let harness = Harness()
        let distractor = audioCue("2")
        let target = audioCue("3")
        let after = audioCue("4")
        let goTo = Cue(number: "1", body: .goTo(GoToBody(targetID: target.id, andFire: true)))
        harness.show.cues = [goTo, distractor, target, after]
        harness.transport.go()
        await harness.wait(0.05)
        XCTAssertEqual(harness.provider.players.count, 1, "andFire must fire the target exactly once")
        XCTAssertNotNil(harness.provider.players[target.id])
        XCTAssertNil(harness.provider.players[distractor.id], "the distractor sitting between the GoTo cue and its target must never fire")
        XCTAssertEqual(
            harness.transport.playheadID, after.id,
            "GO past the fired target must land on the cue AFTER it, mirroring go()'s own chain advance — " +
            "NOT on the distractor that happens to sit right after the GoTo cue itself"
        )
    }

    @MainActor
    func testAndFireOffLeavesPlayheadOnTargetWithoutAdvancing() async {
        let harness = Harness()
        let distractor = audioCue("2")
        let target = audioCue("3")
        let goTo = Cue(number: "1", body: .goTo(GoToBody(targetID: target.id, andFire: false)))
        harness.show.cues = [goTo, distractor, target]
        harness.transport.go()
        await harness.wait(0.05)
        XCTAssertEqual(
            harness.transport.playheadID, target.id,
            "without andFire the playhead simply stands by the target, not the distractor"
        )
    }

    // MARK: - Guards: nil / deleted / self target

    @MainActor
    func testDeletedTargetWarnsAndDoesNotMovePlayheadButGOStillAdvancesPastTheInertCue() async {
        let harness = Harness()
        let goTo = Cue(number: "1", body: .goTo(GoToBody(targetID: UUID(), andFire: true)))
        let after = audioCue("2")
        harness.show.cues = [goTo, after]
        harness.transport.go()
        await harness.wait(0.05)
        XCTAssertEqual(harness.warnings.count, 1)
        XCTAssertTrue(harness.warnings.first?.contains("no longer exists") ?? false)
        XCTAssertEqual(harness.provider.players.count, 0, "a deleted target must never be armed/fired")
        // A deleted target never touches the playhead itself, so GO's
        // generic "advance past this inert action cue" logic still applies
        // — exactly like any other warned no-op action cue (OSC/MIDI empty
        // config): the show never gets stuck.
        XCTAssertEqual(harness.transport.playheadID, after.id)
    }

    @MainActor
    func testNilTargetWarnsAndDoesNotMovePlayhead() async {
        let harness = Harness()
        let goTo = Cue(number: "1", body: .goTo(GoToBody(targetID: nil, andFire: false)))
        harness.show.cues = [goTo]
        harness.transport.go()
        await harness.wait(0.05)
        XCTAssertEqual(harness.warnings.count, 1)
        XCTAssertTrue(harness.warnings.first?.contains("no target assigned") ?? false)
    }

    @MainActor
    func testSelfTargetWarnsNeverFiresButGOStillAdvancesPastTheInertCue() async {
        let harness = Harness()
        var goTo = Cue(number: "1", body: .goTo(GoToBody(andFire: true)))
        goTo.body = .goTo(GoToBody(targetID: goTo.id, andFire: true))
        let after = audioCue("2")
        harness.show.cues = [goTo, after]
        harness.transport.go()
        await harness.wait(0.05)
        XCTAssertEqual(harness.warnings.count, 1)
        XCTAssertTrue(harness.warnings.first?.contains("target is this cue") ?? false)
        XCTAssertEqual(harness.provider.players.count, 0, "a self-target must never fire — that would be an infinite GO loop")
        // Same "never gets stuck" rule as the deleted-target case: refusing
        // the self-target doesn't touch the playhead, so GO's generic
        // advance still moves past this (now inert) cue.
        XCTAssertEqual(harness.transport.playheadID, after.id)
    }

    // MARK: - Enter-group header resolution

    @MainActor
    func testAndFireOnEnterGroupHeaderResolvesToFirstChildLikeSetPlayhead() async {
        let harness = Harness()
        let distractor = audioCue("2")
        let header = Cue(number: "3", body: .group(GroupBody(mode: .enterAndPlayFirst)))
        let child1 = { var c = audioCue("3.1"); c.parentID = header.id; return c }()
        let child2 = { var c = audioCue("3.2"); c.parentID = header.id; return c }()
        let after = audioCue("4")
        let goTo = Cue(number: "1", body: .goTo(GoToBody(targetID: header.id, andFire: true)))
        harness.show.cues = [goTo, distractor, header, child1, child2, after]
        harness.transport.go()
        await harness.wait(0.05)
        XCTAssertNotNil(harness.provider.players[child1.id], "andFire on a group header must fire its FIRST CHILD, not the header")
        XCTAssertNil(harness.provider.players[header.id])
        XCTAssertNil(harness.provider.players[distractor.id])
        // The GO sequence walks INTO the group and out its far side (see
        // TransportController.goSequence); the far side of a two-child
        // enter-and-play-first group whose first child just fired is its
        // second child — NOT the distractor sitting right after the GoTo cue.
        XCTAssertEqual(harness.transport.playheadID, child2.id)
    }

    // MARK: - D31 fix: cycle/depth guard, nested-GoTo flag semantics, un-placeable targets

    /// Mutual andFire GoTos (A → B → A → …) recurse synchronously with no
    /// guard — this pins the fix: the SECOND time a GoTo cue's id reappears
    /// in the active chain, `performGoTo` warns and stops instead of
    /// overflowing the stack. Exactly one warning, and the playhead ends up
    /// somewhere sane (never left standing on the looping pair).
    @MainActor
    func testMutualAndFireGoTosDoNotCrashAndStopAfterExactlyOneLoopWarning() async {
        let harness = Harness()
        var a = Cue(number: "1", body: .goTo(GoToBody(andFire: true)))
        var b = Cue(number: "2", body: .goTo(GoToBody(andFire: true)))
        a.body = .goTo(GoToBody(targetID: b.id, andFire: true))
        b.body = .goTo(GoToBody(targetID: a.id, andFire: true))
        harness.show.cues = [a, b]
        harness.transport.go()
        await harness.wait(0.05)
        XCTAssertEqual(harness.warnings.count, 1, "exactly one loop warning: \(harness.warnings)")
        XCTAssertTrue(harness.warnings.first?.contains("loop detected") ?? false)
        XCTAssertEqual(harness.transport.playheadID, b.id, "the chain must stop and land somewhere sane, not crash or stick on the looping pair")
        XCTAssertEqual(harness.transport.registry.instances.count, 0, "every GoTo instance in the aborted cascade must still terminate cleanly")
    }

    /// The header-self case from the audit: a GoTo that is the FIRST CHILD of
    /// an enter-and-play-first group, targeting its own parent header.
    /// `resolveGOTarget` resolves the header back to that same first child —
    /// i.e. the GoTo cue itself — so the id-differs self-guard alone can't
    /// catch it; only the chain guard does.
    @MainActor
    func testAndFireGoToTargetingItsOwnEnterGroupHeaderWarnsAndDoesNotCrash() async {
        let harness = Harness()
        let header = Cue(number: "1", body: .group(GroupBody(mode: .enterAndPlayFirst)))
        var firstChild = { var c = audioCue("1.1"); c.parentID = header.id; return c }()
        firstChild.body = .goTo(GoToBody(targetID: header.id, andFire: true))
        let secondChild = { var c = audioCue("1.2"); c.parentID = header.id; return c }()
        harness.show.cues = [header, firstChild, secondChild]
        harness.transport.go()
        await harness.wait(0.05)
        XCTAssertEqual(harness.warnings.count, 1, "exactly one loop warning: \(harness.warnings)")
        XCTAssertTrue(harness.warnings.first?.contains("loop detected") ?? false)
        XCTAssertEqual(
            harness.transport.playheadID, secondChild.id,
            "GO must still advance past the (now inert) self-looping GoTo, into the far side of the group"
        )
        XCTAssertEqual(harness.transport.registry.instances.count, 0)
    }

    /// A legitimate, non-cyclic chain of THREE distinct andFire GoTos must
    /// still work end-to-end — the loop/depth guard must never trip on
    /// ordinary chained navigation, only on genuine re-entrancy.
    @MainActor
    func testLegitimateChainOfThreeDistinctGoTosStillWorksEndToEnd() async {
        let harness = Harness()
        let afterGoTo1 = audioCue("d1")
        let afterGoTo2 = audioCue("d2")
        let afterGoTo3 = audioCue("d3")
        let target = audioCue("4")
        let after = audioCue("5")
        var goTo3 = Cue(number: "3", body: .goTo(GoToBody(andFire: true)))
        goTo3.body = .goTo(GoToBody(targetID: target.id, andFire: true))
        var goTo2 = Cue(number: "2", body: .goTo(GoToBody(andFire: true)))
        goTo2.body = .goTo(GoToBody(targetID: goTo3.id, andFire: true))
        var goTo1 = Cue(number: "1", body: .goTo(GoToBody(andFire: true)))
        goTo1.body = .goTo(GoToBody(targetID: goTo2.id, andFire: true))
        harness.show.cues = [goTo1, afterGoTo1, goTo2, afterGoTo2, goTo3, afterGoTo3, target, after]
        harness.transport.go()
        await harness.wait(0.05)
        XCTAssertTrue(harness.warnings.isEmpty, "a legitimate non-cyclic chain must never warn: \(harness.warnings)")
        XCTAssertNotNil(harness.provider.players[target.id], "the chain must actually fire the final target exactly once")
        XCTAssertNil(harness.provider.players[afterGoTo1.id])
        XCTAssertNil(harness.provider.players[afterGoTo2.id])
        XCTAssertNil(harness.provider.players[afterGoTo3.id])
        XCTAssertEqual(
            harness.transport.playheadID, after.id,
            "the playhead must land on the cue after the FINAL fired target, not any distractor along the chain"
        )
    }

    /// D31 fix3: reentrant GoTo→andFire→GoTo must not let the OUTER
    /// performGoTo's generic chain-advance clobber the INNER GoTo's own
    /// jump. A distractor sits right after B in document order so a bug
    /// where A's advance overwrites B's jump is caught (without it, both
    /// the buggy and fixed code would coincidentally land on the same cue).
    @MainActor
    func testInnerGoToRepositioningWinsOverOuterChainAdvance() async {
        let harness = Harness()
        let afterA = audioCue("d1")
        let afterB = audioCue("d2")
        let c = audioCue("4")
        var b = Cue(number: "2", body: .goTo(GoToBody(andFire: false)))
        b.body = .goTo(GoToBody(targetID: c.id, andFire: false))
        var a = Cue(number: "1", body: .goTo(GoToBody(andFire: true)))
        a.body = .goTo(GoToBody(targetID: b.id, andFire: true))
        harness.show.cues = [a, afterA, b, afterB, c]
        harness.transport.go()
        await harness.wait(0.05)
        XCTAssertTrue(harness.warnings.isEmpty, "a legitimate nested GoTo must never warn: \(harness.warnings)")
        XCTAssertEqual(
            harness.transport.standingByCue?.id, c.id,
            "B's own jump to C must win — A's outer generic chain-advance (which would otherwise land on the " +
            "distractor sitting right after B in document order) must be skipped once the inner GoTo already " +
            "repositioned the playhead"
        )
    }

    /// D31 fix4: a target that EXISTS but isn't a GO-able position (a
    /// fireAll group's child) must not silently stick the playhead on the
    /// GoTo cue — it must warn, and GO must still advance past the (now
    /// inert) GoTo cue exactly like any other warned no-op.
    @MainActor
    func testGoToTargetingAFireAllGroupChildWarnsAndGOStillAdvancesNormally() async {
        let harness = Harness()
        let group = Cue(number: "2", body: .group(GroupBody(mode: .fireAll)))
        let child = { var c = audioCue("2.1"); c.parentID = group.id; return c }()
        let after = audioCue("3")
        var goTo = Cue(number: "1", body: .goTo(GoToBody(andFire: true)))
        goTo.body = .goTo(GoToBody(targetID: child.id, andFire: true))
        harness.show.cues = [goTo, group, child, after]
        harness.transport.go()
        await harness.wait(0.05)
        XCTAssertEqual(harness.warnings.count, 1)
        XCTAssertTrue(harness.warnings.first?.contains("isn't a GO position") ?? false)
        XCTAssertEqual(harness.provider.players.count, 0, "the un-placeable target must never be armed/fired")
        XCTAssertEqual(
            harness.transport.playheadID, group.id,
            "GO must still advance past the (now inert) GoTo cue normally — the group header, " +
            "not the un-placeable child, is next in the GO sequence"
        )
    }

    // MARK: - Never blocks GO / honors preWait

    @MainActor
    func testGoToNeverBlocksGOAdvancingPastItself() async {
        let harness = Harness()
        let a = Cue(number: "1", body: .goTo(GoToBody()))
        let b = audioCue("2")
        harness.show.cues = [a, b]
        harness.transport.go()
        XCTAssertEqual(harness.transport.playheadID, b.id, "GO must advance past an instant, unconfigured GoTo cue synchronously")
    }

    /// A pre-waiting GoTo cue's own `begin()` only SCHEDULES the action (an
    /// async Task) and returns immediately — `go()`'s generic post-fire
    /// advance (see the `goToRepositionedPlayhead` flag) has already run by
    /// then, since the arm hasn't executed yet, so the playhead transiently
    /// lands on the DISTRACTOR (document-order "next cue"), same as it would
    /// for any other cue type with a pre-wait. Once the pre-wait elapses,
    /// `performGoTo` actually runs and corrects the playhead to the real target.
    @MainActor
    func testPreWaitIsHonoredBeforeMovingThePlayhead() async {
        let harness = Harness()
        let distractor = audioCue("2")
        let target = audioCue("3")
        let goTo = Cue(number: "1", preWait: 0.25, body: .goTo(GoToBody(targetID: target.id)))
        harness.show.cues = [goTo, distractor, target]
        harness.transport.go()
        await harness.wait(0.1)
        XCTAssertEqual(
            harness.transport.standingByCue?.id, distractor.id,
            "before the pre-wait elapses the playhead sits at the generic document-order next cue"
        )
        await harness.wait(0.3)
        XCTAssertEqual(harness.transport.standingByCue?.id, target.id, "the real target takes over once the pre-wait has elapsed")
    }
}
