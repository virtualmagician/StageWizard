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

    /// D30: one operator warning per `.midiSend` cue whose configured
    /// destination name matches no connected destination — wired by
    /// AppModel, same shape as `OSCSender.onWarning`. The cue has already
    /// completed by the time this can fire; purely informational.
    var onWarning: (@MainActor (String) -> Void)?

    /// Connected source display names, for the Remote settings tab.
    private(set) var sources: [String] = []
    /// D30: connected destination display names, for the MIDI Send cue's
    /// destination picker and Preflight — refreshed on setup change exactly
    /// like `sources`, regardless of whether the input listener is running.
    private(set) var destinations: [String] = []

    @ObservationIgnored private(set) var client = MIDIClientRef()
    @ObservationIgnored private var inputPort = MIDIPortRef()
    @ObservationIgnored private var connectedSources: Set<MIDIEndpointRef> = []
    @ObservationIgnored private var running = false
    @ObservationIgnored private var ccTracker = CCTransitionTracker()
    /// D30 (fixed): output half — created lazily on first `send(_:)` call,
    /// entirely independent of `client`/`inputPort`/`running` above (which
    /// are the LISTENER's, gated by `midiEnabled`). Sending must work even
    /// when the listener is disabled, so this never touches `running` — and,
    /// after the lifecycle fix below, `ensureOutputPort()` never touches
    /// `client` either: the output half owns ITS OWN client, so `stop()`
    /// disposing the listener's client can never silently invalidate this
    /// one. `private(set)` (not `private`) on both so MIDIControllerTests can
    /// pin that independence without needing a real connected destination.
    @ObservationIgnored private(set) var outputClient = MIDIClientRef()
    @ObservationIgnored private(set) var outputPort = MIDIPortRef()

    init() {
        // D30: destinations are a plain global CoreMIDI query — no client or
        // port needed to LIST them (only to send), so the picker/Preflight
        // have a live list from launch, independent of `midiEnabled`.
        refreshDestinations()
    }

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
                self?.handleMIDISetupChanged()
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
        // D30 lifecycle fix: `outputPort`/`outputClient` are deliberately NOT
        // touched here. They belong to the OUTPUT half (see `ensureOutputPort`),
        // which — after the fix — never creates its port on `client` above, so
        // disposing `client` can never leave `outputPort` dangling. (The
        // original bug: `ensureOutputPort` reused this LISTENER's `client`
        // when running, so this exact `MIDIClientDispose(client)` silently
        // disposed `outputPort` too, without resetting it — every later
        // `.midiSend` cue, and any pending delayed noteOff, then went into a
        // dead port with no warning. See MIDIControllerTests.)
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

    /// D30: enumerate every current MIDI destination for the Send cue's
    /// picker and Preflight. No client/port required — `MIDIGetNumberOf
    /// Destinations`/`MIDIGetDestination` are plain global queries; only
    /// SENDING needs the output port (see `ensureOutputPort`).
    private func refreshDestinations() {
        var names: [String] = []
        let count = MIDIGetNumberOfDestinations()
        for index in 0..<count {
            let destination = MIDIGetDestination(index)
            guard destination != 0 else { continue }
            names.append(Self.displayName(for: destination))
        }
        destinations = names
    }

    /// Shared MIDI setup-change (hot-plug) handler for BOTH the listener's
    /// client (`start()`) and the independent output client `ensureOutputPort`
    /// may lazily create — the two clients are entirely separate and may both
    /// exist at once (see `ensureOutputPort`), but either one's notification
    /// refreshes both lists; `refreshSources()` is a no-op while the listener
    /// isn't running.
    private func handleMIDISetupChanged() {
        refreshSources()
        refreshDestinations()
    }

    // MARK: - MIDI Send output (D30: the app's first MIDI output)

    /// Lazily create the output port `send(_:)` uses. Sending must work even
    /// when the LISTENER (`midiEnabled`) is off, so this is entirely
    /// decoupled from `running`/`client`/`inputPort`: it ALWAYS creates (or
    /// reuses, on later calls) its own independent `outputClient` — it never
    /// borrows the listener's `client`, even while the listener is running.
    ///
    /// This is deliberate and load-bearing, not just an optimization: an
    /// earlier version reused the listener's client "when running" (one
    /// client, two ports), which meant `stop()`'s `MIDIClientDispose(client)`
    /// silently disposed this port too — every later `.midiSend`, and any
    /// pending delayed noteOff, then went into a dead port with no warning
    /// (`sendWord` ignored the OSStatus). Never reintroduce a `client`
    /// parameter or read of `self.client` here; `MIDIControllerTests` pins
    /// `outputClient != client` after a send while the listener is running.
    ///
    /// Returns nil only if CoreMIDI itself refuses to create the client/port.
    private func ensureOutputPort() -> MIDIPortRef? {
        if outputPort != MIDIPortRef() { return outputPort }

        if outputClient == MIDIClientRef() {
            var newClient = MIDIClientRef()
            let status = MIDIClientCreateWithBlock("StageWizard Output" as CFString, &newClient) { @Sendable [weak self] _ in
                Task { @MainActor in
                    self?.handleMIDISetupChanged()
                }
            }
            guard status == noErr else { return nil }
            outputClient = newClient
        }

        var newPort = MIDIPortRef()
        guard MIDIOutputPortCreate(outputClient, "StageWizard Output" as CFString, &newPort) == noErr else { return nil }
        outputPort = newPort
        return outputPort
    }

    private var outputPortIfReady: MIDIPortRef? {
        outputPort != MIDIPortRef() ? outputPort : nil
    }

    /// D30: send one MIDI message for a `.midiSend` cue — the outbound
    /// sibling of the listener above, and the app's FIRST MIDI output.
    /// `body.destinationName` empty sends to every connected destination; a
    /// non-empty name matching nothing is a warned no-op (mirrors
    /// `OSCSender`'s failed-send warning). NoteOn's matching noteOff is
    /// scheduled here — owned by this controller, not by the cue (which has
    /// already completed by fire time; see `CueInstance.runMIDISendAction`)
    /// — and deliberately NEVER cancelled: a stuck note is worse than a late
    /// noteOff, so panic/Stop All must not leave one hanging.
    func send(_ body: MIDISendBody) {
        guard let port = ensureOutputPort() else { return }
        let targets = Self.matchingDestinations(named: body.destinationName)
        guard !targets.isEmpty else {
            if !body.destinationName.isEmpty {
                onWarning?("MIDI: no connected destination named “\(body.destinationName)” — message not sent")
            }
            return
        }
        let destinationName = body.destinationName
        for (word, delay) in Self.plan(for: body) {
            if delay <= 0 {
                // Throttled to at most ONE warning per plan entry — sending
                // the same word to every "ALL destinations" target shouldn't
                // spam one warning per destination if the port is dead.
                var warnedThisSend = false
                for destination in targets {
                    let status = Self.sendWord(word, port: port, destination: destination)
                    if status != noErr, !warnedThisSend {
                        warnedThisSend = true
                        onWarning?("MIDI: send failed (OSStatus \(status)) — message not delivered")
                    }
                }
            } else {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled, let self, let port = self.outputPortIfReady else { return }
                    // Re-resolve by name at send time rather than reusing the
                    // captured `targets` — a device unplugged/replugged
                    // during the wait is handled the same way a live send is.
                    var warnedThisSend = false
                    for destination in Self.matchingDestinations(named: destinationName) {
                        let status = Self.sendWord(word, port: port, destination: destination)
                        if status != noErr, !warnedThisSend {
                            warnedThisSend = true
                            self.onWarning?("MIDI: send failed (OSStatus \(status)) — message not delivered")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Pure MIDI Send construction (D30: nonisolated + static — the
    // unit-testable core, no actor hop needed since these touch no state)

    /// MIDI 1.0 channel-voice UMP word for `body` — the exact inverse of
    /// `messages(fromWords:)`'s own parsing (message-type nibble 0x2, status
    /// byte in bits 23-16, data1 in bits 15-8, data2 in bits 7-0).
    /// programChange forces data2 to 0 — it's a single-data-byte message;
    /// `messages(fromWords:)` has no 0xC parsing arm, so this word is
    /// send-only and can't round-trip through the parser (pinned against a
    /// hand-computed constant in MIDISendTests instead).
    nonisolated static func word(for body: MIDISendBody) -> UInt32 {
        let statusNibble: UInt8
        let data2: UInt8
        switch body.kind {
        case .noteOn:
            statusNibble = 0x9
            data2 = body.value & 0x7F
        case .controlChange:
            statusNibble = 0xB
            data2 = body.value & 0x7F
        case .programChange:
            statusNibble = 0xC
            data2 = 0
        }
        return word(statusNibble: statusNibble, channel: body.channel, data1: body.number & 0x7F, data2: data2)
    }

    /// The matching noteOff for a noteOn: status 0x8n with velocity 64 (a
    /// real noteOff status, not a noteOn-with-velocity-0 — "cleanest" per
    /// D30's design).
    nonisolated static func noteOffWord(channel: UInt8, number: UInt8) -> UInt32 {
        word(statusNibble: 0x8, channel: channel, data1: number & 0x7F, data2: 64)
    }

    nonisolated private static func word(statusNibble: UInt8, channel: UInt8, data1: UInt8, data2: UInt8) -> UInt32 {
        let statusByte = (statusNibble << 4) | (channel & 0x0F)
        return (UInt32(2) << 28) | (UInt32(statusByte) << 16) | (UInt32(data1) << 8) | UInt32(data2)
    }

    /// D30: pure decision — which UMP words a `.midiSend` cue produces, and
    /// at what delay (seconds) after fire. noteOn always yields TWO entries
    /// (the noteOn immediately, its matching noteOff after `noteOffAfter` —
    /// a noteOn with no noteOff would hang a synth voice); controlChange and
    /// programChange yield exactly one. `send(_:)` drives its scheduling
    /// entirely from this — directly unit-testable without CoreMIDI.
    nonisolated static func plan(for body: MIDISendBody) -> [(word: UInt32, delay: TimeInterval)] {
        let onWord = word(for: body)
        switch body.kind {
        case .noteOn:
            return [(onWord, 0), (noteOffWord(channel: body.channel, number: body.number), body.noteOffAfter)]
        case .controlChange, .programChange:
            return [(onWord, 0)]
        }
    }

    /// Destinations whose display name matches `name` case-insensitively;
    /// "" matches every connected destination (ALL).
    private static func matchingDestinations(named name: String) -> [MIDIEndpointRef] {
        var result: [MIDIEndpointRef] = []
        let count = MIDIGetNumberOfDestinations()
        for index in 0..<count {
            let destination = MIDIGetDestination(index)
            guard destination != 0 else { continue }
            if name.isEmpty || displayName(for: destination).caseInsensitiveCompare(name) == .orderedSame {
                result.append(destination)
            }
        }
        return result
    }

    /// Send one already-built UMP word through `port` to `destination`, via
    /// the MIDIEventList protocol — mirrors the receive side's
    /// `words(from:)` in reverse: `MIDIEventListInit`/`MIDIEventListAdd`
    /// build a one-packet, one-word list, and `MIDISendEventList` hands it
    /// to CoreMIDI. Returns the raw OSStatus (`noErr` on success) so callers
    /// can surface a throttled operator warning on failure — e.g. a stale
    /// port (see the D30 lifecycle fix in `ensureOutputPort`) or a
    /// disconnected destination.
    private static func sendWord(_ word: UInt32, port: MIDIPortRef, destination: MIDIEndpointRef) -> OSStatus {
        var eventList = MIDIEventList()
        var packet = MIDIEventListInit(&eventList, ._1_0)
        var words: [UInt32] = [word]
        packet = MIDIEventListAdd(
            &eventList,
            MemoryLayout<MIDIEventList>.size,
            packet,
            0,
            words.count,
            &words
        )
        _ = packet
        return MIDISendEventList(port, destination, &eventList)
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
