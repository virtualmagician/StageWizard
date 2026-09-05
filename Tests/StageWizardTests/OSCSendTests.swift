import Network
import XCTest
@testable import StageWizard

/// D29: the first OUTBOUND cue type. Covers the model (Codable round trip,
/// stripped-key defaults, port clamp, forward-compat), the wire-format
/// conversion (OSCSendArgument → OSCArgument, pinned through the same
/// encode/parse round trip OSCFeedbackTests uses — no sockets), the runtime
/// action (fires exactly once via an injected closure, completes
/// immediately like a stop cue, empty host is a warned no-op, preWait is
/// honored), and Preflight.
final class OSCSendTests: XCTestCase {

    // MARK: - Codable

    func testOSCSendBodyRoundTripsEveryArgumentType() throws {
        let body = OSCSendBody(
            host: "192.168.1.50",
            port: 9001,
            address: "/cue/fire",
            arguments: [.int32(42), .float(3.5), .string("hello — 日本語")]
        )
        let cue = Cue(number: "1", body: .oscSend(body))
        let data = try JSONEncoder().encode(cue)
        let decoded = try JSONDecoder().decode(Cue.self, from: data)
        XCTAssertEqual(decoded, cue)
    }

    func testOSCSendBodyDefaultsWhenKeysAreStripped() throws {
        let json = """
        {"type": "oscSend"}
        """
        let decoded = try JSONDecoder().decode(CueBody.self, from: Data(json.utf8))
        guard case .oscSend(let body) = decoded else {
            return XCTFail("expected .oscSend, got \(decoded)")
        }
        XCTAssertEqual(body.host, "")
        XCTAssertEqual(body.port, 8000)
        XCTAssertEqual(body.address, "/")
        XCTAssertTrue(body.arguments.isEmpty)
    }

    func testOSCSendBodyPortZeroClampsToDefaultOnDecode() throws {
        let json = """
        {"type": "oscSend", "host": "x", "port": 0, "address": "/a", "arguments": []}
        """
        let decoded = try JSONDecoder().decode(CueBody.self, from: Data(json.utf8))
        guard case .oscSend(let body) = decoded else {
            return XCTFail("expected .oscSend, got \(decoded)")
        }
        XCTAssertEqual(body.port, 8000)
    }

    func testOSCSendBodyPortClampAlsoAppliesOnDirectInit() {
        // Same clamp the memberwise init applies as the decoder — an
        // authored port of 0 (e.g. programmatic construction) is just as
        // invalid as a decoded one.
        XCTAssertEqual(OSCSendBody(port: 0).port, 8000)
        XCTAssertEqual(OSCSendBody(port: 9001).port, 9001)
    }

    /// Forward-compat pin (D29 can't run the OLD app to verify unknown types
    /// decode to `.broken` there — but this confirms the CURRENT decoder's
    /// unknown-type fallback still works for a type string that isn't
    /// "oscSend", exactly the mechanism an old app would use against a show
    /// file this version writes for a cue type introduced later).
    func testUnrelatedUnknownTypeStillDecodesToBrokenAfterAddingOSCSend() throws {
        let json = """
        {"type": "oscSendFromTheFuture", "host": "x"}
        """
        let decoded = try JSONDecoder().decode(CueBody.self, from: Data(json.utf8))
        guard case .broken(let body) = decoded else {
            return XCTFail("expected .broken, got \(decoded)")
        }
        XCTAssertEqual(body.originalType, "oscSendFromTheFuture")
    }

    func testOSCSendDefaultNameUsesAddressWhenSetElseGenericLabel() {
        XCTAssertEqual(CueBody.oscSend(OSCSendBody()).defaultName, "OSC Send")
        XCTAssertEqual(CueBody.oscSend(OSCSendBody(address: "/stagewand/blackout")).defaultName, "/stagewand/blackout")
    }

    // MARK: - Wire round trip (argument conversion, no sockets)

    func testArgumentConversionRoundTripsThroughOSCServerEncodeParse() {
        let arguments: [OSCSendArgument] = [.int32(7), .float(1.25), .string("Blackout — 日本語")]
        // The SAME conversion function OSCSender.send uses in production.
        let wireArgs = arguments.map(OSCSender.convert)
        let data = OSCServer.encode(address: "/stagewand/cue", arguments: wireArgs)
        XCTAssertEqual(
            OSCServer.parse(data),
            [OSCMessage(address: "/stagewand/cue", arguments: wireArgs)]
        )
    }

    func testEmptyArgumentListRoundTrips() {
        let data = OSCServer.encode(address: "/stagewand/blackout", arguments: [])
        XCTAssertEqual(OSCServer.parse(data), [OSCMessage(address: "/stagewand/blackout", arguments: [])])
    }

    // MARK: - D28-fix5: OSCSender.outcome(for:) — pure state-transition decision

    /// The core of the fix: `.waiting` (unreachable host, DNS failure, no
    /// route) must be treated as a FAILURE — warn and clean up — not left
    /// alone to retry indefinitely (which would both leak the connection
    /// entry and risk delivering a stale datagram late if the network
    /// recovers mid-show).
    @MainActor
    func testWaitingStateIsClassifiedAsWarnAndCleanUp() {
        let outcome = OSCSender.outcome(for: .waiting(.posix(.EHOSTUNREACH)), host: "lighting-desk.local", port: 9000)
        XCTAssertEqual(outcome, .warnAndCleanUp(message: "OSC send to lighting-desk.local:9000 unreachable"))
    }

    @MainActor
    func testFailedStateIsClassifiedAsWarnAndCleanUpWithTheUnderlyingError() {
        let error = NWError.posix(.ECONNREFUSED)
        let outcome = OSCSender.outcome(for: .failed(error), host: "127.0.0.1", port: 9000)
        XCTAssertEqual(outcome, .warnAndCleanUp(message: "OSC send to 127.0.0.1:9000 failed: \(error.localizedDescription)"))
    }

    @MainActor
    func testCancelledStateIsClassifiedAsCleanUpSilently() {
        XCTAssertEqual(OSCSender.outcome(for: .cancelled, host: "127.0.0.1", port: 9000), .cleanUpSilently)
    }

    @MainActor
    func testSetupAndPreparingStatesAreIgnored() {
        XCTAssertEqual(OSCSender.outcome(for: .setup, host: "127.0.0.1", port: 9000), .ignore)
        XCTAssertEqual(OSCSender.outcome(for: .preparing, host: "127.0.0.1", port: 9000), .ignore)
    }

    // MARK: - Runtime harness (mirrors RuntimeTests' MockProvider pattern)

    @MainActor
    private final class Harness {
        var show = ShowFile()
        let provider = MockProvider()
        // Implicitly-unwrapped: an Optional stored property needs no value
        // before `self` can be captured by the escaping closures below (a
        // non-optional `let` here would be a definite-initialization error —
        // "used before being initialized" — since those closures capture
        // `self` while `self.transport` itself is still being assigned).
        var transport: TransportController!
        private(set) var sent: [OSCSendBody] = []
        private(set) var warnings: [String] = []

        init() {
            transport = TransportController(
                provider: provider,
                show: { [unowned self] in self.show },
                showFolder: { nil },
                oscSend: { [weak self] body in self?.sent.append(body) }
            )
            transport.onOperatorWarning = { [weak self] message in self?.warnings.append(message) }
        }

        func wait(_ seconds: TimeInterval) async {
            try? await Task.sleep(for: .seconds(seconds))
        }
    }

    @MainActor
    func testOSCSendCueFiresExactlyOnceWithCorrectPayload() async {
        let harness = Harness()
        let body = OSCSendBody(host: "127.0.0.1", port: 9000, address: "/go", arguments: [.int32(3), .string("Blackout")])
        let cue = Cue(number: "1", body: .oscSend(body))
        harness.show.cues = [cue]
        harness.transport.go()
        await harness.wait(0.05)
        XCTAssertEqual(harness.sent.count, 1)
        XCTAssertEqual(harness.sent.first, body)
    }

    @MainActor
    func testOSCSendCueCompletesImmediatelyLikeAStopCue() async {
        let harness = Harness()
        let cue = Cue(number: "1", body: .oscSend(OSCSendBody(host: "127.0.0.1", address: "/go")))
        harness.show.cues = [cue]
        harness.transport.go()
        await harness.wait(0.05)
        XCTAssertEqual(harness.transport.registry.instances.count, 0, "an OSC send cue must not linger in the active-cues registry")
    }

    @MainActor
    func testEmptyHostIsWarnedNoOp() async {
        let harness = Harness()
        let cue = Cue(number: "1", body: .oscSend(OSCSendBody(host: "", address: "/go")))
        harness.show.cues = [cue]
        harness.transport.go()
        await harness.wait(0.05)
        XCTAssertTrue(harness.sent.isEmpty, "unconfigured host must never reach the sender")
        XCTAssertEqual(harness.warnings.count, 1)
        XCTAssertEqual(harness.transport.registry.instances.count, 0)
    }

    @MainActor
    func testPreWaitIsHonoredBeforeSending() async {
        let harness = Harness()
        let cue = Cue(number: "1", preWait: 0.25, body: .oscSend(OSCSendBody(host: "127.0.0.1", address: "/go")))
        harness.show.cues = [cue]
        harness.transport.go()
        await harness.wait(0.1)
        XCTAssertTrue(harness.sent.isEmpty, "must not send before the pre-wait elapses")
        await harness.wait(0.3)
        XCTAssertEqual(harness.sent.count, 1, "sends once the pre-wait has elapsed")
    }

    @MainActor
    func testOSCSendCueNeverBlocksGOAdvancingToTheNextCue() async {
        let harness = Harness()
        let a = Cue(number: "1", body: .oscSend(OSCSendBody(host: "127.0.0.1", address: "/go")))
        let b = Cue(number: "2", body: .oscSend(OSCSendBody(host: "127.0.0.1", address: "/next")))
        harness.show.cues = [a, b]
        harness.transport.go()
        XCTAssertEqual(harness.transport.playheadID, b.id, "GO must advance past an instant OSC cue synchronously")
    }
}
