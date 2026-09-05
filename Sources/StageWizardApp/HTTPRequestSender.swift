import Foundation

/// D31: the outbound half of the HTTP Request cue — the second OUTBOUND cue
/// type after D29's OSC Send. `.httpRequest` cues fire one request,
/// fire-and-forget — the cue completes at fire time regardless of the
/// network outcome (see `ShowRuntime.CueInstance.runHTTPRequestAction`), so
/// this class's whole job is "build a URLRequest, fire it, surface one
/// operator warning if it fails" — nothing the show ever waits on.
///
/// Concurrency: @MainActor, mirroring `OSCSender`/`MIDIController`.
/// `URLSession`'s completion handler fires on a session-internal queue,
/// never assumed to be MainActor-bound, so it's `@Sendable` and hops via
/// `Task { @MainActor in … }` before touching any actor state.
///
/// Retain-cycle note (mirrors `OSCSender.connections`): each in-flight
/// request gets its OWN ephemeral `URLSession` (so `body.timeout` — which
/// varies per cue — can set that session's `timeoutIntervalForRequest`), and
/// that session is owned by `pendingSessions`, keyed by a value-type UUID
/// generated before the task exists (not the task itself, which can't be
/// captured inside its own creation expression). The completion closure
/// captures only that key plus `[weak self]` — never the session — so there
/// is no session → closure → session cycle, and the session stays alive for
/// the life of the request regardless of ARC self-retention nuances around
/// bare local `URLSession` instances.
///
/// ATS: plain `http://` endpoints are the norm for show-control gear on a
/// closed LAN (lighting consoles, relay boxes, video switchers) — see
/// project.yml's `NSAppTransportSecurity` exemption. This class never
/// distinguishes http from https; nothing here warns about the scheme.
@MainActor
final class HTTPRequestSender {
    /// One operator warning per failed/errored request — wired by AppModel,
    /// same shape as `OSCSender.onWarning`. The cue itself has ALREADY
    /// completed by the time this can fire; purely informational.
    var onWarning: (@MainActor (String) -> Void)?

    private var pendingSessions: [UUID: URLSession] = [:]

    /// Fire one HTTP request for `body`. Two distinct guards:
    /// - empty urlString: silent no-op, no warning — callers (CueInstance)
    ///   already warn-and-skip this exact case before ever reaching here
    ///   (mirrors `OSCSender.send`'s empty-host guard), so this is just
    ///   defense in depth, never expected to fire in production.
    /// - non-empty but unparseable (bad characters, no scheme/host the
    ///   `URL` initializer rejects outright): THIS layer's own warning —
    ///   building the actual URLRequest is where "malformed" is detected.
    func send(_ body: HTTPRequestBody) {
        guard !body.urlString.isEmpty else { return }
        guard let request = Self.request(for: body) else {
            onWarning?("HTTP: “\(body.urlString)” is not a valid URL — request not sent")
            return
        }
        let host = request.url?.host ?? body.urlString
        // Ephemeral: no caching, no cookie jar — showtime purity, and every
        // fire is independent of any previous one.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = body.timeout
        let session = URLSession(configuration: configuration)
        let key = UUID()
        pendingSessions[key] = session
        let task = session.dataTask(with: request) { @Sendable [weak self] _, response, error in
            Task { @MainActor in
                self?.handleCompletion(key: key, host: host, response: response, error: error)
            }
        }
        task.resume()
    }

    private func handleCompletion(key: UUID, host: String, response: URLResponse?, error: Error?) {
        pendingSessions.removeValue(forKey: key)
        if let error {
            onWarning?("HTTP \(host) failed: \(error.localizedDescription)")
            return
        }
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            onWarning?("HTTP \(host) failed: status \(http.statusCode)")
        }
    }

    /// Pure request construction — `nonisolated` and `internal` (not
    /// `private`) so tests can pin method/headers/timeout/body bytes
    /// without opening a real connection (mirrors `OSCSender.convert`).
    /// nil for a URL string that doesn't parse at all.
    nonisolated static func request(for body: HTTPRequestBody) -> URLRequest? {
        guard let url = URL(string: body.urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = body.timeout
        switch body.method {
        case .get:
            request.httpMethod = "GET"
        case .post:
            request.httpMethod = "POST"
            request.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(body.payload.utf8)
        }
        return request
    }
}
