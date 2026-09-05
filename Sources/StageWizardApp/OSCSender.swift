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
/// only strong reference, removed on `.failed`/`.cancelled` so the flow
/// deallocates promptly instead of leaking one small object per fire.
@MainActor
final class OSCSender {
    /// One operator warning per failed send (unreachable host, DNS failure,
    /// etc.) — wired by AppModel, same shape as `EnginePlayerProvider.onWarning`.
    /// The cue itself has ALREADY completed by the time this can fire; this
    /// is purely informational, never something GO waits on.
    var onWarning: (@MainActor (String) -> Void)?

    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let queue = DispatchQueue(label: "com.marcotempest.stagewizard.oscsend")

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
    }

    private func handleState(_ state: NWConnection.State, key: ObjectIdentifier, data: Data, host: String, port: UInt16) {
        guard let connection = connections[key] else { return }
        switch state {
        case .ready:
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
                    self?.connections.removeValue(forKey: key)
                }
            })
        case .failed(let error):
            onWarning?("OSC send to \(host):\(port) failed: \(error.localizedDescription)")
            connections.removeValue(forKey: key)
        case .cancelled:
            connections.removeValue(forKey: key)
        default:
            break
        }
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
