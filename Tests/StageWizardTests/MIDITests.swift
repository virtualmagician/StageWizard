import XCTest
@testable import StageWizard

/// Phase D6: trigger bus + MIDI remote control.
@MainActor
final class MIDITests: XCTestCase {

    // MARK: - UMP word construction helper

    /// Builds a MIDI 1.0 channel-voice UMP word: message-type nibble 0x2,
    /// group in the next nibble, then the classic 3-byte MIDI message
    /// (status|channel, data1, data2) packed into the low 24 bits — mirrors
    /// MIDIController.messages(fromWords:)'s own layout doc.
    private func word(status: UInt8, channel: UInt8, data1: UInt8, data2: UInt8, group: UInt8 = 0) -> UInt32 {
        let messageType: UInt32 = 2
        let statusByte = UInt32(status) << 4 | UInt32(channel & 0x0F)
        return (messageType << 28) | (UInt32(group & 0xF) << 24) | (statusByte << 16) | (UInt32(data1 & 0x7F) << 8) | UInt32(data2 & 0x7F)
    }

    // MARK: - Parser: MIDIController.messages(fromWords:)

    func testParsesNoteOn() {
        let messages = MIDIController.messages(fromWords: [word(status: 0x9, channel: 3, data1: 60, data2: 100)])
        XCTAssertEqual(messages, [MIDIController.MIDIMessage(kind: .noteOn, channel: 3, number: 60, value: 100)])
    }

    func testParsesNoteOff() {
        let messages = MIDIController.messages(fromWords: [word(status: 0x8, channel: 2, data1: 64, data2: 40)])
        XCTAssertEqual(messages, [MIDIController.MIDIMessage(kind: .noteOff, channel: 2, number: 64, value: 40)])
    }

    func testParsesControlChange() {
        let messages = MIDIController.messages(fromWords: [word(status: 0xB, channel: 0, data1: 7, data2: 127)])
        XCTAssertEqual(messages, [MIDIController.MIDIMessage(kind: .controlChange, channel: 0, number: 7, value: 127)])
    }

    func testNoteOnWithVelocityZeroDecodesAsNoteOff() {
        let messages = MIDIController.messages(fromWords: [word(status: 0x9, channel: 5, data1: 71, data2: 0)])
        XCTAssertEqual(messages, [MIDIController.MIDIMessage(kind: .noteOff, channel: 5, number: 71, value: 0)])
    }

    func testNonChannelVoiceMessageTypeIsIgnored() {
        // Message-type nibble 0x4 (MIDI 2.0 channel voice) — must be ignored,
        // not misread as a MIDI 1.0 status byte.
        let alienWord: UInt32 = (0x4 << 28) | (0 << 24) | (0x90 << 16) | (60 << 8) | 100
        XCTAssertTrue(MIDIController.messages(fromWords: [alienWord]).isEmpty)
    }

    func testIgnoresNonChannelVoiceStatusBytesWithinType2() {
        // Status nibble 0xF (system messages) carried as a type-2 word: not
        // one of noteOn/noteOff/CC, so it's dropped rather than misdecoded.
        let raw = word(status: 0xF, channel: 0, data1: 0, data2: 0)
        XCTAssertTrue(MIDIController.messages(fromWords: [raw]).isEmpty)
    }

    func testMultipleWordsInOneListDecodeInOrder() {
        let words = [
            word(status: 0x9, channel: 0, data1: 60, data2: 100),
            word(status: 0xB, channel: 1, data1: 64, data2: 127),
            word(status: 0x8, channel: 0, data1: 60, data2: 0),
        ]
        let messages = MIDIController.messages(fromWords: words)
        XCTAssertEqual(messages, [
            MIDIController.MIDIMessage(kind: .noteOn, channel: 0, number: 60, value: 100),
            MIDIController.MIDIMessage(kind: .controlChange, channel: 1, number: 64, value: 127),
            MIDIController.MIDIMessage(kind: .noteOff, channel: 0, number: 60, value: 0),
        ])
    }

    // MARK: - CC transition logic: CCTransitionTracker

    func testCCTransitionFiresOnCrossingSixtyThreeToSixtyFour() {
        var tracker = CCTransitionTracker()
        XCTAssertFalse(tracker.shouldFire(channel: 0, number: 7, value: 63))
        XCTAssertTrue(tracker.shouldFire(channel: 0, number: 7, value: 64))
    }

    func testCCTransitionDoesNotRefireWhileHeldAboveThreshold() {
        var tracker = CCTransitionTracker()
        XCTAssertTrue(tracker.shouldFire(channel: 0, number: 7, value: 64))
        XCTAssertFalse(tracker.shouldFire(channel: 0, number: 7, value: 65))
    }

    func testCCTransitionRearmsBelowThresholdAndFiresTwice() {
        var tracker = CCTransitionTracker()
        var fireCount = 0
        for value: UInt8 in [64, 10, 70] {
            if tracker.shouldFire(channel: 0, number: 7, value: value) { fireCount += 1 }
        }
        XCTAssertEqual(fireCount, 2, "64 (arms+fires), 10 (re-arms), 70 (fires again)")
    }

    func testCCTransitionTracksChannelAndNumberIndependently() {
        var tracker = CCTransitionTracker()
        XCTAssertTrue(tracker.shouldFire(channel: 0, number: 7, value: 100))
        // A different channel/number pair starts fresh below the threshold.
        XCTAssertTrue(tracker.shouldFire(channel: 1, number: 7, value: 100))
        XCTAssertTrue(tracker.shouldFire(channel: 0, number: 8, value: 100))
    }

    // MARK: - Codable: MIDIBinding / MIDIBindingEntry / ShowSettings

    func testMIDIBindingRoundTripsThroughCodable() throws {
        let binding = MIDIBinding(kind: .controlChange, channel: 9, number: 64)
        let decoded = try JSONDecoder().decode(MIDIBinding.self, from: JSONEncoder().encode(binding))
        XCTAssertEqual(decoded, binding)
    }

    func testMIDIBindingEntryRoundTripsThroughCodable() throws {
        let entry = MIDIBindingEntry(binding: MIDIBinding(kind: .noteOn, channel: 0, number: 60), action: .go)
        let decoded = try JSONDecoder().decode(MIDIBindingEntry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(decoded, entry)
    }

    func testMIDISettingsRoundTripThroughShowFile() throws {
        var show = ShowFile()
        show.settings.midiEnabled = true
        show.settings.midiBindings = [
            MIDIBindingEntry(binding: MIDIBinding(kind: .noteOn, channel: 0, number: 60), action: .go),
            MIDIBindingEntry(binding: MIDIBinding(kind: .controlChange, channel: 0, number: 64), action: .stopAll),
        ]
        let decoded = try ShowFile.load(from: show.encoded())
        XCTAssertTrue(decoded.settings.midiEnabled)
        XCTAssertEqual(decoded.settings.midiBindings, show.settings.midiBindings)
    }

    func testMIDIEnabledDefaultsFalseAndBindingsDefaultEmpty() {
        let settings = ShowSettings()
        XCTAssertFalse(settings.midiEnabled)
        XCTAssertTrue(settings.midiBindings.isEmpty)
    }

    func testOlderShowFileWithoutMIDIKeysDecodesToDefaults() throws {
        // A pre-D6 show file predates MIDI remote control entirely.
        var show = ShowFile()
        show.settings.midiEnabled = true
        show.settings.midiBindings = [MIDIBindingEntry(binding: MIDIBinding(kind: .noteOn, channel: 0, number: 1), action: .go)]
        var json = try JSONSerialization.jsonObject(with: show.encoded()) as! [String: Any]
        var settings = json["settings"] as! [String: Any]
        settings.removeValue(forKey: "midiEnabled")
        settings.removeValue(forKey: "midiBindings")
        json["settings"] = settings
        let stripped = try JSONSerialization.data(withJSONObject: json)
        let decoded = try ShowFile.load(from: stripped)
        XCTAssertFalse(decoded.settings.midiEnabled, "pre-D6 files predate MIDI control")
        XCTAssertTrue(decoded.settings.midiBindings.isEmpty)
    }

    // MARK: - MIDIController dispatch (learn mode + firing semantics)

    func testLearnModeCapturesFirstEligibleMessageAndStopsLearning() {
        let controller = MIDIController()
        var learned: MIDIBinding?
        controller.learning = true
        controller.onLearned = { learned = $0 }
        controller.handle([
            MIDIController.MIDIMessage(kind: .noteOff, channel: 0, number: 60, value: 0),   // ineligible — skipped
            MIDIController.MIDIMessage(kind: .noteOn, channel: 2, number: 60, value: 100),  // captured
            MIDIController.MIDIMessage(kind: .noteOn, channel: 5, number: 61, value: 100),  // must NOT overwrite
        ])
        XCTAssertEqual(learned, MIDIBinding(kind: .noteOn, channel: 2, number: 60))
        XCTAssertFalse(controller.learning, "learn mode ends after the first captured message")
    }

    func testNoteOnFiresBoundActionImmediately() {
        let controller = MIDIController()
        let binding = MIDIBinding(kind: .noteOn, channel: 0, number: 60)
        controller.bindingsProvider = { [MIDIBindingEntry(binding: binding, action: .go)] }
        var fired: ShortcutAction?
        controller.onAction = { fired = $0 }
        controller.handle([MIDIController.MIDIMessage(kind: .noteOn, channel: 0, number: 60, value: 100)])
        XCTAssertEqual(fired, .go)
    }

    func testNoteOffNeverFiresEvenIfBound() {
        let controller = MIDIController()
        let binding = MIDIBinding(kind: .noteOn, channel: 0, number: 60)
        controller.bindingsProvider = { [MIDIBindingEntry(binding: binding, action: .go)] }
        var fired: ShortcutAction?
        controller.onAction = { fired = $0 }
        controller.handle([MIDIController.MIDIMessage(kind: .noteOff, channel: 0, number: 60, value: 0)])
        XCTAssertNil(fired, "noteOff must never fire, even against a matching binding")
    }

    func testHeldCCDoesNotMachineGunFire() {
        let controller = MIDIController()
        let binding = MIDIBinding(kind: .controlChange, channel: 0, number: 64)
        controller.bindingsProvider = { [MIDIBindingEntry(binding: binding, action: .stopAll)] }
        var fireCount = 0
        controller.onAction = { _ in fireCount += 1 }
        // A held pedal keeps re-sending the same at/above-threshold value.
        controller.handle([
            MIDIController.MIDIMessage(kind: .controlChange, channel: 0, number: 64, value: 127),
            MIDIController.MIDIMessage(kind: .controlChange, channel: 0, number: 64, value: 127),
            MIDIController.MIDIMessage(kind: .controlChange, channel: 0, number: 64, value: 126),
        ])
        XCTAssertEqual(fireCount, 1, "only the transition into ≥64 fires, not every repeat")
    }

    // MARK: - Router

    /// A cue whose action stays outstanding synchronously after firing (arm
    /// is async), so `registry.instances` still holds it the instant `fire`
    /// returns — unlike a `.stop` cue, whose action runs and terminates
    /// synchronously within the same call.
    private func pendingAudioCue(number: String) -> Cue {
        Cue(number: number, body: .audio(AudioBody(media: MediaReference(absolutePath: "/fake/\(number).wav"))))
    }

    func testRouteCueNumberWithUnknownNumberIsNoOp() {
        let app = AppModel()
        app.document.mutate { $0.cues = [pendingAudioCue(number: "1")] }
        app.triggerRouter.route(cueNumber: "99")
        XCTAssertTrue(app.transport.registry.instances.isEmpty)
    }

    func testRouteCueNumberWithKnownNumberReachesFire() {
        let app = AppModel()
        let cue = pendingAudioCue(number: "1")
        app.document.mutate { $0.cues = [cue] }
        app.triggerRouter.route(cueNumber: "1")
        XCTAssertEqual(app.transport.registry.instances.first?.cue.id, cue.id)
    }

    func testRouteActionReachesTransport() {
        let app = AppModel()
        let cue = pendingAudioCue(number: "1")
        app.document.mutate { $0.cues = [cue] }
        app.triggerRouter.route(.go)
        XCTAssertEqual(app.transport.registry.instances.first?.cue.id, cue.id, "route(.go) must reach the same GO transport.go() drives")
    }
}
