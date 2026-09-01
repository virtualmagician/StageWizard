import XCTest
@testable import StageWizard

/// D21: StageWand hardware-controller handoff — outbound OSC status
/// feedback (pure encoder round-trip, the subscriber registry, snapshot
/// diffing, GO-sequence window computation) plus the new inbound
/// `/stagewizard/cue/{number}/select` address at the transport level.
///
/// Deliberately does NOT bind a real UDP socket (same discipline as
/// OSCTests.swift, CI/sandbox flakiness) — every type under test here
/// (`OSCServer.encode`, `OSCSubscriberRegistry`, `OSCStatusFeedback`) is pure
/// and value-typed for exactly this reason.
@MainActor
final class OSCFeedbackTests: XCTestCase {

    // MARK: - Encoder round-trip: parse(encode(x)) == [x]

    func testEncodeNoArgsRoundTrips() {
        let data = OSCServer.encode(address: "/stagewizard/go", arguments: [])
        XCTAssertEqual(OSCServer.parse(data), [OSCMessage(address: "/stagewizard/go", arguments: [])])
    }

    func testEncodeInt32RoundTrips() {
        for value: Int32 in [0, 1, -1, 42, Int32.min, Int32.max] {
            let data = OSCServer.encode(address: "/stagewizard/status/running", arguments: [.int32(value)])
            XCTAssertEqual(
                OSCServer.parse(data),
                [OSCMessage(address: "/stagewizard/status/running", arguments: [.int32(value)])],
                "value \(value)"
            )
        }
    }

    func testEncodeFloat32RoundTrips() {
        for value: Float in [0, 1.5, -3.25, 123456.75, .greatestFiniteMagnitude, -1] {
            let data = OSCServer.encode(address: "/stagewizard/status/elapsed", arguments: [.float32(value)])
            XCTAssertEqual(
                OSCServer.parse(data),
                [OSCMessage(address: "/stagewizard/status/elapsed", arguments: [.float32(value)])],
                "value \(value)"
            )
        }
    }

    func testEncodeStringRoundTrips() {
        let data = OSCServer.encode(address: "/stagewizard/status/notes", arguments: [.string("hello")])
        XCTAssertEqual(OSCServer.parse(data), [OSCMessage(address: "/stagewizard/status/notes", arguments: [.string("hello")])])
    }

    func testEncodeMultibyteStringRoundTrips() {
        let data = OSCServer.encode(address: "/stagewizard/status/notes", arguments: [.string("café — 日本語")])
        XCTAssertEqual(OSCServer.parse(data), [OSCMessage(address: "/stagewizard/status/notes", arguments: [.string("café — 日本語")])])
    }

    func testEncodeEmptyStringRoundTrips() {
        let data = OSCServer.encode(address: "/stagewizard/status/standingby", arguments: [.string(""), .string("")])
        XCTAssertEqual(
            OSCServer.parse(data),
            [OSCMessage(address: "/stagewizard/status/standingby", arguments: [.string(""), .string("")])]
        )
    }

    func testEncodeMultiArgMixedTypesRoundTrips() {
        let args: [OSCArgument] = [.int32(3), .int32(12), .string("2"), .string("Blackout"), .string("4"), .string("Rain")]
        let data = OSCServer.encode(address: "/stagewizard/status/window", arguments: args)
        XCTAssertEqual(OSCServer.parse(data), [OSCMessage(address: "/stagewizard/status/window", arguments: args)])
    }

    /// Padding correctness across every address length 1...8 — OSC strings
    /// pad to a 4-byte boundary regardless of where the null terminator
    /// falls, so this exercises all four possible remainders twice over.
    func testEncodeRoundTripsForEveryAddressLength1Through8() {
        for length in 1...8 {
            let address = "/" + String(repeating: "a", count: length - 1)
            let data = OSCServer.encode(address: address, arguments: [.int32(7)])
            XCTAssertEqual(
                OSCServer.parse(data), [OSCMessage(address: address, arguments: [.int32(7)])],
                "address length \(length)"
            )
        }
    }

    // MARK: - Subscriber registry (pure, generic — fake clock, no sockets)

    func testNewSubscriberIsReportedOnceThenNotOnRepeat() {
        let clock: TimeInterval = 0
        var registry = OSCSubscriberRegistry<String>(now: { clock })
        XCTAssertTrue(registry.touch("wand"), "first contact must report as a new subscriber")
        XCTAssertFalse(registry.touch("wand"), "a repeat datagram from the same endpoint is not new")
    }

    func testSubscriberStillLiveWithinFiveSecondWindow() {
        var clock: TimeInterval = 0
        var registry = OSCSubscriberRegistry<String>(now: { clock })
        _ = registry.touch("wand")
        clock += 4
        XCTAssertEqual(registry.liveEndpoints(), ["wand"], "4s of silence is still inside the 5s window")
    }

    func testSilentSixSecondsPrunesTheSubscriber() {
        var clock: TimeInterval = 0
        var registry = OSCSubscriberRegistry<String>(now: { clock })
        _ = registry.touch("wand")
        clock += 6
        XCTAssertTrue(registry.liveEndpoints().isEmpty, "6s of silence exceeds the 5s timeout")
    }

    func testPingAfterPruneIsReportedAsANewSubscriberAgain() {
        var clock: TimeInterval = 0
        var registry = OSCSubscriberRegistry<String>(now: { clock })
        _ = registry.touch("wand")
        clock += 6   // goes stale and gets pruned
        XCTAssertTrue(registry.touch("wand"), "a return after pruning must trigger a fresh full refresh")
    }

    func testMultipleSubscribersArePrunedIndependently() {
        var clock: TimeInterval = 0
        var registry = OSCSubscriberRegistry<String>(now: { clock })
        _ = registry.touch("wand")
        clock += 3
        _ = registry.touch("phone")
        clock += 3   // wand is now 6s stale, phone only 3s
        XCTAssertEqual(registry.liveEndpoints(), ["phone"])
    }

    // MARK: - OSCStatusFeedback.changedMessages

    private func snapshot(
        standingByNumber: String = "3", standingByName: String = "Blackout",
        notes: String = "", runningCount: Int = 0, panic: Bool = false, showMode: Bool = false,
        windowIndex: Int = 2, windowTotal: Int = 5,
        prevNum: String = "2", prevName: String = "Fade up", nextNum: String = "4", nextName: String = "Rain",
        cuelist: [OSCStatusFeedback.CueListEntry] = []
    ) -> OSCStatusFeedback.Snapshot {
        OSCStatusFeedback.Snapshot(
            standingByNumber: standingByNumber, standingByName: standingByName, notes: notes,
            runningCount: runningCount, panic: panic, showMode: showMode,
            windowIndex: windowIndex, windowTotal: windowTotal,
            prevNum: prevNum, prevName: prevName, nextNum: nextNum, nextName: nextName,
            cuelist: cuelist
        )
    }

    func testNilOldSnapshotSendsEveryAddress() {
        // Default snapshot() has an EMPTY cuelist, so the D22 burst still
        // fires (old == nil means "everything") but degenerates to just
        // begin(0)/end(0) — no item messages.
        let messages = OSCStatusFeedback.changedMessages(old: nil, new: snapshot())
        XCTAssertEqual(Set(messages.map(\.address)), [
            "/stagewizard/status/standingby", "/stagewizard/status/running", "/stagewizard/status/panic",
            "/stagewizard/status/showmode", "/stagewizard/status/window", "/stagewizard/status/notes",
            "/stagewizard/cuelist/begin", "/stagewizard/cuelist/end",
        ])
    }

    func testUnchangedSnapshotSendsNothing() {
        let s = snapshot()
        XCTAssertTrue(OSCStatusFeedback.changedMessages(old: s, new: s).isEmpty)
    }

    func testSingleFieldChangeSendsExactlyThatAddress() {
        let old = snapshot(panic: false)
        let new = snapshot(panic: true)
        XCTAssertEqual(
            OSCStatusFeedback.changedMessages(old: old, new: new),
            [OSCMessage(address: "/stagewizard/status/panic", arguments: [.int32(1)])]
        )
    }

    func testRunningCountChangeSendsOnlyRunningAddress() {
        let old = snapshot(runningCount: 0)
        let new = snapshot(runningCount: 2)
        XCTAssertEqual(
            OSCStatusFeedback.changedMessages(old: old, new: new),
            [OSCMessage(address: "/stagewizard/status/running", arguments: [.int32(2)])]
        )
    }

    func testWindowFieldsGroupIntoOneMessage() {
        let old = snapshot(windowIndex: 2, nextNum: "4", nextName: "Rain")
        let new = snapshot(windowIndex: 3, nextNum: "5", nextName: "Storm")
        let messages = OSCStatusFeedback.changedMessages(old: old, new: new)
        XCTAssertEqual(messages.count, 1, "all four window fields must collapse into ONE message")
        XCTAssertEqual(messages.first?.address, "/stagewizard/status/window")
        XCTAssertEqual(messages.first?.arguments, [
            .int32(3), .int32(5), .string("2"), .string("Fade up"), .string("5"), .string("Storm"),
        ])
    }

    func testEmptyStandingByEncodesEmptyStrings() {
        let messages = OSCStatusFeedback.changedMessages(old: nil, new: snapshot(standingByNumber: "", standingByName: ""))
        let standingBy = messages.first { $0.address == "/stagewizard/status/standingby" }
        XCTAssertEqual(standingBy?.arguments, [.string(""), .string("")])
    }

    func testShowModeAndNotesChangesEachSendTheirOwnAddress() {
        let old = snapshot(notes: "old note", showMode: false)
        let new = snapshot(notes: "new note", showMode: true)
        XCTAssertEqual(
            Set(OSCStatusFeedback.changedMessages(old: old, new: new).map(\.address)),
            ["/stagewizard/status/notes", "/stagewizard/status/showmode"]
        )
    }

    // MARK: - D22: liveness heartbeat (OSCStatusFeedback.shouldSendHeartbeat)
    //
    // Pure tick-index arithmetic — no AppModel, no feedback loop. AppModel's
    // own `oscFeedbackTick` just calls this with its running tick counter and
    // whether THIS tick's diff already emitted a genuine running-count change.

    func testHeartbeatFiresOnEveryTwentiethTick() {
        for tick in [20, 40, 60, 100] {
            XCTAssertTrue(
                OSCStatusFeedback.shouldSendHeartbeat(tickCount: tick, runningAlreadySentThisTick: false),
                "tick \(tick) should be a heartbeat tick"
            )
        }
    }

    func testHeartbeatDoesNotFireOnNonHeartbeatTicks() {
        for tick in [1, 5, 10, 15, 19, 21, 39] {
            XCTAssertFalse(
                OSCStatusFeedback.shouldSendHeartbeat(tickCount: tick, runningAlreadySentThisTick: false),
                "tick \(tick) is not a multiple of the heartbeat divisor"
            )
        }
    }

    func testHeartbeatSuppressedWhenRunningAlreadySentThisTick() {
        XCTAssertFalse(
            OSCStatusFeedback.shouldSendHeartbeat(tickCount: 20, runningAlreadySentThisTick: true),
            "a genuine running-count change this tick must not be doubled by the heartbeat"
        )
    }

    func testHeartbeatDivisorIsTwentyTicksPerTheWireContract() {
        // 10 Hz feedback tick / 20 = one heartbeat every ~2s, per the D22 ask.
        XCTAssertEqual(OSCStatusFeedback.heartbeatTickDivisor, 20)
    }

    // MARK: - D22: OSCStatusFeedback.cuelistMessages (pure burst construction)

    func testCuelistMessagesEmptyListSendsBeginAndEndWithZeroCountNoItems() {
        let messages = OSCStatusFeedback.cuelistMessages([])
        XCTAssertEqual(messages, [
            OSCMessage(address: "/stagewizard/cuelist/begin", arguments: [.int32(0)]),
            OSCMessage(address: "/stagewizard/cuelist/end", arguments: [.int32(0)]),
        ])
    }

    func testCuelistMessagesThreeCuesOrderedWithZeroBasedIndices() {
        let entries = [
            OSCStatusFeedback.CueListEntry(number: "1", name: "Blackout"),
            OSCStatusFeedback.CueListEntry(number: "2", name: "Fade up"),
            OSCStatusFeedback.CueListEntry(number: "3", name: "Rain"),
        ]
        let messages = OSCStatusFeedback.cuelistMessages(entries)
        XCTAssertEqual(messages, [
            OSCMessage(address: "/stagewizard/cuelist/begin", arguments: [.int32(3)]),
            OSCMessage(address: "/stagewizard/cuelist/item", arguments: [.int32(0), .string("1"), .string("Blackout"), .string("")]),
            OSCMessage(address: "/stagewizard/cuelist/item", arguments: [.int32(1), .string("2"), .string("Fade up"), .string("")]),
            OSCMessage(address: "/stagewizard/cuelist/item", arguments: [.int32(2), .string("3"), .string("Rain"), .string("")]),
            OSCMessage(address: "/stagewizard/cuelist/end", arguments: [.int32(3)]),
        ])
    }

    func testCuelistItemCarriesTheColorTagAsOptionalTrailingArg() {
        // StageWand ask (2026-09-01): tag verbatim, empty when untagged —
        // wands parse positionally, old firmware ignores the 4th arg.
        let entries = [
            OSCStatusFeedback.CueListEntry(number: "10", name: "Opening", colorTag: "crimson"),
            OSCStatusFeedback.CueListEntry(number: "20", name: "Drones"),
        ]
        let messages = OSCStatusFeedback.cuelistMessages(entries)
        XCTAssertEqual(messages[1].arguments, [.int32(0), .string("10"), .string("Opening"), .string("crimson")])
        XCTAssertEqual(messages[2].arguments, [.int32(1), .string("20"), .string("Drones"), .string("")])
    }

    func testCuelistEntriesCarryTheCueColorTag() {
        var tagged = Cue(number: "1", body: .stop(StopBody()))
        tagged.colorTag = "sky"
        let untagged = Cue(number: "2", body: .stop(StopBody()))
        let entries = OSCStatusFeedback.cuelistEntries(goSequence: [tagged, untagged])
        XCTAssertEqual(entries.map(\.colorTag), ["sky", ""])
    }

    func testColorTagChangeAloneTriggersACuelistReburst() {
        var old = snapshot()
        old.cuelist = [OSCStatusFeedback.CueListEntry(number: "1", name: "Same")]
        var new = old
        new.cuelist = [OSCStatusFeedback.CueListEntry(number: "1", name: "Same", colorTag: "navy")]
        let messages = OSCStatusFeedback.changedMessages(old: old, new: new)
        XCTAssertTrue(messages.contains { $0.address == "/stagewizard/cuelist/begin" },
                      "a tag change re-bursts the list, same as a rename")
    }

    func testCuelistMessagesCapsAtSixtyFourEntries() {
        let entries = (0..<70).map { OSCStatusFeedback.CueListEntry(number: "\($0 + 1)", name: "Cue \($0 + 1)") }
        let messages = OSCStatusFeedback.cuelistMessages(entries)

        XCTAssertEqual(messages.first, OSCMessage(address: "/stagewizard/cuelist/begin", arguments: [.int32(64)]))
        XCTAssertEqual(messages.last, OSCMessage(address: "/stagewizard/cuelist/end", arguments: [.int32(64)]))

        let items = messages.filter { $0.address == "/stagewizard/cuelist/item" }
        XCTAssertEqual(items.count, 64, "must truncate to the FIRST 64 cues")
        XCTAssertEqual(items.first?.arguments, [.int32(0), .string("1"), .string("Cue 1"), .string("")])
        XCTAssertEqual(items.last?.arguments, [.int32(63), .string("64"), .string("Cue 64"), .string("")], "the 65th+ cue must never appear")
    }

    // MARK: - D22: OSCStatusFeedback.cuelistEntries (GO sequence → capped entries, pure)

    func testCuelistEntriesMapsNumberAndDisplayName() {
        let a = Cue(number: "1", name: "Blackout", body: .audio(AudioBody(media: MediaReference(absolutePath: "/fake/1.wav"))))
        let b = cue("2")
        let entries = OSCStatusFeedback.cuelistEntries(goSequence: [a, b])
        XCTAssertEqual(entries, [
            OSCStatusFeedback.CueListEntry(number: "1", name: "Blackout"),
            OSCStatusFeedback.CueListEntry(number: "2", name: b.displayName),
        ])
    }

    func testCuelistEntriesCapsAtSixtyFour() {
        let cues = (0..<70).map { cue("\($0 + 1)") }
        XCTAssertEqual(OSCStatusFeedback.cuelistEntries(goSequence: cues).count, 64)
    }

    // MARK: - D22: Snapshot diff — the cue-list burst rides changedMessages

    func testCuelistRenameTriggersBurst() {
        let old = snapshot(cuelist: [OSCStatusFeedback.CueListEntry(number: "1", name: "Blackout")])
        let new = snapshot(cuelist: [OSCStatusFeedback.CueListEntry(number: "1", name: "Blackout (v2)")])
        XCTAssertTrue(OSCStatusFeedback.changedMessages(old: old, new: new).contains { $0.address == "/stagewizard/cuelist/begin" })
    }

    func testCuelistAddTriggersBurst() {
        let old = snapshot(cuelist: [OSCStatusFeedback.CueListEntry(number: "1", name: "Blackout")])
        let new = snapshot(cuelist: [
            OSCStatusFeedback.CueListEntry(number: "1", name: "Blackout"),
            OSCStatusFeedback.CueListEntry(number: "2", name: "Rain"),
        ])
        XCTAssertTrue(OSCStatusFeedback.changedMessages(old: old, new: new).contains { $0.address == "/stagewizard/cuelist/begin" })
    }

    func testCuelistReorderTriggersBurst() {
        let a = OSCStatusFeedback.CueListEntry(number: "1", name: "Blackout")
        let b = OSCStatusFeedback.CueListEntry(number: "2", name: "Rain")
        let old = snapshot(cuelist: [a, b])
        let new = snapshot(cuelist: [b, a])
        XCTAssertTrue(OSCStatusFeedback.changedMessages(old: old, new: new).contains { $0.address == "/stagewizard/cuelist/begin" })
    }

    func testUnchangedCuelistSendsNoBurst() {
        let list = [OSCStatusFeedback.CueListEntry(number: "1", name: "Blackout")]
        let s = snapshot(cuelist: list)
        XCTAssertTrue(OSCStatusFeedback.changedMessages(old: s, new: s).isEmpty)
    }

    func testFullRefreshIncludesCuelistBurstAfterStatusMessages() {
        let list = [
            OSCStatusFeedback.CueListEntry(number: "1", name: "Blackout"),
            OSCStatusFeedback.CueListEntry(number: "2", name: "Rain"),
        ]
        let messages = OSCStatusFeedback.changedMessages(old: nil, new: snapshot(cuelist: list))

        let statusAddresses = [
            "/stagewizard/status/standingby", "/stagewizard/status/running", "/stagewizard/status/panic",
            "/stagewizard/status/showmode", "/stagewizard/status/window", "/stagewizard/status/notes",
        ]
        XCTAssertEqual(
            Array(messages.prefix(6).map(\.address)), statusAddresses,
            "status messages must come first, in their fixed order"
        )
        XCTAssertEqual(
            Array(messages.suffix(from: 6)).map(\.address),
            ["/stagewizard/cuelist/begin", "/stagewizard/cuelist/item", "/stagewizard/cuelist/item", "/stagewizard/cuelist/end"],
            "the D22 burst must follow every status message, in begin -> items -> end order"
        )
    }

    // MARK: - OSCStatusFeedback.elapsedMessage

    func testElapsedMessageEncodesKnownDuration() {
        XCTAssertEqual(
            OSCStatusFeedback.elapsedMessage(elapsed: 12.5, duration: 30),
            OSCMessage(address: "/stagewizard/status/elapsed", arguments: [.float32(12.5), .float32(30)])
        )
    }

    func testElapsedMessageEncodesIndefiniteDurationAsNegativeOne() {
        XCTAssertEqual(
            OSCStatusFeedback.elapsedMessage(elapsed: 4, duration: nil),
            OSCMessage(address: "/stagewizard/status/elapsed", arguments: [.float32(4), .float32(-1)])
        )
    }

    // MARK: - OSCStatusFeedback.windowInfo (pure: goSequence + playhead → index/total/prev/next)

    private func cue(_ number: String) -> Cue {
        Cue(number: number, body: .audio(AudioBody(media: MediaReference(absolutePath: "/fake/\(number).wav"))))
    }

    func testWindowInfoEmptyShow() {
        let info = OSCStatusFeedback.windowInfo(goSequence: [], standingByID: nil)
        XCTAssertEqual(info, OSCStatusFeedback.WindowInfo(index: -1, total: 0, prevNum: "", prevName: "", nextNum: "", nextName: ""))
    }

    /// A nil standing-by id with a NON-empty sequence is what
    /// `TransportController.standingByCue` also returns once the playhead
    /// has run past the end of the show — total still reflects the full
    /// sequence length even though nothing currently stands by.
    func testWindowInfoPastEndOrNothingStandingBy() {
        let info = OSCStatusFeedback.windowInfo(goSequence: [cue("1"), cue("2")], standingByID: nil)
        XCTAssertEqual(info.index, -1)
        XCTAssertEqual(info.total, 2)
        XCTAssertEqual(info.prevNum, "")
        XCTAssertEqual(info.nextNum, "")
    }

    func testWindowInfoAtStartHasNoPrev() {
        let a = cue("1"), b = cue("2")
        let info = OSCStatusFeedback.windowInfo(goSequence: [a, b], standingByID: a.id)
        XCTAssertEqual(info.index, 0)
        XCTAssertEqual(info.total, 2)
        XCTAssertEqual(info.prevNum, "")
        XCTAssertEqual(info.nextNum, "2")
    }

    func testWindowInfoAtEndHasNoNext() {
        let a = cue("1"), b = cue("2")
        let info = OSCStatusFeedback.windowInfo(goSequence: [a, b], standingByID: b.id)
        XCTAssertEqual(info.index, 1)
        XCTAssertEqual(info.prevNum, "1")
        XCTAssertEqual(info.nextNum, "")
    }

    func testWindowInfoMiddleHasBothNeighbors() {
        let a = cue("1"), b = cue("2"), c = cue("3")
        let info = OSCStatusFeedback.windowInfo(goSequence: [a, b, c], standingByID: b.id)
        XCTAssertEqual(info.index, 1)
        XCTAssertEqual(info.prevNum, "1")
        XCTAssertEqual(info.nextNum, "3")
    }

    // MARK: - D21 select-cue contract, transport level
    //
    // `TriggerRouter.route(selectCueNumber:)` is a thin
    // `cues.first(where: number ==) + transport.setPlayhead(_:)` wrapper —
    // end-to-end AppModel-level coverage (including the unknown-number
    // no-op) lives in OSCTests.swift. This exercises `setPlayhead`'s own
    // pre-existing GO-sequence-membership contract directly, with a
    // MockProvider-backed TransportController and no AppModel involved.

    func testSelectKnownNumberMovesPlayheadWithoutFiring() {
        let a = Cue(number: "1", body: .audio(AudioBody(media: MediaReference(absolutePath: "/fake/1.wav"))))
        let b = Cue(number: "2", body: .audio(AudioBody(media: MediaReference(absolutePath: "/fake/2.wav"))))
        var show = ShowFile()
        show.cues = [a, b]
        let transport = TransportController(provider: MockProvider(), show: { show }, showFolder: { nil })

        guard let target = show.cues.first(where: { $0.number == "2" }) else { return XCTFail("cue not found") }
        transport.setPlayhead(target.id)

        XCTAssertEqual(transport.playheadID, b.id)
        XCTAssertTrue(transport.registry.instances.isEmpty, "select must never arm/fire a player")
    }

    func testSelectingAnUnGOableFireAllChildIsANoOp() {
        let group = Cue(number: "1", body: .group(GroupBody(mode: .fireAll)))
        let child = Cue(number: "1.1", parentID: group.id, body: .audio(AudioBody(media: MediaReference(absolutePath: "/fake/1.1.wav"))))
        var show = ShowFile()
        show.cues = [group, child]
        let transport = TransportController(provider: MockProvider(), show: { show }, showFolder: { nil })

        // Baseline: the fire-all group itself stands by (its children never
        // appear in goSequence — only enter-and-play-first groups expand).
        XCTAssertEqual(transport.standingByCue?.id, group.id)

        transport.setPlayhead(child.id)

        XCTAssertNil(transport.playheadID, "an un-GO-able cue must leave the playhead untouched")
        XCTAssertEqual(transport.standingByCue?.id, group.id, "still standing by the group")
        XCTAssertTrue(transport.registry.instances.isEmpty)
    }
}
