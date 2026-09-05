import Foundation
import Network

/// D29: the outbound half of OSC. `.oscSend` cues fire one message,
/// fire-and-forget — the cue completes at fire time regardless of the
/// network outcome (see `ShowRuntime.CueInstance.runOSCSendAction`), so this
/// class's whole job is "start a one-shot UDP flow, send once, clean up",
/// surfacing a single operator warning if the flow ever fails.
///
/// Concurrency: @MainActor, mirroring `OSCServer`. Network.framework
/// delivers `NWConnection` state updates on the queue passed to
/// `start(queue:)` — a dedicated background queue, never assumed to be
/// MainActor-bound — so the handler is `@Sendable` and hops via
/// `Task { @MainActor in … }` before touching any actor state, the same
/// pattern `OSCServer`/`MIDIController` use.
///
/// Retain-cycle note (mirrors `OSCServer.accept`/`handleConnectionState`):
/// each in-flight connection is owned by `connections`, keyed by
/// `ObjectIdentifier`. `stateUpdateHandler` captures only that key (a value
/// type) plus `[weak self]` — never the connection itself — so there is no
/// connection → handler → connection cycle; the dictionary entry is the
/// only strong reference, removed on `.failed`/`.waiting`/`.cancelled` (and
/// on completed send) so the flow deallocates promptly instead of leaking
/// one small object per fire.
///
/// D28-fix5: `.waiting` (no route/unreachable host/DNS failure) is treated
/// as a FAILURE for this one-shot fire-and-forget flow, not a "retry later"
/// state — Network.framework retries `.waiting` indefinitely and has no
/// connect timeout of its own, so leaving it alone would (a) leak the
/// `connections` entry forever and (b) — worse — deliver the datagram LATE
/// if the network recovers mid-show, which for a show-control message (a
/// lighting/video GO) is a hazard, not a courtesy. A 3-second deadline Task
/// per send backstops any state that never transitions at all.
@MainActor
final class OSCSender {
    /// One operator warning per failed send (unreachable host, DNS failure,
    /// etc.) — wired by AppModel, same shape as `EnginePlayerProvider.onWarning`.
    /// The cue itself has ALREADY completed by the time this can fire; this
    /// is purely informational, never something GO waits on.
    var onWarning: (@MainActor (String) -> Void)?

    private var connections: [ObjectIdentifier: NWConnection] = [:]
    /// D28-fix5: one deadline per in-flight connection, cancelled on every
    /// removal path (success, `.failed`, `.waiting`, `.cancelled`) — see
    /// `cleanUp(key:)`, the single funnel every path routes through.
    private var deadlines: [ObjectIdentifier: Task<Void, Never>] = [:]
    private let queue = DispatchQueue(label: "com.marcotempest.stagewizard.oscsend")
    /// How long a send may sit without reaching `.ready`/`.failed` before
    /// this class gives up on it unilaterally (unreachable host with no
    /// route, a state that never transitions at all).
    private static let sendDeadline: TimeInterval = 3

    /// Fire one OSC message at `body.host:body.port`. No-op if the host is
    /// empty or the port can't form a valid endpoint — callers (CueInstance)
    /// already warn-and-skip an empty host before ever reaching here, so this
    /// guard is just defense in depth.
    func send(_ body: OSCSendBody) {
        guard !body.host.isEmpty, let port = NWEndpoint.Port(rawValue: body.port) else { return }
        let data = OSCServer.encode(address: body.address, arguments: body.arguments.map(Self.convert))
        let host = body.host
        let rawPort = body.port
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .udp)
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        connection.stateUpdateHandler = { @Sendable [weak self] state in
            Task { @MainActor in
                self?.handleState(state, key: key, data: data, host: host, port: rawPort)
            }
        }
        connection.start(queue: queue)
        deadlines[key] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.sendDeadline))
            guard !Task.isCancelled, let self, self.connections[key] != nil else { return }
            self.onWarning?("OSC send to \(host):\(rawPort) unreachable")
            self.connections[key]?.cancel()
            self.cleanUp(key: key)
        }
    }

    private func handleState(_ state: NWConnection.State, key: ObjectIdentifier, data: Data, host: String, port: UInt16) {
        guard let connection = connections[key] else { return }
        if case .ready = state {
            // Fire-and-forget, but NOT "cancel immediately after enqueueing":
            // `NWConnection.cancel()` can drop an outstanding send that
            // hasn't been handed to the transport yet, so tearing the flow
            // down waits for `.contentProcessed` — the documented signal
            // that the datagram actually left. The completion closure
            // capturing `connection` is a one-shot handler Network.framework
            // releases once it fires (like `OSCServer.receiveNext`'s
            // completion, not a stored `stateUpdateHandler`), so this isn't
            // the same retain-cycle shape the class header warns about.
            connection.send(content: data, completion: .contentProcessed { @Sendable [weak self] _ in
                Task { @MainActor in
                    connection.cancel()
                    self?.cleanUp(key: key)
                }
            })
            return
        }
        switch Self.outcome(for: state, host: host, port: port) {
        case .ignore:
            break
        case .warnAndCleanUp(let message):
            onWarning?(message)
            connection.cancel()
            cleanUp(key: key)
        case .cleanUpSilently:
            cleanUp(key: key)
        }
    }

    /// D28-fix5: pure classification of a (non-`.ready`) state transition —
    /// factored out so tests can pin ".waiting is treated as failure"
    /// without opening a real socket (constructing an `NWConnection.State`
    /// value needs no live connection). `.ready` is handled directly in
    /// `handleState` since it needs `data`/the connection itself to actually
    /// send, so it's deliberately not part of this decision.
    enum StateOutcome: Equatable {
        case ignore
        case warnAndCleanUp(message: String)
        case cleanUpSilently
    }

    nonisolated static func outcome(for state: NWConnection.State, host: String, port: UInt16) -> StateOutcome {
        switch state {
        case .failed(let error):
            return .warnAndCleanUp(message: "OSC send to \(host):\(port) failed: \(error.localizedDescription)")
        case .waiting:
            // Treated as a FAILURE, not "still trying" — see the class
            // header: Network.framework retries `.waiting` indefinitely with
            // no connect timeout of its own, and a stale datagram delivered
            // late (once the network recovers mid-show) is a hazard, not a
            // courtesy. Message deliberately matches the deadline task's own
            // wording — the operator sees one consistent phrase regardless
            // of which of the two paths caught it.
            return .warnAndCleanUp(message: "OSC send to \(host):\(port) unreachable")
        case .cancelled:
            return .cleanUpSilently
        default:
            return .ignore
        }
    }

    /// The single funnel every removal path routes through — guarantees the
    /// deadline task is always cancelled alongside the connection entry, so
    /// a connection that finishes (by any route) never leaves a stray timer
    /// running, and the 3-second deadline never fires a second, spurious
    /// warning after the flow has already been accounted for.
    private func cleanUp(key: ObjectIdentifier) {
        connections.removeValue(forKey: key)
        deadlines.removeValue(forKey: key)?.cancel()
    }

    /// The model→wire argument conversion — pure, so `nonisolated` (mirrors
    /// `OSCServer.encode`/`parse`) and `internal` (not `private`) so tests
    /// can pin the round trip through `OSCServer.encode`/`parse` without
    /// opening a real socket (see OSCSendTests).
    nonisolated static func convert(_ argument: OSCSendArgument) -> OSCArgument {
        switch argument {
        case .int32(let value): return .int32(value)
        case .float(let value): return .float32(Float(value))
        case .string(let value): return .string(value)
        }
    }
}
