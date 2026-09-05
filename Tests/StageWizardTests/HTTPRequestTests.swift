import XCTest
@testable import StageWizard

/// D31: the HTTP Request cue — the second OUTBOUND cue type after D29's OSC
/// Send. Covers the model (Codable round trip, stripped-key defaults,
/// timeout clamp, forward-compat), the runtime action (fires exactly once
/// via an injected closure, completes immediately like a stop cue, an empty
/// urlString is a warned no-op AT THE RUNTIME LAYER, preWait honored, never
/// blocks GO), and `HTTPRequestSender`'s pure request construction plus its
/// own (separate) malformed-but-nonempty-URL guard.
final class HTTPRequestTests: XCTestCase {

    // MARK: - Codable

    func testHTTPRequestBodyRoundTripsGET() throws {
        let body = HTTPRequestBody(method: .get, urlString: "http://192.168.1.50:8080/cue/fire", timeout: 12)
        let cue = Cue(number: "1", body: .httpRequest(body))
        let data = try JSONEncoder().encode(cue)
        let decoded = try JSONDecoder().decode(Cue.self, from: data)
        XCTAssertEqual(decoded, cue)
    }

    func testHTTPRequestBodyRoundTripsPOST() throws {
        let body = HTTPRequestBody(
            method: .post,
            urlString: "https://example.com/api/go",
            contentType: "text/plain",
            payload: "blackout — 日本語",
            timeout: 20
        )
        let cue = Cue(number: "1", body: .httpRequest(body))
        let data = try JSONEncoder().encode(cue)
        let decoded = try JSONDecoder().decode(Cue.self, from: data)
        XCTAssertEqual(decoded, cue)
    }

    func testHTTPRequestBodyDefaultsWhenKeysAreStripped() throws {
        let json = """
        {"type": "httpRequest"}
        """
        let decoded = try JSONDecoder().decode(CueBody.self, from: Data(json.utf8))
        guard case .httpRequest(let body) = decoded else {
            return XCTFail("expected .httpRequest, got \(decoded)")
        }
        XCTAssertEqual(body.method, .get)
        XCTAssertEqual(body.urlString, "")
        XCTAssertEqual(body.contentType, "application/json")
        XCTAssertEqual(body.payload, "")
        XCTAssertEqual(body.timeout, 5)
    }

    func testHTTPRequestBodyTimeoutClampsOnDecode() throws {
        let tooLow = """
        {"type": "httpRequest", "timeout": 0}
        """
        let tooHigh = """
        {"type": "httpRequest", "timeout": 999}
        """
        guard case .httpRequest(let low) = try JSONDecoder().decode(CueBody.self, from: Data(tooLow.utf8)) else {
            return XCTFail("expected .httpRequest")
        }
        guard case .httpRequest(let high) = try JSONDecoder().decode(CueBody.self, from: Data(tooHigh.utf8)) else {
            return XCTFail("expected .httpRequest")
        }
        XCTAssertEqual(low.timeout, 1, "clamps up to the floor")
        XCTAssertEqual(high.timeout, 30, "clamps down to the ceiling")
    }

    func testHTTPRequestBodyTimeoutClampAppliesOnDirectInitToo() {
        XCTAssertEqual(HTTPRequestBody(timeout: 0).timeout, 1)
        XCTAssertEqual(HTTPRequestBody(timeout: 999).timeout, 30)
        XCTAssertEqual(HTTPRequestBody(timeout: 15).timeout, 15)
    }

    func testDefaultNameUsesHostWhenParseableElseGenericLabel() {
        XCTAssertEqual(CueBody.httpRequest(HTTPRequestBody()).defaultName, "HTTP Request")
        XCTAssertEqual(
            CueBody.httpRequest(HTTPRequestBody(urlString: "http://192.168.1.50:8080/go")).defaultName,
            "192.168.1.50"
        )
        XCTAssertEqual(
            CueBody.httpRequest(HTTPRequestBody(urlString: "https://lights.local/api/blackout")).defaultName,
            "lights.local"
        )
        // A non-empty string with no scheme/host component (this Foundation
        // percent-encodes rather than refusing it outright) still has a nil
        // `.host` — same generic fallback as an empty urlString.
        XCTAssertEqual(
            CueBody.httpRequest(HTTPRequestBody(urlString: "not a valid url")).defaultName,
            "HTTP Request"
        )
    }

    /// Forward-compat pin, same shape as OSCSendTests'/GoToTests' — confirms
    /// the decoder's unknown-type fallback still works for a type string
    /// that isn't "httpRequest" after adding this type.
    func testUnrelatedUnknownTypeStillDecodesToBrokenAfterAddingHTTPRequest() throws {
        let json = """
        {"type": "httpRequestFromTheFuture"}
        """
        let decoded = try JSONDecoder().decode(CueBody.self, from: Data(json.utf8))
        guard case .broken(let body) = decoded else {
            return XCTFail("expected .broken, got \(decoded)")
        }
        XCTAssertEqual(body.originalType, "httpRequestFromTheFuture")
    }

    // MARK: - HTTPRequestSender.request(for:) — pure construction

    func testRequestForGETHasNoBodyOrContentTypeAndCarriesTimeout() {
        let body = HTTPRequestBody(method: .get, urlString: "http://10.0.0.5/relay/on", timeout: 7)
        guard let request = HTTPRequestSender.request(for: body) else {
            return XCTFail("expected a valid request")
        }
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertNil(request.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertEqual(request.timeoutInterval, 7)
        XCTAssertEqual(request.url, URL(string: "http://10.0.0.5/relay/on"))
    }

    func testRequestForPOSTCarriesContentTypeAndPayloadBytes() {
        let body = HTTPRequestBody(
            method: .post,
            urlString: "http://10.0.0.5/api/cue",
            contentType: "application/x-www-form-urlencoded",
            payload: "cue=42&go=1",
            timeout: 3
        )
        guard let request = HTTPRequestSender.request(for: body) else {
            return XCTFail("expected a valid request")
        }
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertEqual(request.httpBody, Data("cue=42&go=1".utf8))
        XCTAssertEqual(request.timeoutInterval, 3)
    }

    func testRequestForMalformedURLReturnsNil() {
        // An unterminated IPv6-literal bracket is rejected outright by
        // URL(string:) — unlike plain unescaped spaces, which this Foundation
        // percent-encodes rather than refusing.
        let body = HTTPRequestBody(urlString: "http://[invalid")
        XCTAssertNil(HTTPRequestSender.request(for: body))
    }

    func testRequestForEmptyURLReturnsNil() {
        XCTAssertNil(HTTPRequestSender.request(for: HTTPRequestBody(urlString: "")))
    }

    // MARK: - HTTPRequestSender.send: its own malformed-URL warning (never the empty-URL case)

    @MainActor
    func testSendWithEmptyURLNeverWarnsDefenseInDepth() {
        // CueInstance already warns-and-skips an empty urlString before this
        // is ever reached in production — this just confirms the sender
        // itself stays silent on that exact input (mirrors OSCSender).
        let sender = HTTPRequestSender()
        var warned: String?
        sender.onWarning = { warned = $0 }
        sender.send(HTTPRequestBody(urlString: ""))
        XCTAssertNil(warned)
    }

    @MainActor
    func testSendWithMalformedNonEmptyURLWarnsOperator() {
        let sender = HTTPRequestSender()
        var warned: String?
        sender.onWarning = { warned = $0 }
        sender.send(HTTPRequestBody(urlString: "http://[invalid"))
        XCTAssertEqual(warned, "HTTP: “http://[invalid” is not a valid URL — request not sent")
    }

    // MARK: - Runtime harness (mirrors OSCSendTests'/GoToTests' Harness pattern)

    @MainActor
    private final class Harness {
        var show = ShowFile()
        let provider = MockProvider()
        var transport: TransportController!
        private(set) var sent: [HTTPRequestBody] = []
        private(set) var warnings: [String] = []

        init() {
            transport = TransportController(
                provider: provider,
                show: { [unowned self] in self.show },
                showFolder: { nil },
                httpRequest: { [weak self] body in self?.sent.append(body) }
            )
            transport.onOperatorWarning = { [weak self] message in self?.warnings.append(message) }
        }

        func wait(_ seconds: TimeInterval) async {
            try? await Task.sleep(for: .seconds(seconds))
        }
    }

    @MainActor
    func testHTTPRequestCueFiresExactlyOnceWithCorrectPayload() async {
        let harness = Harness()
        let body = HTTPRequestBody(method: .post, urlString: "http://10.0.0.5/go", payload: "42")
        let cue = Cue(number: "1", body: .httpRequest(body))
        harness.show.cues = [cue]
        harness.transport.go()
        await harness.wait(0.05)
        XCTAssertEqual(harness.sent.count, 1)
        XCTAssertEqual(harness.sent.first, body)
    }

    @MainActor
    func testHTTPRequestCueCompletesImmediatelyLikeAnOSCSendCue() async {
        let harness = Harness()
        let cue = Cue(number: "1", body: .httpRequest(HTTPRequestBody(urlString: "http://10.0.0.5/go")))
        harness.show.cues = [cue]
        harness.transport.go()
        await harness.wait(0.05)
        XCTAssertEqual(harness.transport.registry.instances.count, 0, "an HTTP request cue must not linger in the active-cues registry")
    }

    @MainActor
    func testEmptyURLIsWarnedNoOpAtTheRuntimeLayer() async {
        let harness = Harness()
        let cue = Cue(number: "1", body: .httpRequest(HTTPRequestBody(urlString: "")))
        harness.show.cues = [cue]
        harness.transport.go()
        await harness.wait(0.05)
        XCTAssertTrue(harness.sent.isEmpty, "unconfigured URL must never reach the sender")
        XCTAssertEqual(harness.warnings.count, 1)
        XCTAssertTrue(harness.warnings.first?.contains("no URL configured") ?? false)
        XCTAssertEqual(harness.transport.registry.instances.count, 0)
    }

    /// A non-empty but malformed URL is NOT caught at the runtime layer —
    /// the runtime forwards it unconditionally; only the sender can tell a
    /// malformed URL from a good one (building the actual URLRequest).
    @MainActor
    func testMalformedNonEmptyURLIsNotCaughtAtTheRuntimeLayer() async {
        let harness = Harness()
        let cue = Cue(number: "1", body: .httpRequest(HTTPRequestBody(urlString: "http://[invalid")))
        harness.show.cues = [cue]
        harness.transport.go()
        await harness.wait(0.05)
        XCTAssertEqual(harness.sent.count, 1, "the runtime always forwards a non-empty urlString — validation is the sender's job")
        XCTAssertTrue(harness.warnings.isEmpty, "the runtime layer itself never validates URL syntax")
    }

    @MainActor
    func testPreWaitIsHonoredBeforeSending() async {
        let harness = Harness()
        let cue = Cue(number: "1", preWait: 0.25, body: .httpRequest(HTTPRequestBody(urlString: "http://10.0.0.5/go")))
        harness.show.cues = [cue]
        harness.transport.go()
        await harness.wait(0.1)
        XCTAssertTrue(harness.sent.isEmpty, "must not send before the pre-wait elapses")
        await harness.wait(0.3)
        XCTAssertEqual(harness.sent.count, 1, "sends once the pre-wait has elapsed")
    }

    @MainActor
    func testHTTPRequestCueNeverBlocksGOAdvancingToTheNextCue() async {
        let harness = Harness()
        let a = Cue(number: "1", body: .httpRequest(HTTPRequestBody(urlString: "http://10.0.0.5/go")))
        let b = Cue(number: "2", body: .httpRequest(HTTPRequestBody(urlString: "http://10.0.0.5/next")))
        harness.show.cues = [a, b]
        harness.transport.go()
        XCTAssertEqual(harness.transport.playheadID, b.id, "GO must advance past an instant HTTP request cue synchronously")
    }
}
