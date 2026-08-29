import XCTest
@testable import StageWizard

/// Phase D8: web remote — a phone-friendly GO page served by the app
/// (zero-dependency, Network.framework HTTP/1.1).
///
/// Deliberately does NOT bind a real TCP socket (CI/sandbox flakiness) —
/// coverage is the pure request-line parser, the pure route table, the pure
/// response serializer, Codable, and the command-routing wire-up through
/// AppModel/TriggerRouter (mirrors OSCTests).
@MainActor
final class WebRemoteTests: XCTestCase {

    // MARK: - parseRequest: normal lines

    func testParsesSimpleGETRequestLine() {
        let head = "GET / HTTP/1.1\r\nHost: example.com\r\nUser-Agent: test"
        let request = WebRemoteServer.parseRequest(head)
        XCTAssertEqual(request?.method, "GET")
        XCTAssertEqual(request?.path, "/")
    }

    func testParsesPOSTRequestLine() {
        let head = "POST /go HTTP/1.1\r\nContent-Length: 0"
        let request = WebRemoteServer.parseRequest(head)
        XCTAssertEqual(request?.method, "POST")
        XCTAssertEqual(request?.path, "/go")
    }

    func testParsesStatusRequestLine() {
        let head = "GET /status HTTP/1.1\r\n"
        let request = WebRemoteServer.parseRequest(head)
        XCTAssertEqual(request?.method, "GET")
        XCTAssertEqual(request?.path, "/status")
    }

    // MARK: - parseRequest: query-string truncation

    func testQueryStringIsTruncatedFromPath() {
        let head = "GET /status?ts=12345&x=1 HTTP/1.1\r\n"
        let request = WebRemoteServer.parseRequest(head)
        XCTAssertEqual(request?.path, "/status")
    }

    func testQuestionMarkAtPathStartTruncatesToEmptyPathIsNil() {
        // A path that's nothing but a query string truncates to empty — no
        // valid route can match that, so the parser rejects it outright
        // rather than handing routing a path it can never resolve.
        let head = "GET ?ts=1 HTTP/1.1\r\n"
        XCTAssertNil(WebRemoteServer.parseRequest(head))
    }

    func testTrailingQuestionMarkTruncatesToRootPath() {
        let head = "GET /? HTTP/1.1\r\n"
        XCTAssertEqual(WebRemoteServer.parseRequest(head)?.path, "/")
    }

    // MARK: - parseRequest: garbage/empty

    func testEmptyHeadReturnsNil() {
        XCTAssertNil(WebRemoteServer.parseRequest(""))
    }

    func testGarbageSingleTokenReturnsNil() {
        XCTAssertNil(WebRemoteServer.parseRequest("garbage\r\nHost: x"))
    }

    func testWhitespaceOnlyReturnsNil() {
        XCTAssertNil(WebRemoteServer.parseRequest("   \r\nHost: x"))
    }

    func testMethodAndPathWithoutHTTPVersionStillParses() {
        // Tolerant: routing only needs method + path.
        let request = WebRemoteServer.parseRequest("GET /status")
        XCTAssertEqual(request?.method, "GET")
        XCTAssertEqual(request?.path, "/status")
    }

    // MARK: - Route table: WebRemoteServer.route(method:path:)

    func testRouteIndex() {
        XCTAssertEqual(WebRemoteServer.route(method: "GET", path: "/"), .index)
    }

    func testRouteStatus() {
        XCTAssertEqual(WebRemoteServer.route(method: "GET", path: "/status"), .status)
    }

    func testRouteCommands() {
        XCTAssertEqual(WebRemoteServer.route(method: "POST", path: "/go"), .command(.go))
        XCTAssertEqual(WebRemoteServer.route(method: "POST", path: "/stopall"), .command(.stopAll))
        XCTAssertEqual(WebRemoteServer.route(method: "POST", path: "/panic"), .command(.panic))
        XCTAssertEqual(WebRemoteServer.route(method: "POST", path: "/next"), .command(.next))
        XCTAssertEqual(WebRemoteServer.route(method: "POST", path: "/prev"), .command(.prev))
    }

    func testRouteUnknownPathIs404() {
        XCTAssertEqual(WebRemoteServer.route(method: "GET", path: "/nope"), .notFound)
        XCTAssertEqual(WebRemoteServer.route(method: "POST", path: "/unknown"), .notFound)
    }

    func testRouteWrongMethodOnKnownPathIs405() {
        XCTAssertEqual(WebRemoteServer.route(method: "POST", path: "/"), .methodNotAllowed)
        XCTAssertEqual(WebRemoteServer.route(method: "POST", path: "/status"), .methodNotAllowed)
        XCTAssertEqual(WebRemoteServer.route(method: "GET", path: "/go"), .methodNotAllowed)
        XCTAssertEqual(WebRemoteServer.route(method: "DELETE", path: "/stopall"), .methodNotAllowed)
    }

    // MARK: - Response writer: status line + headers + Content-Length

    func testResponseBytesForHTML() {
        let response = WebRemoteHTTPResponse.html("<html></html>")
        let bytes = WebRemoteServer.responseBytes(response)
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(text.contains("Content-Type: text/html; charset=utf-8\r\n"))
        XCTAssertTrue(text.contains("Content-Length: 13\r\n"))
        XCTAssertTrue(text.contains("Connection: close\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n<html></html>"))
    }

    func testResponseBytesContentLengthCountsUTF8BytesNotCharacters() {
        // "café ▶" — the é (2 bytes) and ▶ (3 bytes) push the byte count
        // above the character count; Content-Length must report bytes.
        let body = "café ▶"
        XCTAssertEqual(body.count, 6, "6 grapheme clusters")
        let response = WebRemoteHTTPResponse.html(body)
        XCTAssertEqual(response.body.count, 9, "é is 2 UTF-8 bytes, ▶ is 3 — 9 bytes total, not 6")
        let bytes = WebRemoteServer.responseBytes(response)
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(text.contains("Content-Length: 9\r\n"))
    }

    func testResponseBytesForNoContentHasNoBodyAndNoContentType() {
        let bytes = WebRemoteServer.responseBytes(.noContent)
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 204 No Content\r\n"))
        XCTAssertFalse(text.contains("Content-Type"))
        XCTAssertTrue(text.contains("Content-Length: 0\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n"), "204 must end at the blank line with no body bytes after it")
    }

    func testResponseBytesForNotFound() {
        let bytes = WebRemoteServer.responseBytes(.notFound)
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 404 Not Found\r\n"))
        XCTAssertTrue(text.hasSuffix("not found"))
    }

    func testResponseBytesForMethodNotAllowed() {
        let bytes = WebRemoteServer.responseBytes(.methodNotAllowed)
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 405 Method Not Allowed\r\n"))
    }

    // MARK: - WebRemoteStatus JSON round-trip / shape

    func testWebRemoteStatusEncodesExpectedKeys() throws {
        let status = WebRemoteStatus(
            standingByNumber: "3", standingByName: "Intro VO", notes: "watch levels",
            runningCount: 2, showMode: true, panicking: false
        )
        let data = try JSONEncoder().encode(status)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["standingByNumber"] as? String, "3")
        XCTAssertEqual(json["standingByName"] as? String, "Intro VO")
        XCTAssertEqual(json["notes"] as? String, "watch levels")
        XCTAssertEqual(json["runningCount"] as? Int, 2)
        XCTAssertEqual(json["showMode"] as? Bool, true)
        XCTAssertEqual(json["panicking"] as? Bool, false)
    }

    func testWebRemoteStatusRoundTripsThroughDecoderOfEncoderOutput() throws {
        let status = WebRemoteStatus(
            standingByNumber: nil, standingByName: nil, notes: nil,
            runningCount: 0, showMode: false, panicking: true
        )
        let data = try JSONEncoder().encode(status)
        let decoded = try JSONDecoder().decode(WebRemoteStatus.self, from: data)
        XCTAssertEqual(decoded, status)
    }

    // MARK: - Codable: ShowSettings.webRemoteEnabled / webRemotePort

    func testWebRemoteSettingsDefaultOffWithDefaultPort() {
        let settings = ShowSettings()
        XCTAssertFalse(settings.webRemoteEnabled)
        XCTAssertEqual(settings.webRemotePort, 53200)
    }

    func testWebRemoteSettingsRoundTripThroughShowFile() throws {
        var show = ShowFile()
        show.settings.webRemoteEnabled = true
        show.settings.webRemotePort = 9100
        let decoded = try ShowFile.load(from: show.encoded())
        XCTAssertTrue(decoded.settings.webRemoteEnabled)
        XCTAssertEqual(decoded.settings.webRemotePort, 9100)
    }

    func testOlderShowFileWithoutWebRemoteKeysDecodesToDefaults() throws {
        // A pre-D8 show file predates the web remote entirely.
        var show = ShowFile()
        show.settings.webRemoteEnabled = true
        show.settings.webRemotePort = 9100
        var json = try JSONSerialization.jsonObject(with: show.encoded()) as! [String: Any]
        var settings = json["settings"] as! [String: Any]
        settings.removeValue(forKey: "webRemoteEnabled")
        settings.removeValue(forKey: "webRemotePort")
        json["settings"] = settings
        let stripped = try JSONSerialization.data(withJSONObject: json)
        let decoded = try ShowFile.load(from: stripped)
        XCTAssertFalse(decoded.settings.webRemoteEnabled, "pre-D8 files predate the web remote")
        XCTAssertEqual(decoded.settings.webRemotePort, 53200)
    }

    func testWebRemotePortBelowValidRangeClampsToDefaultOnDecode() throws {
        let show = ShowFile()
        var json = try JSONSerialization.jsonObject(with: show.encoded()) as! [String: Any]
        var settings = json["settings"] as! [String: Any]
        settings["webRemotePort"] = 80   // below 1024
        json["settings"] = settings
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try ShowFile.load(from: data)
        XCTAssertEqual(decoded.settings.webRemotePort, 53200, "out-of-range port clamps to the default on decode")
    }

    func testWebRemotePortAtLowerBoundDecodesUnclamped() throws {
        let show = ShowFile()
        var json = try JSONSerialization.jsonObject(with: show.encoded()) as! [String: Any]
        var settings = json["settings"] as! [String: Any]
        settings["webRemotePort"] = 1024   // exactly the lower bound — must decode as-is
        json["settings"] = settings
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try ShowFile.load(from: data)
        XCTAssertEqual(decoded.settings.webRemotePort, 1024)
    }

    // MARK: - Embedded page sanity

    func testEmbeddedPageContainsExpectedRoutesAndNoExternalReferences() {
        let page = WebRemotePage.html
        XCTAssertTrue(page.contains("POST"))
        XCTAssertTrue(page.contains("/status"))
        XCTAssertTrue(page.contains("/go"))
        XCTAssertTrue(page.contains("/stopall"))
        XCTAssertTrue(page.contains("/next"))
        XCTAssertTrue(page.contains("/prev"))
        XCTAssertTrue(page.contains("name=\"viewport\""))
        XCTAssertFalse(page.contains("http://"), "no external references — the page must be fully self-contained")
        XCTAssertFalse(page.contains("https://"), "no external references — the page must be fully self-contained")
    }

    func testEmbeddedPageOmitsAPanicButtonRoute() {
        // Esc-grade panic stays a physical keyboard action; the page must
        // never issue POST /panic itself even though the server still
        // serves that route.
        XCTAssertFalse(WebRemotePage.html.contains("/panic"))
    }

    // MARK: - AppModel dispatch: WebRemoteServer.onCommand → TriggerRouter

    func testWebRemoteGoCommandDispatchesThroughTriggerRouter() {
        let app = AppModel()
        let cue = Cue(number: "1", body: .audio(AudioBody(media: MediaReference(absolutePath: "/fake/1.wav"))))
        app.document.mutate { $0.cues = [cue] }
        app.webRemoteServer.onCommand?(.go)
        XCTAssertEqual(app.transport.registry.instances.first?.cue.id, cue.id, ".go must reach the same GO transport.go() drives")
    }

    func testWebRemoteStopAllCommandDispatchesThroughTriggerRouter() {
        let app = AppModel()
        let cue = Cue(number: "1", body: .audio(AudioBody(media: MediaReference(absolutePath: "/fake/1.wav"))))
        app.document.mutate { $0.cues = [cue] }
        app.webRemoteServer.onCommand?(.go)
        XCTAssertFalse(app.transport.registry.isEmpty)
        app.webRemoteServer.onCommand?(.stopAll)
        XCTAssertTrue(app.transport.registry.isEmpty)
    }

    func testWebRemotePanicCommandDispatchesThroughTriggerRouter() {
        let app = AppModel()
        app.webRemoteServer.onCommand?(.panic)
        XCTAssertTrue(app.transport.isPanicking)
    }

    func testWebRemoteNextPrevCommandsMovePlayhead() {
        let app = AppModel()
        let cueA = Cue(number: "1", body: .audio(AudioBody(media: MediaReference(absolutePath: "/fake/1.wav"))))
        let cueB = Cue(number: "2", body: .audio(AudioBody(media: MediaReference(absolutePath: "/fake/2.wav"))))
        app.document.mutate { $0.cues = [cueA, cueB] }
        app.transport.setPlayhead(cueA.id)
        app.webRemoteServer.onCommand?(.next)
        XCTAssertEqual(app.transport.playheadID, cueB.id)
        app.webRemoteServer.onCommand?(.prev)
        XCTAssertEqual(app.transport.playheadID, cueA.id)
    }

    // MARK: - AppModel: statusProvider reflects live transport state

    func testStatusProviderReflectsStandingByCueAndRunningCount() {
        let app = AppModel()
        let cue = Cue(number: "5", body: .audio(AudioBody(media: MediaReference(absolutePath: "/fake/5.wav"))))
        app.document.mutate { show in
            show.cues = [cue]
            show.cues[0].notes = "watch levels"
        }
        app.transport.setPlayhead(cue.id)

        guard let status = app.webRemoteServer.statusProvider?() else {
            XCTFail("statusProvider must be wired by AppModel.wire()")
            return
        }
        XCTAssertEqual(status.standingByNumber, "5")
        XCTAssertEqual(status.notes, "watch levels")
        XCTAssertEqual(status.runningCount, 0)
        XCTAssertFalse(status.panicking)

        app.webRemoteServer.onCommand?(.go)
        let afterGo = app.webRemoteServer.statusProvider?()
        XCTAssertEqual(afterGo?.runningCount, 1)
    }
}
