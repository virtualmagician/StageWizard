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
        prevNum: String = "2", prevName: String = "Fade up", nextNum: String = "4", nextName: String = "Rain"
    ) -> OSCStatusFeedback.Snapshot {
        OSCStatusFeedback.Snapshot(
            standingByNumber: standingByNumber, standingByName: standingByName, notes: notes,
            runningCount: runningCount, panic: panic, showMode: showMode,
            windowIndex: windowIndex, windowTotal: windowTotal,
            prevNum: prevNum, prevName: prevName, nextNum: nextNum, nextName: nextName
        )
    }

    func testNilOldSnapshotSendsEveryAddress() {
        let messages = OSCStatusFeedback.changedMessages(old: nil, new: snapshot())
        XCTAssertEqual(Set(messages.map(\.address)), [
            "/stagewizard/status/standingby", "/stagewizard/status/running", "/stagewizard/status/panic",
            "/stagewizard/status/showmode", "/stagewizard/status/window", "/stagewizard/status/notes",
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
