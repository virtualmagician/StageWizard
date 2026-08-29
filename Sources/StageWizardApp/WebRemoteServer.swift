import Foundation
import Network
import Observation

/// JSON status payload the web remote page polls (`GET /status`) — the
/// standing-by cue, how much is running, and whether the workspace is
/// currently panicking.
struct WebRemoteStatus: Codable, Equatable {
    var standingByNumber: String?
    var standingByName: String?
    var notes: String?
    var runningCount: Int
    var showMode: Bool
    var panicking: Bool
}

/// A transport-level command posted from the web remote page, ready for
/// AppModel to dispatch through TriggerRouter.
enum WebRemoteCommand: Equatable {
    case go, stopAll, panic, next, prev
}

/// The result of resolving a method+path pair against the fixed route table
/// — pure and directly unit-testable, independent of how the bytes were
/// read off the wire.
enum WebRemoteRoute: Equatable {
    case index
    case status
    case command(WebRemoteCommand)
    case notFound
    case methodNotAllowed
}

/// One fully-formed HTTP response, ready to be serialized to bytes.
struct WebRemoteHTTPResponse: Equatable {
    var status: Int
    var reason: String
    var contentType: String?
    var body: Data

    static func html(_ body: String) -> WebRemoteHTTPResponse {
        WebRemoteHTTPResponse(status: 200, reason: "OK", contentType: "text/html; charset=utf-8", body: Data(body.utf8))
    }

    static func json(_ body: Data) -> WebRemoteHTTPResponse {
        WebRemoteHTTPResponse(status: 200, reason: "OK", contentType: "application/json", body: body)
    }

    static let noContent = WebRemoteHTTPResponse(status: 204, reason: "No Content", contentType: nil, body: Data())
    static let notFound = WebRemoteHTTPResponse(
        status: 404, reason: "Not Found", contentType: "text/plain; charset=utf-8", body: Data("not found".utf8)
    )
    static let methodNotAllowed = WebRemoteHTTPResponse(
        status: 405, reason: "Method Not Allowed", contentType: "text/plain; charset=utf-8", body: Data("method not allowed".utf8)
    )
    static let serverError = WebRemoteHTTPResponse(
        status: 500, reason: "Internal Server Error", contentType: "text/plain; charset=utf-8", body: Data("internal server error".utf8)
    )
}

/// Zero-dependency TCP HTTP/1.1 server (Network.framework) serving a
/// phone-friendly GO page: web remote is TriggerRouter's third remote-control
/// client, after MIDI and OSC.
///
/// Concurrency: @MainActor, mirroring OSCServer. Network.framework delivers
/// listener state updates, new-connection callbacks, `receive` completions,
/// and `send` completions on the queue passed to `start(queue:)` — here a
/// dedicated background queue, NEVER assumed to be MainActor-bound — so
/// every closure handed to NWListener/NWConnection is `@Sendable` and hops
/// via `Task { @MainActor in … }` before touching any actor state (the exact
/// pattern OSCServer uses for UDP OSC; see its header comment for the bug
/// this guards against). Request-line parsing (`WebRemoteServer.parseRequest`),
/// route resolution (`WebRemoteServer.route(method:path:)`), and response
/// serialization (`WebRemoteServer.responseBytes`) are pure and
/// `nonisolated` — they run synchronously on the background queue inside
/// the receive callback, and only the resulting value types cross the hop.
///
/// One request per connection: no keep-alive, no chunked transfer, no
/// request bodies (ignored if present — every route this server exposes is
/// path-driven). Each connection accumulates received bytes until the
/// header terminator `\r\n\r\n`, capped at 16 KB total — a connection that
/// exceeds the cap without completing its headers is dropped rather than
/// buffered forever.
@MainActor
@Observable
final class WebRemoteServer {
    /// True once the listener has reached `.ready`. UI-facing.
    private(set) var isRunning = false
    /// Last failure message, if any — cleared on a successful start. UI-facing.
    private(set) var lastError: String?

    var onCommand: ((WebRemoteCommand) -> Void)?
    /// Pulled fresh on every `GET /status` — never cached between polls.
    var statusProvider: (() -> WebRemoteStatus)?

    /// Per-connection accumulation state. A class (not a struct) so the
    /// receive loop can mutate `buffer` in place across repeated callbacks.
    private final class Connection {
        let connection: NWConnection
        var buffer = Data()
        init(_ connection: NWConnection) { self.connection = connection }
    }

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var connections: [ObjectIdentifier: Connection] = [:]
    @ObservationIgnored private let queue = DispatchQueue(label: "com.marcotempest.stagewizard.webremote")

    init() {}

    // MARK: - Lifecycle (owned by AppModel: started/stopped with settings.webRemoteEnabled)

    /// Bind and start listening for HTTP connections on `port`. A port
    /// change is a full restart — the owner calls `stop()` then
    /// `start(port:)` again (or just `start(port:)`, which stops any
    /// previous listener first) rather than this class watching for changes
    /// reactively.
    func start(port: UInt16) {
        stop()

        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            lastError = "Invalid web remote port \(port)"
            return
        }

        let newListener: NWListener
        do {
            newListener = try NWListener(using: .tcp, on: endpointPort)
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
        for state in connections.values {
            state.connection.cancel()
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
        connections[key] = Connection(connection)
        connection.stateUpdateHandler = { @Sendable [weak self] state in
            Task { @MainActor in
                self?.handleConnectionState(state, key: key)
            }
        }
        connection.start(queue: queue)
        receiveNext(key: key)
    }

    private func handleConnectionState(_ state: NWConnection.State, key: ObjectIdentifier) {
        switch state {
        case .failed, .cancelled:
            connections.removeValue(forKey: key)
        default:
            break
        }
    }

    private static let maxRequestBytes = 16 * 1024
    private static let headerTerminator: [UInt8] = Array("\r\n\r\n".utf8)

    /// Accumulate bytes for one connection until the header terminator
    /// shows up (respond), the 16 KB cap is exceeded (drop), or the
    /// connection closes/errors before either happens (drop). We never need
    /// the body of a request, so nothing past the terminator is read.
    private func receiveNext(key: ObjectIdentifier) {
        guard let state = connections[key] else { return }
        let connection = state.connection
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { @Sendable [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, let state = self.connections[key] else { return }
                if let data, !data.isEmpty {
                    state.buffer.append(data)
                }
                if let range = state.buffer.firstRange(of: WebRemoteServer.headerTerminator) {
                    let head = String(decoding: state.buffer[..<range.lowerBound], as: UTF8.self)
                    self.respond(to: head, on: state, key: key)
                    return
                }
                if state.buffer.count > WebRemoteServer.maxRequestBytes || isComplete || error != nil {
                    connection.cancel()
                    self.connections.removeValue(forKey: key)
                    return
                }
                self.receiveNext(key: key)
            }
        }
    }

    private func respond(to head: String, on state: Connection, key: ObjectIdentifier) {
        let response: WebRemoteHTTPResponse
        if let request = WebRemoteServer.parseRequest(head) {
            response = resolve(method: request.method, path: request.path)
        } else {
            response = .notFound
        }
        let bytes = WebRemoteServer.responseBytes(response)
        // The completion closure is @Sendable and may run on the background
        // queue — capture only `key` (a Sendable value) and `self` (weakly)
        // rather than `state` (a non-Sendable class), then re-look-up the
        // connection on the MainActor hop before touching it.
        state.connection.send(content: bytes, completion: .contentProcessed { @Sendable [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.connections[key]?.connection.cancel()
                self.connections.removeValue(forKey: key)
            }
        })
    }

    private func resolve(method: String, path: String) -> WebRemoteHTTPResponse {
        switch WebRemoteServer.route(method: method, path: path) {
        case .index:
            return .html(WebRemotePage.html)
        case .status:
            let status = statusProvider?() ?? WebRemoteStatus(
                standingByNumber: nil, standingByName: nil, notes: nil,
                runningCount: 0, showMode: false, panicking: false
            )
            guard let data = try? JSONEncoder().encode(status) else { return .serverError }
            return .json(data)
        case .command(let command):
            onCommand?(command)
            return .noContent
        case .notFound:
            return .notFound
        case .methodNotAllowed:
            return .methodNotAllowed
        }
    }

    // MARK: - Pure HTTP parsing/routing/serialization (nonisolated + static:
    // no actor hop needed, and directly unit-testable)

    /// The request line only ("METHOD /path HTTP/1.1") — headers are parsed
    /// no further than that, since routing needs nothing else. Tolerates a
    /// query string by truncating the path at the first `?`. Malformed or
    /// empty input (no method/path pair) returns nil.
    nonisolated static func parseRequest(_ head: String) -> (method: String, path: String)? {
        guard let requestLine = head.split(separator: "\r\n", omittingEmptySubsequences: false).first,
              !requestLine.isEmpty else { return nil }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }

        let method = String(parts[0])
        var path = String(parts[1])
        if let queryStart = path.firstIndex(of: "?") {
            path = String(path[path.startIndex..<queryStart])
        }
        guard !path.isEmpty else { return nil }
        return (method, path)
    }

    /// Fixed route table: `GET /` the page, `GET /status` live JSON,
    /// `POST` on any transport verb, everything else 404 — except a known
    /// path hit with the wrong method, which is 405 rather than 404 so a
    /// misbehaving client can tell "wrong verb" from "no such route".
    nonisolated static func route(method: String, path: String) -> WebRemoteRoute {
        switch (method, path) {
        case ("GET", "/"): return .index
        case ("GET", "/status"): return .status
        case ("POST", "/go"): return .command(.go)
        case ("POST", "/stopall"): return .command(.stopAll)
        case ("POST", "/panic"): return .command(.panic)
        case ("POST", "/next"): return .command(.next)
        case ("POST", "/prev"): return .command(.prev)
        default:
            return knownPaths.contains(path) ? .methodNotAllowed : .notFound
        }
    }

    nonisolated private static let knownPaths: Set<String> = ["/", "/status", "/go", "/stopall", "/panic", "/next", "/prev"]

    /// Full HTTP/1.1 response bytes: status line, headers, blank line, body.
    /// Always `Connection: close` — this server never keeps a connection
    /// alive past one response. `Content-Length` is the body's BYTE count
    /// (`Data.count`), not its character count, so multibyte UTF-8 bodies
    /// report correctly.
    nonisolated static func responseBytes(_ response: WebRemoteHTTPResponse) -> Data {
        var head = "HTTP/1.1 \(response.status) \(response.reason)\r\n"
        if let contentType = response.contentType {
            head += "Content-Type: \(contentType)\r\n"
        }
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Connection: close\r\n"
        head += "\r\n"
        var bytes = Data(head.utf8)
        bytes.append(response.body)
        return bytes
    }
}
