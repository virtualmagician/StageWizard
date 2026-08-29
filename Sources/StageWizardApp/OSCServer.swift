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
}

/// Zero-dependency UDP OSC 1.0 listener (Network.framework): parses incoming
/// datagrams into commands and hands them to `onCommand` — OSC is
/// TriggerRouter's second remote-control client, after MIDI.
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

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var connections: [ObjectIdentifier: NWConnection] = [:]
    @ObservationIgnored private let queue = DispatchQueue(label: "com.marcotempest.stagewizard.osc")

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

        newListener.stateUpdateHandler = { @Sendable [weak self] state in
            Task { @MainActor in
                self?.handleListenerState(state)
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

    private func accept(_ connection: NWConnection) {
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
            let commands: [OSCCommand] = {
                guard let data, !data.isEmpty else { return [] }
                return OSCServer.parse(data).compactMap { OSCServer.command(for: $0.address) }
            }()
            Task { @MainActor in
                guard let self, self.connections[key] != nil else { return }
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

    // MARK: - Pure OSC 1.0 parsing (nonisolated + static: no actor hop
    // needed, and directly unit-testable)

    /// Entry point: a bare OSC message, or a `#bundle` containing (possibly
    /// nested) messages/bundles. Malformed input yields an empty array
    /// rather than throwing — a bad remote datagram should never crash or
    /// spam the operator.
    nonisolated static func parse(_ data: Data) -> [OSCMessage] {
        if data.starts(with: bundleTag) {
            return parseBundle(data)
        }
        if let message = parseMessage(data) {
            return [message]
        }
        return []
    }

    nonisolated private static let bundleTag = Data("#bundle\0".utf8)

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
    nonisolated private static func parseBundle(_ data: Data) -> [OSCMessage] {
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
                result.append(contentsOf: parseBundle(element))
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
    /// `/stagewizard/cue/.../fire`) returns nil — a remote surface has no
    /// operator-facing warning UI, so unknown addresses are ignored silently.
    nonisolated static func command(for address: String) -> OSCCommand? {
        switch address {
        case "/stagewizard/go": return .action(.go)
        case "/stagewizard/stopall": return .action(.stopAll)
        case "/stagewizard/next": return .action(.nextCue)
        case "/stagewizard/prev": return .action(.previousCue)
        case "/stagewizard/toggle": return .action(.togglePlayback)
        case "/stagewizard/panic": return .panic
        default:
            return fireCueCommand(for: address)
        }
    }

    nonisolated private static let cuePrefix = "/stagewizard/cue/"
    nonisolated private static let cueSuffix = "/fire"

    nonisolated private static func fireCueCommand(for address: String) -> OSCCommand? {
        guard address.hasPrefix(cuePrefix), address.hasSuffix(cueSuffix) else { return nil }
        let start = address.index(address.startIndex, offsetBy: cuePrefix.count)
        let end = address.index(address.endIndex, offsetBy: -cueSuffix.count)
        guard start < end else { return nil }   // no number between "cue/" and "/fire"
        let number = String(address[start..<end])
        guard !number.isEmpty, !number.contains("/") else { return nil }
        return .fireCue(number: number)
    }
}
