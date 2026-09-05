import CoreMIDI
import XCTest
@testable import StageWizard

/// D30: the MIDI Send cue — the outbound sibling of D29's OSC Send, and the
/// app's FIRST MIDI output. Covers the model (Codable round trip, stripped-
/// key defaults, clamps), the pure word/plan construction in
/// `MIDIController` (round-tripped through the existing UMP parser where
/// possible), the runtime action (fires exactly once via an injected
/// closure, completes immediately, no destination validation at this
/// layer), and `MIDIController.send`'s own destination-matching/warning
/// behavior.
final class MIDISendTests: XCTestCase {

    // MARK: - Codable

    func testMIDISendBodyRoundTripsEveryKind() throws {
        for kind: MIDISendBody.Kind in [.noteOn, .controlChange, .programChange] {
            let body = MIDISendBody(
                kind: kind, channel: 9, number: 42, value: 77,
                noteOffAfter: 0.25, destinationName: "IAC Driver Bus 1"
            )
            let cue = Cue(number: "1", body: .midiSend(body))
            let data = try JSONEncoder().encode(cue)
            let decoded = try JSONDecoder().decode(Cue.self, from: data)
            XCTAssertEqual(decoded, cue, "round trip failed for kind \(kind)")
        }
    }

    func testMIDISendBodyDefaultsWhenKeysAreStripped() throws {
        let json = """
        {"type": "midiSend"}
        """
        let decoded = try JSONDecoder().decode(CueBody.self, from: Data(json.utf8))
        guard case .midiSend(let body) = decoded else {
            return XCTFail("expected .midiSend, got \(decoded)")
        }
        XCTAssertEqual(body.kind, .noteOn)
        XCTAssertEqual(body.channel, 0)
        XCTAssertEqual(body.number, 60)
        XCTAssertEqual(body.value, 100)
        XCTAssertEqual(body.noteOffAfter, 0.1)
        XCTAssertEqual(body.destinationName, "")
    }

    func testMIDISendBodyClampsOutOfRangeValuesOnDecode() throws {
        let json = """
        {"type": "midiSend", "channel": 99, "number": 60, "value": 200, "noteOffAfter": -5}
        """
        let decoded = try JSONDecoder().decode(CueBody.self, from: Data(json.utf8))
        guard case .midiSend(let body) = decoded else {
            return XCTFail("expected .midiSend, got \(decoded)")
        }
        XCTAssertEqual(body.channel, 15, "channel clamps to the top of 0-15")
        XCTAssertEqual(body.value, 127, "value clamps to the top of 0-127")
        XCTAssertEqual(body.noteOffAfter, 0, "a negative noteOffAfter clamps to 0")
    }

    func testMIDISendBodyClampAppliesOnDirectInitToo() {
        // Same clamp the decoder applies — an authored out-of-range value
        // (e.g. programmatic construction) is just as invalid as a decoded one.
        XCTAssertEqual(MIDISendBody(channel: 99).channel, 15)
        XCTAssertEqual(MIDISendBody(number: 200).number, 127)
        XCTAssertEqual(MIDISendBody(value: 200).value, 127)
        XCTAssertEqual(MIDISendBody(noteOffAfter: -5).noteOffAfter, 0)
        XCTAssertEqual(MIDISendBody(noteOffAfter: 120).noteOffAfter, 60)
    }

    func testDefaultNameMatchesEachKindsOneBasedChannelConvention() {
        XCTAssertEqual(CueBody.midiSend(MIDISendBody(kind: .noteOn, channel: 0, number: 60)).defaultName, "Note 60 ch 1")
        XCTAssertEqual(CueBody.midiSend(MIDISendBody(kind: .controlChange, channel: 0, number: 7)).defaultName, "CC 7 ch 1")
        XCTAssertEqual(CueBody.midiSend(MIDISendBody(kind: .programChange, channel: 0, number: 5)).defaultName, "Prog 5 ch 1")
        // Wire value 9 displays as channel 10.
        XCTAssertEqual(CueBody.midiSend(MIDISendBody(kind: .noteOn, channel: 9, number: 1)).defaultName, "Note 1 ch 10")
    }

    // MARK: - Word construction (MIDIController.word(for:) / noteOffWord)

    func testNoteOnWordRoundTripsThroughTheExistingParser() {
        let body = MIDISendBody(kind: .noteOn, channel: 2, number: 60, value: 100)
        let word = MIDIController.word(for: body)
        XCTAssertEqual(
            MIDIController.messages(fromWords: [word]),
            [MIDIController.MIDIMessage(kind: .noteOn, channel: 2, number: 60, value: 100)]
        )
    }

    func testControlChangeWordRoundTripsThroughTheExistingParser() {
        let body = MIDISendBody(kind: .controlChange, channel: 5, number: 7, value: 127)
        let word = MIDIController.word(for: body)
        XCTAssertEqual(
            MIDIController.messages(fromWords: [word]),
            [MIDIController.MIDIMessage(kind: .controlChange, channel: 5, number: 7, value: 127)]
        )
    }

    /// programChange (status 0xC) has no arm in `messages(fromWords:)` — it
    /// only parses 0x8/0x9/0xB — so this word can't round-trip through the
    /// parser. Pinned instead against a hand-computed constant: message-type
    /// nibble 0x2, status byte 0xC3 (0xC0 | channel 3), data1 = 12, data2
    /// forced to 0 (program change carries only one data byte).
    func testProgramChangeWordMatchesHandComputedConstant() {
        let body = MIDISendBody(kind: .programChange, channel: 3, number: 12, value: 99)
        XCTAssertEqual(MIDIController.word(for: body), 0x20C3_0C00)
    }

    /// The matching noteOff for a noteOn: status 0x8n, velocity 64 — a real
    /// noteOff status (not a noteOn-with-velocity-0).
    func testNoteOffWordRoundTripsThroughTheExistingParserAsNoteOff() {
        let word = MIDIController.noteOffWord(channel: 4, number: 60)
        XCTAssertEqual(
            MIDIController.messages(fromWords: [word]),
            [MIDIController.MIDIMessage(kind: .noteOff, channel: 4, number: 60, value: 64)]
        )
    }

    // MARK: - Plan (what to send, and when)

    func testPlanForNoteOnYieldsNoteOnImmediatelyThenNoteOffAtDelay() {
        let body = MIDISendBody(kind: .noteOn, channel: 0, number: 60, value: 100, noteOffAfter: 0.3)
        let plan = MIDIController.plan(for: body)
        XCTAssertEqual(plan.count, 2, "noteOn always yields a paired noteOff — a hanging note is worse than a late one")
        XCTAssertEqual(plan[0].word, MIDIController.word(for: body))
        XCTAssertEqual(plan[0].delay, 0)
        XCTAssertEqual(plan[1].word, MIDIController.noteOffWord(channel: 0, number: 60))
        XCTAssertEqual(plan[1].delay, 0.3)
    }

    func testPlanForNoteOnWithZeroNoteOffAfterStillSchedulesTheNoteOff() {
        // 0 still sends a noteOff — immediately after, not fused into the
        // noteOn itself.
        let body = MIDISendBody(kind: .noteOn, channel: 0, number: 60, noteOffAfter: 0)
        let plan = MIDIController.plan(for: body)
        XCTAssertEqual(plan.count, 2)
        XCTAssertEqual(plan[1].delay, 0)
    }

    func testPlanForControlChangeYieldsExactlyOneEntry() {
        let body = MIDISendBody(kind: .controlChange, channel: 1, number: 7, value: 64)
        let plan = MIDIController.plan(for: body)
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan[0].delay, 0)
        XCTAssertEqual(plan[0].word, MIDIController.word(for: body))
    }

    func testPlanForProgramChangeYieldsExactlyOneEntry() {
        let body = MIDISendBody(kind: .programChange, channel: 0, number: 5)
        let plan = MIDIController.plan(for: body)
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan[0].delay, 0)
    }

    // MARK: - D30 lifecycle fix: output port/client independence from the listener

    /// Pins the fix directly: `send(_:)` (via `ensureOutputPort`) must create
    /// its OWN `outputClient`, never borrow the listener's `client` — and
    /// both must survive `stop()` untouched. Under the original bug,
    /// `outputClient` stayed zero (the port was created on `client` instead)
    /// and `stop()`'s `MIDIClientDispose(client)` silently disposed it,
    /// killing every later `.midiSend` cue and any pending delayed noteOff
    /// with no operator warning.
    @MainActor
    func testOutputClientIsIndependentOfTheListenerAndSurvivesStop() {
        let controller = MIDIController()
        controller.start()
        XCTAssertNotEqual(controller.client, MIDIClientRef(), "the listener's client must exist while running")

        controller.send(MIDISendBody(destinationName: ""))   // triggers ensureOutputPort()

        XCTAssertNotEqual(
            controller.outputClient, MIDIClientRef(),
            "send() must create its OWN output client rather than borrowing the listener's — " +
            "otherwise stop() disposing the listener's client silently kills this one too"
        )
        XCTAssertNotEqual(
            controller.outputClient, controller.client,
            "the output client must never be the same object as the listener's client"
        )
        let outputClientBeforeStop = controller.outputClient
        let outputPortBeforeStop = controller.outputPort

        controller.stop()

        XCTAssertEqual(controller.client, MIDIClientRef(), "stop() must dispose the LISTENER's client")
        XCTAssertEqual(
            controller.outputClient, outputClientBeforeStop,
            "the output client must be untouched by stop() — it belongs to send(), not the listener"
        )
        XCTAssertEqual(
            controller.outputPort, outputPortBeforeStop,
            "the output port must survive stop() — a disposed port here means every later MIDI send, " +
            "and any pending delayed noteOff, silently goes nowhere"
        )
    }

    @MainActor
    func testOutputPortStillCreatableWhenListenerWasNeverStarted() {
        // The output half must work even when midiEnabled has never been on
        // — it must not depend on start() ever having run.
        let controller = MIDIController()
        XCTAssertEqual(controller.client, MIDIClientRef(), "listener never started")
        controller.send(MIDISendBody(destinationName: ""))
        XCTAssertNotEqual(controller.outputClient, MIDIClientRef(), "send must create its own client on demand")
    }

    // MARK: - MIDIController.send: destination matching / warnings

    @MainActor
    func testSendWithEmptyDestinationNameNeverWarnsEvenWithNoDestinations() {
        // "" = ALL destinations — a valid, meaningful configuration (unlike
        // OSCSendBody.host's ""), so there is nothing to warn about even on a
        // machine with zero connected MIDI destinations.
        let controller = MIDIController()
        var warned: String?
        controller.onWarning = { warned = $0 }
        controller.send(MIDISendBody(destinationName: ""))
        XCTAssertNil(warned)
    }

    @MainActor
    func testSendWithUnmatchedDestinationNameWarnsOperator() {
        let controller = MIDIController()
        var warned: String?
        controller.onWarning = { warned = $0 }
        let name = "Definitely Not A Real MIDI Destination \(UUID())"
        controller.send(MIDISendBody(destinationName: name))
        XCTAssertEqual(warned, "MIDI: no connected destination named “\(name)” — message not sent")
    }

    // MARK: - Runtime harness (mirrors OSCSendTests' Harness pattern)

    @MainActor
    private final class Harness {
        var show = ShowFile()
        let provider = MockProvider()
        var transport: TransportController!
        private(set) var sent: [MIDISendBody] = []
        private(set) var warnings: [String] = []

        init() {
            transport = TransportController(
                provider: provider,
                show: { [unowned self] in self.show },
                showFolder: { nil },
                midiSend: { [weak self] body in self?.sent.append(body) }
            )
            transport.onOperatorWarning = { [weak self] message in self?.warnings.append(message) }
        }

        func wait(_ seconds: TimeInterval) async {
            try? await Task.sleep(for: .seconds(seconds))
        }
    }

    @MainActor
    func testMIDISendCueFiresExactlyOnceWithCorrectPayload() async {
        let harness = Harness()
        let body = MIDISendBody(kind: .controlChange, channel: 3, number: 64, value: 127, destinationName: "Everything")
        let cue = Cue(number: "1", body: .midiSend(body))
        harness.show.cues = [cue]
        harness.transport.go()
        await harness.wait(0.05)
        XCTAssertEqual(harness.sent.count, 1)
        XCTAssertEqual(harness.sent.first, body)
    }

    @MainActor
    func testMIDISendCueCompletesImmediatelyLikeAnOSCSendCue() async {
        let harness = Harness()
        let cue = Cue(number: "1", body: .midiSend(MIDISendBody()))
        harness.show.cues = [cue]
        harness.transport.go()
        await harness.wait(0.05)
        XCTAssertEqual(harness.transport.registry.instances.count, 0, "a MIDI send cue must not linger in the active-cues registry")
    }

    @MainActor
    func testMIDISendCueNeverBlocksGOAdvancingToTheNextCue() async {
        let harness = Harness()
        let a = Cue(number: "1", body: .midiSend(MIDISendBody()))
        let b = Cue(number: "2", body: .midiSend(MIDISendBody(number: 61)))
        harness.show.cues = [a, b]
        harness.transport.go()
        XCTAssertEqual(harness.transport.playheadID, b.id, "GO must advance past an instant MIDI cue synchronously")
    }

    /// UNLIKE OSC Send, an empty `destinationName` is a valid "send to ALL"
    /// configuration, not an unconfigured one — the runtime arm must stay
    /// dumb and never warn, even when the closure it calls is a stub that
    /// records the call (destination matching is MIDIController's job).
    @MainActor
    func testEmptyDestinationNameIsNeverWarnedAtTheRuntimeLevel() async {
        let harness = Harness()
        let cue = Cue(number: "1", body: .midiSend(MIDISendBody(destinationName: "")))
        harness.show.cues = [cue]
        harness.transport.go()
        await harness.wait(0.05)
        XCTAssertEqual(harness.sent.count, 1, "the runtime always forwards the cue — no destination validation happens here")
        XCTAssertTrue(harness.warnings.isEmpty, "an empty destination name is not an error at the runtime layer")
    }

    @MainActor
    func testPreWaitIsHonoredBeforeSending() async {
        let harness = Harness()
        let cue = Cue(number: "1", preWait: 0.25, body: .midiSend(MIDISendBody()))
        harness.show.cues = [cue]
        harness.transport.go()
        await harness.wait(0.1)
        XCTAssertTrue(harness.sent.isEmpty, "must not send before the pre-wait elapses")
        await harness.wait(0.3)
        XCTAssertEqual(harness.sent.count, 1, "sends once the pre-wait has elapsed")
    }
}
