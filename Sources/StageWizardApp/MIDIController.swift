import CoreMIDI
import Foundation
import Observation

/// Zero-dependency CoreMIDI listener: connects to every current MIDI source
/// and dispatches MIDI 1.0 channel-voice messages (delivered as UMP via the
/// MIDIEventList protocol) to transport actions through per-binding
/// MIDI-Learn bindings, via TriggerRouter — MIDI is its first client.
///
/// Concurrency: @MainActor, mirroring AudioDeviceManager. CoreMIDI delivers
/// BOTH the setup-change notification and the receive block on ITS OWN
/// threads — every closure handed to CoreMIDI here is `@Sendable` and hops
/// via `Task { @MainActor in … }` before touching any actor state (the exact
/// bug this guards against once crashed GO — see AudioDeviceManager). The
/// receive block is stricter still: the `MIDIEventList` pointer is only
/// valid for the duration of the call, so the UMP words are extracted and
/// run through the pure, `nonisolated` `messages(fromWords:)` parser
/// SYNCHRONOUSLY on the CoreMIDI thread — only the resulting value-type
/// messages are handed across the hop.
@MainActor
@Observable
final class MIDIController {
    /// A decoded MIDI 1.0 channel-voice message.
    struct MIDIMessage: Equatable {
        enum Kind: Equatable {
            case noteOn
            case noteOff
            case controlChange
        }
        var kind: Kind
        var channel: UInt8
        var number: UInt8
        var value: UInt8
    }

    // MARK: - Wiring (live lookup, mirrors ShortcutManager's *Provider pattern)

    /// Live bindings lookup — provided by the app so edits apply instantly;
    /// bindings are resolved at dispatch time, never cached.
    var bindingsProvider: @MainActor () -> [MIDIBindingEntry] = { [] }
    var onAction: (@MainActor (ShortcutAction) -> Void)?

    /// While true, the next eligible message (noteOn vel>0, or a CC
    /// transitioning ≥64) is captured as a binding and delivered via
    /// `onLearned` instead of being dispatched. Cleared after one capture.
    var learning = false
    var onLearned: (@MainActor (MIDIBinding) -> Void)?

    /// Connected source display names, for the Remote settings tab.
    private(set) var sources: [String] = []

    @ObservationIgnored private var client = MIDIClientRef()
    @ObservationIgnored private var inputPort = MIDIPortRef()
    @ObservationIgnored private var connectedSources: Set<MIDIEndpointRef> = []
    @ObservationIgnored private var running = false
    @ObservationIgnored private var ccTracker = CCTransitionTracker()

    init() {}

    // MARK: - Lifecycle (owned by AppModel: started/stopped with settings.midiEnabled)

    /// Active in every workspace mode, same as hotkeys — there is no mode
    /// gate here, only the enable toggle.
    func start() {
        guard !running else { return }

        var newClient = MIDIClientRef()
        let clientStatus = MIDIClientCreateWithBlock("StageWizard" as CFString, &newClient) { @Sendable [weak self] _ in
            // Setup change (device plugged/unplugged) — arrives on a CoreMIDI
            // notification thread. Hop before touching any state.
            Task { @MainActor in
                self?.refreshSources()
            }
        }
        guard clientStatus == noErr else { return }

        var newPort = MIDIPortRef()
        let portStatus = MIDIInputPortCreateWithProtocol(
            newClient, "StageWizard Input" as CFString, ._1_0, &newPort
        ) { @Sendable [weak self] eventListPointer, _ in
            // CoreMIDI thread. The pointer is only valid for this call, so
            // decode it into Sendable value types BEFORE hopping.
            let words = MIDIController.words(from: eventListPointer)
            let messages = MIDIController.messages(fromWords: words)
            guard !messages.isEmpty else { return }
            Task { @MainActor in
                self?.handle(messages)
            }
        }
        guard portStatus == noErr else {
            MIDIClientDispose(newClient)
            return
        }

        client = newClient
        inputPort = newPort
        running = true
        refreshSources()
    }

    func stop() {
        guard running else { return }
        running = false
        MIDIPortDispose(inputPort)
        MIDIClientDispose(client)
        inputPort = MIDIPortRef()
        client = MIDIClientRef()
        connectedSources.removeAll()
        sources = []
        ccTracker = CCTransitionTracker()
    }

    func cancelLearning() {
        learning = false
        onLearned = nil
    }

    /// Connect every current source (idempotent — already-connected sources
    /// are skipped) and refresh the display-name list. Called on start and
    /// again whenever CoreMIDI reports a setup change (hot-plug).
    private func refreshSources() {
        guard running else { return }
        var names: [String] = []
        let count = MIDIGetNumberOfSources()
        for index in 0..<count {
            let source = MIDIGetSource(index)
            guard source != 0 else { continue }
            if !connectedSources.contains(source) {
                if MIDIPortConnectSource(inputPort, source, nil) == noErr {
                    connectedSources.insert(source)
                }
            }
            names.append(Self.displayName(for: source))
        }
        sources = names
    }

    private static func displayName(for endpoint: MIDIEndpointRef) -> String {
        var unmanagedName: Unmanaged<CFString>?
        let status = MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &unmanagedName)
        guard status == noErr, let name = unmanagedName?.takeRetainedValue() else {
            return "MIDI Source"
        }
        return name as String
    }

    // MARK: - Dispatch (MainActor)

    /// Internal (not private) so tests can drive dispatch/learn-mode
    /// directly with hand-built messages, without a live CoreMIDI source.
    func handle(_ messages: [MIDIMessage]) {
        for message in messages {
            guard let binding = eligibleBinding(for: message) else { continue }
            if learning {
                learning = false
                let callback = onLearned
                onLearned = nil
                callback?(binding)
                return   // only the FIRST eligible message is captured
            }
            fire(binding)
        }
    }

    /// The binding this message would represent, applying firing semantics:
    /// noteOn (vel>0) fires immediately, noteOff never fires, CC fires only
    /// on the transition into ≥64 (see CCTransitionTracker). Returns nil for
    /// messages that don't cross the firing threshold.
    private func eligibleBinding(for message: MIDIMessage) -> MIDIBinding? {
        switch message.kind {
        case .noteOn where message.value > 0:
            return MIDIBinding(kind: .noteOn, channel: message.channel, number: message.number)
        case .noteOn, .noteOff:
            return nil
        case .controlChange:
            let fired = ccTracker.shouldFire(channel: message.channel, number: message.number, value: message.value)
            return fired ? MIDIBinding(kind: .controlChange, channel: message.channel, number: message.number) : nil
        }
    }

    private func fire(_ binding: MIDIBinding) {
        guard let entry = bindingsProvider().first(where: { $0.binding == binding }) else { return }
        onAction?(entry.action)
    }

    // MARK: - Pure UMP parsing (nonisolated + static: safe to call from the
    // CoreMIDI thread with no actor hop, and directly unit-testable)

    /// Extract every UMP word from a MIDIEventList. MUST run synchronously on
    /// the calling (CoreMIDI) thread — the pointer is invalid afterward.
    nonisolated private static func words(from eventListPointer: UnsafePointer<MIDIEventList>) -> [UInt32] {
        // unsafeSequence walks the variable-length packets IN the original
        // list memory — MIDIEventPacketNext on a stack copy would compute a
        // next-packet address that only means something in that memory.
        var result: [UInt32] = []
        for packetPointer in eventListPointer.unsafeSequence() {
            let count = Int(packetPointer.pointee.wordCount)
            withUnsafeBytes(of: packetPointer.pointee.words) { raw in
                let buffer = raw.bindMemory(to: UInt32.self)
                for index in 0..<min(count, buffer.count) {
                    result.append(buffer[index])
                }
            }
        }
        return result
    }

    /// MIDI 1.0 channel-voice UMP words → value-type messages. Pure
    /// function, no state — unit-tested directly with hand-built word
    /// arrays. UMP layout: message-type nibble 0x2 = MIDI 1.0 channel voice,
    /// status byte = bits 23-16 (0x9n noteOn / 0x8n noteOff / 0xBn CC),
    /// data1 = bits 15-8 & 0x7F, data2 = bits 7-0 & 0x7F. Everything else
    /// (system messages, MIDI 2.0 channel voice, other message types) is
    /// ignored.
    nonisolated static func messages(fromWords words: [UInt32]) -> [MIDIMessage] {
        var result: [MIDIMessage] = []
        for word in words {
            guard word >> 28 == 2 else { continue }
            let statusByte = UInt8((word >> 16) & 0xFF)
            let channel = statusByte & 0x0F
            let data1 = UInt8((word >> 8) & 0x7F)
            let data2 = UInt8(word & 0x7F)
            switch statusByte >> 4 {
            case 0x9:
                // NoteOn with velocity 0 is a de facto noteOff (running-status convention).
                result.append(MIDIMessage(kind: data2 == 0 ? .noteOff : .noteOn, channel: channel, number: data1, value: data2))
            case 0x8:
                result.append(MIDIMessage(kind: .noteOff, channel: channel, number: data1, value: data2))
            case 0xB:
                result.append(MIDIMessage(kind: .controlChange, channel: channel, number: data1, value: data2))
            default:
                continue
            }
        }
        return result
    }
}

/// Tracks the last CC value per (channel, number) so a binding fires only on
/// the transition INTO ≥64 — a held pedal (or a fader parked above the
/// midpoint) doesn't machine-gun GO on every repeated CC message. A pure,
/// directly-testable unit; MIDIController owns exactly one instance.
struct CCTransitionTracker {
    private var lastValues: [UInt16: UInt8] = [:]

    private static func key(channel: UInt8, number: UInt8) -> UInt16 {
        UInt16(channel) << 8 | UInt16(number)
    }

    /// Records `value` and returns true iff this is a NEW crossing into ≥64
    /// (the previous value for this channel+number was <64; unseen
    /// channel+number pairs start below the threshold).
    mutating func shouldFire(channel: UInt8, number: UInt8, value: UInt8) -> Bool {
        let key = Self.key(channel: channel, number: number)
        let previous = lastValues[key] ?? 0
        lastValues[key] = value
        return previous < 64 && value >= 64
    }
}
