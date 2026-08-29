import Foundation
import Network
import Observation

/// A parsed OSC 1.0 message: an address pattern plus its typed arguments.
struct OSCMessage: Equatable {
    var address: String
    var arguments: [OSCArgument]
}

/// The OSC argument types this parser understands. Any other type tag
/// aborts parsing of the enclosing message (see `OSCServer.parseMessage`).
enum OSCArgument: Equatable {
    case int32(Int32)
    case float32(Float)
    case string(String)
}

/// A transport-level command resolved from an OSC address, ready for
/// AppModel to dispatch through TriggerRouter.
enum OSCCommand: Equatable {
    case action(ShortcutAction)
    case panic
    case fireCue(number: String)
    /// D21: stand a cue by (playhead only) WITHOUT firing it — see
    /// `TriggerRouter.route(selectCueNumber:)`.
    case selectCue(number: String)
}

/// D21: tracks OSC feedback subscribers — any source endpoint heard from
/// (any inbound datagram, `/stagewand/ping` keepalives included) within the
/// last `timeout` seconds counts as "live". A pure, generic value type
/// (keyed by any `Hashable` endpoint, not tied to `NWEndpoint`) so it's
/// directly unit-testable with a fake clock and no real socket — mirrors
/// `TransportController.now`'s injectable-clock convention. `OSCServer`
/// holds one instance keyed by `NWEndpoint` (the real socket-level type,
/// itself constructible purely — `.hostPort(host:port:)` — so even the
/// production key type needs no live connection to test against).
struct OSCSubscriberRegistry<Endpoint: Hashable> {
    /// How long a subscriber stays "live" after its last-heard datagram —
    /// fixed by the wire contract (D21 handoff), not configurable.
    static var timeout: TimeInterval { 5 }

    private var lastHeard: [Endpoint: TimeInterval] = [:]
    /// Injectable clock — real default is wall-clock seconds; tests supply
    /// their own monotonically-increasing closure to drive pruning without
    /// real sleeps.
    var now: () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }

    init(now: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }) {
        self.now = now
    }

    /// Record a datagram from `endpoint` at the current time. Returns `true`
    /// when this is a NEW subscriber — first contact ever, or a return after
    /// having gone stale and been pruned — the trigger for a full status
    /// refresh to that endpoint alone. Prunes stale entries first so a
    /// returning endpoint is correctly detected as "new" rather than
    /// silently refreshing a timestamp that should already be gone.
    @discardableResult
    mutating func touch(_ endpoint: Endpoint) -> Bool {
        let t = now()
        prune(at: t)
        let isNewSubscriber = lastHeard[endpoint] == nil
        lastHeard[endpoint] = t
        return isNewSubscriber
    }

    /// Endpoints heard from within the last `timeout` seconds, as of right
    /// now — pruning first so a stale entry is never reported live.
    mutating func liveEndpoints() -> Set<Endpoint> {
        prune(at: now())
        return Set(lastHeard.keys)
    }

    private mutating func prune(at t: TimeInterval) {
        lastHeard = lastHeard.filter { t - $0.value <= Self.timeout }
    }
}

/// Zero-dependency UDP OSC 1.0 listener (Network.framework): parses incoming
/// datagrams into commands and hands them to `onCommand` — OSC is
/// TriggerRouter's second remote-control client, after MIDI. D21 adds the
/// reverse direction: outbound status FEEDBACK to any live subscriber (an
/// endpoint heard from within the last 5s — see `OSCSubscriberRegistry`),
/// so a hardware controller (StageWand) never has to poll HTTP. The
/// listener also advertises itself over Bonjour (`_stagewizard._udp`) so a
/// subscriber can find it without a hardcoded IP. AppModel supplies the
/// actual status content via `fullRefreshProvider` and drives periodic
/// `broadcast(_:)` calls — this class only owns the wire mechanics
/// (encode/send/subscriber-tracking), never show state.
///
/// Concurrency: @MainActor, mirroring MIDIController. Network.framework
/// delivers listener state updates, new-connection callbacks, and
/// `receiveMessage` completions on the queue passed to `start(queue:)` —
/// here a dedicated background queue, NEVER assumed to be MainActor-bound —
/// so every closure handed to NWListener/NWConnection is `@Sendable` and
/// hops via `Task { @MainActor in … }` before touching any actor state
/// (the exact pattern MIDIController uses for CoreMIDI; see its header
/// comment for the bug this guards against). Datagram parsing
/// (`OSCServer.parse`, `OSCServer.command(for:)`) is pure and `nonisolated`
/// — it runs synchronously on the background queue inside the receive
/// callback, and only the resulting value-type `OSCCommand`s are handed
/// across the hop.
@MainActor
@Observable
final class OSCServer {
    /// True once the listener has reached `.ready`. UI-facing.
    private(set) var isRunning = false
    /// Last failure message, if any — cleared on a successful start. UI-facing.
    private(set) var lastError: String?

    var onCommand: ((OSCCommand) -> Void)?

    /// D21: called synchronously whenever a NEW subscriber is detected
    /// (first datagram, or a return after being pruned) — must return the
    /// FULL current status feed (every P1+P2 address), which is sent to
    /// that subscriber's connection alone. AppModel wires this to
    /// `OSCStatusFeedback.changedMessages(old: nil, new: currentSnapshot())`.
    /// OSCServer itself knows nothing about show state — this closure is the
    /// only bridge, exactly like `onCommand` is for inbound routing.
    var fullRefreshProvider: (() -> [OSCMessage])?

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var connections: [ObjectIdentifier: NWConnection] = [:]
    @ObservationIgnored private let queue = DispatchQueue(label: "com.marcotempest.stagewizard.osc")
    /// D21: last-heard timestamp per source endpoint — see
    /// `OSCSubscriberRegistry`. Keyed by the real `NWEndpoint` (the remote
    /// address of whichever per-flow `NWConnection` a datagram arrived on).
    @ObservationIgnored private var subscribers = OSCSubscriberRegistry<NWEndpoint>()

    /// Bonjour service type this listener advertises itself under — no
    /// `NSBonjourServices` entry needed (that key is for BROWSING, not
    /// advertising). Name defaults to the host name.
    private static let bonjourServiceType = "_stagewizard._udp"

    init() {}

    // MARK: - Lifecycle (owned by AppModel: started/stopped with settings.oscEnabled)

    /// Bind and start listening for OSC datagrams on `port`. A port change
    /// is a full restart — the owner calls `stop()` then `start(port:)`
    /// again (or just `start(port:)`, which stops any previous listener
    /// first) rather than this class watching for changes reactively.
    func start(port: UInt16) {
        stop()

        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            lastError = "Invalid OSC port \(port)"
            return
        }

        let newListener: NWListener
        do {
            newListener = try NWListener(using: .udp, on: endpointPort)
        } catch {
            lastError = error.localizedDescription
            return
        }
        // Bonjour advertising (D21/P3) — must be set before `start(queue:)`.
        newListener.service = NWListener.Service(type: Self.bonjourServiceType)

        newListener.stateUpdateHandler = { @Sendable [weak self] state in
            Task { @MainActor in
                // A restart (stop() then start()) can leave the OLD
                // listener's stateUpdateHandler with a late .cancelled/
                // .failed still in flight when the new listener is already
                // up — without this identity check that stale callback would
                // corrupt the NEW listener's isRunning, or even stop() it via
                // the .failed branch. `listener?.stateUpdateHandler = nil` in
                // stop() closes most of this window, but the check stays as
                // the actual guarantee.
                guard let self, self.listener === newListener else { return }
                self.handleListenerState(state)
            }
        }
        newListener.newConnectionHandler = { @Sendable [weak self] connection in
            Task { @MainActor in
                self?.accept(connection)
            }
        }

        listener = newListener
        newListener.start(queue: queue)
    }

    func stop() {
        for connection in connections.values {
            connection.cancel()
        }
        connections.removeAll()
        subscribers = OSCSubscriberRegistry<NWEndpoint>()
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    // MARK: - Listener/connection handling (MainActor — reached only via the hop above)

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            isRunning = true
            lastError = nil
        case .failed(let error):
            lastError = error.localizedDescription
            stop()
        case .cancelled:
            isRunning = false
        default:
            break
        }
    }

    /// Cap on concurrently tracked UDP flows — hostile-input hardening. No
    /// idle timer is needed (unlike the web remote's TCP connections): UDP
    /// flows are cheap, so the cap alone is the guard against unbounded growth.
    private static let maxTrackedFlows = 64

    private func accept(_ connection: NWConnection) {
        guard connections.count < Self.maxTrackedFlows else {
            connection.cancel()
            return
        }
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        connection.stateUpdateHandler = { @Sendable [weak self] state in
            Task { @MainActor in
                self?.handleConnectionState(state, key: key)
            }
        }
        connection.start(queue: queue)
        receiveNext(on: connection, key: key)
    }

    private func handleConnectionState(_ state: NWConnection.State, key: ObjectIdentifier) {
        switch state {
        case .failed, .cancelled:
            connections.removeValue(forKey: key)
        default:
            break
        }
    }

    /// Loop `receiveMessage` on one UDP flow for as long as it stays open —
    /// each completion runs on the background queue, so the datagram is
    /// parsed there (pure/nonisolated) and only the resulting commands cross
    /// the MainActor hop.
    private func receiveNext(on connection: NWConnection, key: ObjectIdentifier) {
        connection.receiveMessage { @Sendable [weak self] data, _, _, error in
            let receivedDatagram = data != nil
            let commands: [OSCCommand] = {
                guard let data, !data.isEmpty else { return [] }
                return OSCServer.parse(data).compactMap { OSCServer.command(for: $0.address) }
            }()
            Task { @MainActor in
                guard let self, self.connections[key] != nil else { return }
                // D21: ANY inbound datagram counts as "heard from" for
                // subscriber purposes — including `/stagewand/ping` (a
                // dedicated keepalive) and anything that fails to parse.
                // This must run before dispatching commands so a brand-new
                // subscriber's very first real command still arrives after
                // its full refresh, not before.
                if receivedDatagram {
                    self.noteSubscriber(connection)
                }
                for command in commands {
                    self.onCommand?(command)
                }
                guard error == nil else {
                    connection.cancel()
                    self.connections.removeValue(forKey: key)
                    return
                }
                self.receiveNext(on: connection, key: key)
            }
        }
    }

    // MARK: - D21: OSC status feedback (MainActor — subscriber tracking +
    // outbound send; content comes entirely from AppModel via the closures
    // above, so this class stays ignorant of show state)

    /// Touch the subscriber registry for `connection`'s remote endpoint; a
    /// brand-new (or pruned-and-returning) subscriber gets an immediate,
    /// full status refresh on this connection alone.
    private func noteSubscriber(_ connection: NWConnection) {
        guard subscribers.touch(connection.endpoint) else { return }
        guard let fullRefreshProvider else { return }
        for message in fullRefreshProvider() {
            send(message, on: connection)
        }
    }

    /// Send one OSC message to every currently-live subscriber, each on its
    /// own already-open per-flow connection — no new socket. No-op while the
    /// listener isn't running (feedback rides `oscEnabled`/the listener
    /// lifecycle, same as everything else here).
    func broadcast(_ messages: [OSCMessage]) {
        guard isRunning, !messages.isEmpty else { return }
        let live = subscribers.liveEndpoints()
        guard !live.isEmpty else { return }
        for connection in connections.values where live.contains(connection.endpoint) {
            for message in messages {
                send(message, on: connection)
            }
        }
    }

    private func send(_ message: OSCMessage, on connection: NWConnection) {
        let data = OSCServer.encode(address: message.address, arguments: message.arguments)
        connection.send(content: data, completion: .idempotent)
    }

    // MARK: - Pure OSC 1.0 encoding (nonisolated + static: no actor hop
    // needed, and directly unit-testable — exact mirror of the parsing
    // section below: same 4-byte-padded address/type-tag/argument layout,
    // same big-endian i/f. `parse(encode(address:arguments:))` round-trips
    // to `[OSCMessage(address:arguments:)]` for every argument combination
    // this parser understands — see OSCFeedbackTests.

    nonisolated static func encode(address: String, arguments: [OSCArgument]) -> Data {
        var data = encodeOSCString(address)
        var tags = ","
        for argument in arguments {
            switch argument {
            case .int32: tags.append("i")
            case .float32: tags.append("f")
            case .string: tags.append("s")
            }
        }
        data.append(encodeOSCString(tags))
        for argument in arguments {
            switch argument {
            case .int32(let value): data.append(encodeInt32(value))
            case .float32(let value): data.append(encodeFloat32(value))
            case .string(let value): data.append(encodeOSCString(value))
            }
        }
        return data
    }

    /// UTF-8 bytes, one null terminator, padded with more nulls to a 4-byte
    /// boundary — exactly what `readOSCString` below expects to consume.
    nonisolated private static func encodeOSCString(_ value: String) -> Data {
        var data = Data(value.utf8)
        data.append(0)
        while data.count % 4 != 0 { data.append(0) }
        return data
    }

    nonisolated private static func encodeInt32(_ value: Int32) -> Data {
        let bits = UInt32(bitPattern: value)
        return Data([UInt8((bits >> 24) & 0xFF), UInt8((bits >> 16) & 0xFF), UInt8((bits >> 8) & 0xFF), UInt8(bits & 0xFF)])
    }

    nonisolated private static func encodeFloat32(_ value: Float) -> Data {
        let bits = value.bitPattern
        return Data([UInt8((bits >> 24) & 0xFF), UInt8((bits >> 16) & 0xFF), UInt8((bits >> 8) & 0xFF), UInt8(bits & 0xFF)])
    }

    // MARK: - Pure OSC 1.0 parsing (nonisolated + static: no actor hop
    // needed, and directly unit-testable)

    /// Entry point: a bare OSC message, or a `#bundle` containing (possibly
    /// nested) messages/bundles. Malformed input yields an empty array
    /// rather than throwing — a bad remote datagram should never crash or
    /// spam the operator.
    nonisolated static func parse(_ data: Data) -> [OSCMessage] {
        if data.starts(with: bundleTag) {
            return parseBundle(data, depth: 0)
        }
        if let message = parseMessage(data) {
            return [message]
        }
        return []
    }

    nonisolated private static let bundleTag = Data("#bundle\0".utf8)
    /// Recursion cap for nested #bundle elements — a crafted datagram with
    /// deeply nested bundles could otherwise blow the worker (background
    /// queue) stack. Beyond this depth, parsing that branch aborts silently
    /// (returns []) rather than crashing.
    nonisolated private static let maxBundleDepth = 8

    /// One OSC message: an address pattern, then a type-tag string, then one
    /// argument per tag. An unrecognized type tag aborts parsing of the
    /// WHOLE message (returns nil) rather than a partial argument list —
    /// OSC arguments aren't self-describing, so once a tag is unrecognized
    /// its width (and therefore every argument after it) can't be trusted.
    nonisolated static func parseMessage(_ data: Data) -> OSCMessage? {
        guard let (address, afterAddress) = readOSCString(data, at: data.startIndex),
              address.hasPrefix("/") else { return nil }
        guard let (typeTags, afterTags) = readOSCString(data, at: afterAddress),
              typeTags.hasPrefix(",") else { return nil }

        var arguments: [OSCArgument] = []
        var cursor = afterTags
        for tag in typeTags.dropFirst() {
            switch tag {
            case "i":
                guard let (value, next) = readInt32(data, at: cursor) else { return nil }
                arguments.append(.int32(value))
                cursor = next
            case "f":
                guard let (value, next) = readFloat32(data, at: cursor) else { return nil }
                arguments.append(.float32(value))
                cursor = next
            case "s":
                guard let (value, next) = readOSCString(data, at: cursor) else { return nil }
                arguments.append(.string(value))
                cursor = next
            default:
                return nil
            }
        }
        return OSCMessage(address: address, arguments: arguments)
    }

    /// `#bundle` element: 8-byte "#bundle\0" tag + 8-byte NTP timetag
    /// (ignored — StageWizard fires everything immediately), then a
    /// sequence of 4-byte-size-prefixed elements, each itself a message or
    /// a nested bundle.
    nonisolated private static func parseBundle(_ data: Data, depth: Int) -> [OSCMessage] {
        guard depth <= maxBundleDepth else { return [] }
        let headerSize = 16
        guard data.count >= headerSize else { return [] }

        var cursor = data.startIndex + headerSize
        var result: [OSCMessage] = []
        while cursor < data.endIndex {
            guard let (size, afterSize) = readInt32(data, at: cursor), size >= 0 else { break }
            let elementEnd = afterSize + Int(size)
            guard elementEnd <= data.endIndex else { break }
            let element = data.subdata(in: afterSize..<elementEnd)
            if element.starts(with: bundleTag) {
                result.append(contentsOf: parseBundle(element, depth: depth + 1))
            } else if let message = parseMessage(element) {
                result.append(message)
            }
            cursor = elementEnd
        }
        return result
    }

    /// An OSC-string: bytes up to (not including) the first null, followed
    /// by 1-4 null bytes so the total consumed length is a multiple of 4.
    nonisolated private static func readOSCString(_ data: Data, at index: Data.Index) -> (value: String, next: Data.Index)? {
        guard index <= data.endIndex, let nullIndex = data[index...].firstIndex(of: 0) else { return nil }
        guard let string = String(bytes: data[index..<nullIndex], encoding: .utf8) else { return nil }
        let consumed = nullIndex - index + 1
        let padded = ((consumed + 3) / 4) * 4
        let next = index + padded
        guard next <= data.endIndex else { return nil }
        return (string, next)
    }

    /// Big-endian 4-byte two's-complement integer.
    nonisolated private static func readInt32(_ data: Data, at index: Data.Index) -> (value: Int32, next: Data.Index)? {
        guard let next = data.index(index, offsetBy: 4, limitedBy: data.endIndex) else { return nil }
        let raw = data[index..<next].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return (Int32(bitPattern: raw), next)
    }

    /// Big-endian 4-byte IEEE-754 float (bit pattern, not value, is what's
    /// transmitted in network order).
    nonisolated private static func readFloat32(_ data: Data, at index: Data.Index) -> (value: Float, next: Data.Index)? {
        guard let next = data.index(index, offsetBy: 4, limitedBy: data.endIndex) else { return nil }
        let raw = data[index..<next].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return (Float(bitPattern: raw), next)
    }

    // MARK: - Pure routing table (nonisolated + static: directly unit-testable)

    /// Fixed OSC address map. Anything unrecognized (including a malformed
    /// `/stagewizard/cue/.../fire` or `.../select`, and `/stagewand/ping` —
    /// the wand's dedicated keepalive) returns nil — a remote surface has no
    /// operator-facing warning UI, so unknown addresses are ignored silently.
    /// (`/stagewand/ping` still counts as a live subscriber — see
    /// `noteSubscriber`, which runs on every inbound datagram regardless of
    /// whether it resolves to a command here.)
    nonisolated static func command(for address: String) -> OSCCommand? {
        switch address {
        case "/stagewizard/go": return .action(.go)
        case "/stagewizard/stopall": return .action(.stopAll)
        case "/stagewizard/next": return .action(.nextCue)
        case "/stagewizard/prev": return .action(.previousCue)
        case "/stagewizard/toggle": return .action(.togglePlayback)
        case "/stagewizard/panic": return .panic
        default:
            return fireCueCommand(for: address) ?? selectCueCommand(for: address)
        }
    }

    nonisolated private static let cuePrefix = "/stagewizard/cue/"
    nonisolated private static let fireSuffix = "/fire"
    nonisolated private static let selectSuffix = "/select"

    /// Shared prefix/suffix stripping for `/stagewizard/cue/<number>/<suffix>`
    /// addresses — `<number>` is free text (dotted numbers like "10.5" are
    /// normal), so it's just "whatever sits between the fixed prefix and
    /// suffix, provided it's non-empty and contains no further slash".
    nonisolated private static func cueNumber(in address: String, suffix: String) -> String? {
        guard address.hasPrefix(cuePrefix), address.hasSuffix(suffix) else { return nil }
        let start = address.index(address.startIndex, offsetBy: cuePrefix.count)
        let end = address.index(address.endIndex, offsetBy: -suffix.count)
        guard start < end else { return nil }
        let number = String(address[start..<end])
        guard !number.isEmpty, !number.contains("/") else { return nil }
        return number
    }

    nonisolated private static func fireCueCommand(for address: String) -> OSCCommand? {
        cueNumber(in: address, suffix: fireSuffix).map { .fireCue(number: $0) }
    }

    /// D21: `/stagewizard/cue/<number>/select` — stand the cue by without
    /// firing. See `TriggerRouter.route(selectCueNumber:)` for resolution.
    nonisolated private static func selectCueCommand(for address: String) -> OSCCommand? {
        cueNumber(in: address, suffix: selectSuffix).map { .selectCue(number: $0) }
    }
}
