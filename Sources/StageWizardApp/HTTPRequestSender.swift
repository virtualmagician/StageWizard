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
/// D31-fix6: `handleCompletion` calls `finishTasksAndInvalidate()` on the
/// session it removes from `pendingSessions` — an un-invalidated
/// `URLSession` leaks its delegate machinery/queue/connection cache until
/// the app exits (Apple's documented contract), so dropping the last
/// dictionary reference alone was not enough; a show that fires
/// `.httpRequest` cues repeatedly (a status ping every scene, say) would
/// otherwise leak one session per fire for its whole runtime. The
/// configuration also sets `timeoutIntervalForResource` (not just
/// `timeoutIntervalForRequest`, which is an IDLE/inter-byte timeout that
/// never trips while a response keeps trickling in) to `body.timeout`, so a
/// streaming/never-ending response (an MJPEG or text/event-stream endpoint —
/// plausible on the LAN AV/lighting gear this feature targets) is bounded in
/// BOTH time and the memory `URLSession.dataTask` buffers the response into.
/// The response body itself is always discarded either way — only the
/// completion/status is ever used.
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
        let configuration = Self.configuration(for: body)
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
        // D31-fix6: without this, an un-invalidated URLSession leaks its
        // delegate machinery/queue/connection cache until the app exits —
        // dropping the dictionary reference alone was never enough.
        pendingSessions.removeValue(forKey: key)?.finishTasksAndInvalidate()
        if let error {
            onWarning?("HTTP \(host) failed: \(error.localizedDescription)")
            return
        }
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            onWarning?("HTTP \(host) failed: status \(http.statusCode)")
        }
    }

    /// Pure session-configuration construction — `nonisolated` and
    /// `internal` (not `private`) so tests can pin the resource-timeout bound
    /// without opening a real connection (mirrors `request(for:)` below).
    /// Ephemeral: no caching, no cookie jar — showtime purity, and every fire
    /// is independent of any previous one. D31-fix6: sets BOTH
    /// `timeoutIntervalForRequest` (idle/inter-byte — resets every time a
    /// byte arrives, so it never trips for a trickling response) AND
    /// `timeoutIntervalForResource` (the WHOLE transfer, start to finish) to
    /// `body.timeout` — a streaming/never-ending response is now bounded in
    /// time, which bounds the memory `dataTask` buffers it into as well.
    nonisolated static func configuration(for body: HTTPRequestBody) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = body.timeout
        configuration.timeoutIntervalForResource = body.timeout
        return configuration
    }

    /// Pure request construction — `nonisolated` and `internal` (not
    /// `private`) so tests can pin method/headers/timeout/body bytes
    /// without opening a real connection (mirrors `OSCSender.convert`).
    /// nil for a URL string that doesn't parse at all.
    ///
    /// D31-fix7: a non-empty, otherwise-parseable string with no scheme
    /// (e.g. a hand-edited show file's "192.168.1.50/relay1", or a value
    /// committed via tab-out/click-away — the inspector's own "http://"
    /// prepend runs only on `.onSubmit`/Return) parses FINE as a path-only
    /// URL — which is exactly what lets it slip past Preflight's
    /// `URL(string:) == nil` check, only to fail here at fire time with
    /// `NSURLErrorUnsupportedURL`. Prepend "http://" the same way the
    /// inspector's own on-commit normalization would, so fire time and
    /// preflight agree on every string preflight already treats as parseable
    /// (see `HTTPRequestTests`'s round-trip pin) — defense in depth; this
    /// doesn't require any change to Preflight itself.
    nonisolated static func request(for body: HTTPRequestBody) -> URLRequest? {
        guard let parsedURL = URL(string: body.urlString) else { return nil }
        let url: URL
        if parsedURL.scheme == nil {
            guard let schemed = URL(string: "http://" + body.urlString) else { return nil }
            url = schemed
        } else {
            url = parsedURL
        }
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
