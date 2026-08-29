import XCTest
@testable import StageWizard

/// Phase D7: OSC remote control (zero-dependency, Network.framework).
///
/// Deliberately does NOT bind a real UDP socket (CI/sandbox flakiness) —
/// coverage is the pure parser, the pure routing table, Codable, and the
/// panic-routing wire-up through AppModel/TriggerRouter.
@MainActor
final class OSCTests: XCTestCase {

    // MARK: - Datagram construction helpers (hand-built, big-endian, padded)

    /// An OSC-string: UTF-8 bytes, one null terminator, padded with more
    /// nulls to a 4-byte boundary.
    private func oscString(_ s: String) -> Data {
        var data = Data(s.utf8)
        data.append(0)
        while data.count % 4 != 0 { data.append(0) }
        return data
    }

    private func oscMessage(address: String, typeTags: String, argBytes: Data = Data()) -> Data {
        var data = oscString(address)
        data.append(oscString("," + typeTags))
        data.append(argBytes)
        return data
    }

    private func bigEndianInt32(_ v: Int32) -> Data {
        let u = UInt32(bitPattern: v)
        return Data([UInt8((u >> 24) & 0xFF), UInt8((u >> 16) & 0xFF), UInt8((u >> 8) & 0xFF), UInt8(u & 0xFF)])
    }

    private func bigEndianFloat32(_ v: Float) -> Data {
        let u = v.bitPattern
        return Data([UInt8((u >> 24) & 0xFF), UInt8((u >> 16) & 0xFF), UInt8((u >> 8) & 0xFF), UInt8(u & 0xFF)])
    }

    /// Wraps `elements` (already-encoded messages/bundles) in a `#bundle`
    /// with an ignored (all-zero) timetag.
    private func oscBundle(elements: [Data]) -> Data {
        var data = Data("#bundle\0".utf8)
        data.append(Data(repeating: 0, count: 8))   // timetag — ignored
        for element in elements {
            data.append(bigEndianInt32(Int32(element.count)))
            data.append(element)
        }
        return data
    }

    // MARK: - Parser: address-only message

    func testParsesAddressOnlyMessage() {
        let data = oscMessage(address: "/stagewizard/go", typeTags: "")
        XCTAssertEqual(OSCServer.parse(data), [OSCMessage(address: "/stagewizard/go", arguments: [])])
    }

    // MARK: - Parser: int32/float32/string args

    func testParsesMessageWithIntFloatAndStringArgs() {
        var args = Data()
        args.append(bigEndianInt32(42))
        args.append(bigEndianFloat32(3.5))
        args.append(oscString("hello"))
        let data = oscMessage(address: "/stagewizard/cue/1/fire", typeTags: "ifs", argBytes: args)

        let messages = OSCServer.parse(data)
        XCTAssertEqual(messages, [
            OSCMessage(address: "/stagewizard/cue/1/fire", arguments: [.int32(42), .float32(3.5), .string("hello")]),
        ])
    }

    func testNegativeInt32ArgRoundTrips() {
        let args = bigEndianInt32(-17)
        let data = oscMessage(address: "/stagewizard/go", typeTags: "i", argBytes: args)
        XCTAssertEqual(OSCServer.parseMessage(data)?.arguments, [.int32(-17)])
    }

    // MARK: - Parser: malformed input

    func testUnknownTypeTagAbortsParsingTheWholeMessage() {
        // "b" (blob) isn't a tag this parser understands.
        let data = oscMessage(address: "/stagewizard/go", typeTags: "b")
        XCTAssertNil(OSCServer.parseMessage(data))
        XCTAssertTrue(OSCServer.parse(data).isEmpty)
    }

    func testTruncatedArgumentDataReturnsNil() {
        // Type tag claims an int32 argument but no bytes follow it.
        let data = oscMessage(address: "/stagewizard/go", typeTags: "i")
        XCTAssertNil(OSCServer.parseMessage(data))
        XCTAssertTrue(OSCServer.parse(data).isEmpty)
    }

    func testMissingNullTerminatorReturnsNil() {
        let data = Data("/stagewizard/go".utf8)   // no null terminator, no padding at all
        XCTAssertNil(OSCServer.parseMessage(data))
        XCTAssertTrue(OSCServer.parse(data).isEmpty)
    }

    func testEmptyDataReturnsEmpty() {
        XCTAssertTrue(OSCServer.parse(Data()).isEmpty)
    }

    func testAddressNotStartingWithSlashReturnsNil() {
        let data = oscMessage(address: "stagewizard/go", typeTags: "")
        XCTAssertNil(OSCServer.parseMessage(data))
    }

    // MARK: - Parser: bundles

    func testBundleWithTwoMessagesParsesBoth() {
        let go = oscMessage(address: "/stagewizard/go", typeTags: "")
        let stop = oscMessage(address: "/stagewizard/stopall", typeTags: "")
        let bundle = oscBundle(elements: [go, stop])

        XCTAssertEqual(OSCServer.parse(bundle), [
            OSCMessage(address: "/stagewizard/go", arguments: []),
            OSCMessage(address: "/stagewizard/stopall", arguments: []),
        ])
    }

    func testNestedBundleParsesInnerMessages() {
        let next = oscMessage(address: "/stagewizard/next", typeTags: "")
        let innerBundle = oscBundle(elements: [next])
        let prev = oscMessage(address: "/stagewizard/prev", typeTags: "")
        let outerBundle = oscBundle(elements: [innerBundle, prev])

        XCTAssertEqual(OSCServer.parse(outerBundle), [
            OSCMessage(address: "/stagewizard/next", arguments: []),
            OSCMessage(address: "/stagewizard/prev", arguments: []),
        ])
    }

    func testTruncatedBundleElementSizeStopsCleanly() {
        var bundle = Data("#bundle\0".utf8)
        bundle.append(Data(repeating: 0, count: 8))
        bundle.append(bigEndianInt32(999))   // claims a huge element that isn't actually present
        XCTAssertTrue(OSCServer.parse(bundle).isEmpty)
    }

    /// Wraps `payload` in `depth` nested `#bundle` layers — depth 1 is a
    /// single bundle directly containing `payload`; depth 2 is a bundle
    /// containing a bundle containing `payload`; and so on.
    private func nestedBundles(around payload: Data, depth: Int) -> Data {
        var wrapped = payload
        for _ in 0..<depth {
            wrapped = oscBundle(elements: [wrapped])
        }
        return wrapped
    }

    /// FIX 9: recursion depth cap. A modest nesting depth (well under the
    /// cap) must still parse normally.
    func testModeratelyNestedBundleStillParses() {
        let go = oscMessage(address: "/stagewizard/go", typeTags: "")
        let data = nestedBundles(around: go, depth: 2)   // bundle -> bundle -> message
        XCTAssertEqual(OSCServer.parse(data), [OSCMessage(address: "/stagewizard/go", arguments: [])])
    }

    /// FIX 9: a datagram nesting `#bundle` well past the recursion cap must
    /// not crash the worker (background) queue — parsing that branch aborts
    /// silently once the cap is exceeded, so the deeply buried message is
    /// simply never reached.
    func testDeeplyNestedBundleAbortsWithoutCrashing() {
        let go = oscMessage(address: "/stagewizard/go", typeTags: "")
        let data = nestedBundles(around: go, depth: 16)
        XCTAssertEqual(OSCServer.parse(data), [], "nesting past the recursion cap must abort that branch, not fire the buried message")
    }

    // MARK: - Router table: OSCServer.command(for:)

    func testCommandForEveryMappedAddress() {
        XCTAssertEqual(OSCServer.command(for: "/stagewizard/go"), .action(.go))
        XCTAssertEqual(OSCServer.command(for: "/stagewizard/stopall"), .action(.stopAll))
        XCTAssertEqual(OSCServer.command(for: "/stagewizard/next"), .action(.nextCue))
        XCTAssertEqual(OSCServer.command(for: "/stagewizard/prev"), .action(.previousCue))
        XCTAssertEqual(OSCServer.command(for: "/stagewizard/toggle"), .action(.togglePlayback))
        XCTAssertEqual(OSCServer.command(for: "/stagewizard/panic"), .panic)
    }

    func testCommandForFireCueWithDottedNumber() {
        XCTAssertEqual(OSCServer.command(for: "/stagewizard/cue/10.5/fire"), .fireCue(number: "10.5"))
    }

    func testCommandForFireCueWithIntegerNumber() {
        XCTAssertEqual(OSCServer.command(for: "/stagewizard/cue/3/fire"), .fireCue(number: "3"))
    }

    func testCommandForUnknownAddressIsNil() {
        XCTAssertNil(OSCServer.command(for: "/stagewizard/unknown"))
        XCTAssertNil(OSCServer.command(for: "/somethingelse"))
        XCTAssertNil(OSCServer.command(for: "/stagewizard/cue/1/notfire"))
    }

    func testCommandForEmptyCueNumberIsNil() {
        XCTAssertNil(OSCServer.command(for: "/stagewizard/cue//fire"))
    }

    // MARK: - Codable: ShowSettings.oscEnabled / oscPort

    func testOSCSettingsDefaultOffWithDefaultPort() {
        let settings = ShowSettings()
        XCTAssertFalse(settings.oscEnabled)
        XCTAssertEqual(settings.oscPort, 53100)
    }

    func testOSCSettingsRoundTripThroughShowFile() throws {
        var show = ShowFile()
        show.settings.oscEnabled = true
        show.settings.oscPort = 9000
        let decoded = try ShowFile.load(from: show.encoded())
        XCTAssertTrue(decoded.settings.oscEnabled)
        XCTAssertEqual(decoded.settings.oscPort, 9000)
    }

    func testOlderShowFileWithoutOSCKeysDecodesToDefaults() throws {
        // A pre-D7 show file predates OSC remote control entirely.
        var show = ShowFile()
        show.settings.oscEnabled = true
        show.settings.oscPort = 9000
        var json = try JSONSerialization.jsonObject(with: show.encoded()) as! [String: Any]
        var settings = json["settings"] as! [String: Any]
        settings.removeValue(forKey: "oscEnabled")
        settings.removeValue(forKey: "oscPort")
        json["settings"] = settings
        let stripped = try JSONSerialization.data(withJSONObject: json)
        let decoded = try ShowFile.load(from: stripped)
        XCTAssertFalse(decoded.settings.oscEnabled, "pre-D7 files predate OSC control")
        XCTAssertEqual(decoded.settings.oscPort, 53100)
    }

    func testOSCPortBelowValidRangeClampsToDefaultOnDecode() throws {
        let show = ShowFile()
        var json = try JSONSerialization.jsonObject(with: show.encoded()) as! [String: Any]
        var settings = json["settings"] as! [String: Any]
        settings["oscPort"] = 80   // below 1024
        json["settings"] = settings
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try ShowFile.load(from: data)
        XCTAssertEqual(decoded.settings.oscPort, 53100, "out-of-range port clamps to the default on decode")
    }

    func testOSCPortAtLowerBoundDecodesUnclamped() throws {
        let show = ShowFile()
        var json = try JSONSerialization.jsonObject(with: show.encoded()) as! [String: Any]
        var settings = json["settings"] as! [String: Any]
        settings["oscPort"] = 1024   // exactly the lower bound — must decode as-is
        json["settings"] = settings
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try ShowFile.load(from: data)
        XCTAssertEqual(decoded.settings.oscPort, 1024)
    }

    /// FIX 6 regression: a port value that doesn't even fit UInt16 (e.g. a
    /// crafted or corrupted 70000) must fall back to the default, not throw
    /// and refuse to open the whole show file — decodeIfPresent(UInt16.self,
    /// …) validates range fit BEFORE the `if let` can catch it and would
    /// propagate a DecodingError straight out of ShowFile.load.
    func testOSCPortAboveUInt16RangeDecodesToDefaultWithoutThrowing() throws {
        let show = ShowFile()
        var json = try JSONSerialization.jsonObject(with: show.encoded()) as! [String: Any]
        var settings = json["settings"] as! [String: Any]
        settings["oscPort"] = 70000
        json["settings"] = settings
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try ShowFile.load(from: data)
        XCTAssertEqual(decoded.settings.oscPort, 53100, "an out-of-UInt16-range port must decode to the default, not throw")
    }

    /// Same failure mode, negative side.
    func testOSCPortNegativeDecodesToDefaultWithoutThrowing() throws {
        let show = ShowFile()
        var json = try JSONSerialization.jsonObject(with: show.encoded()) as! [String: Any]
        var settings = json["settings"] as! [String: Any]
        settings["oscPort"] = -5
        json["settings"] = settings
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try ShowFile.load(from: data)
        XCTAssertEqual(decoded.settings.oscPort, 53100, "a negative port must decode to the default, not throw")
    }

    // MARK: - Panic routing: TriggerRouter.routePanic() reaches transport.panic()

    func testRoutePanicReachesTransport() {
        let app = AppModel()
        XCTAssertFalse(app.transport.isPanicking)
        app.triggerRouter.routePanic()
        XCTAssertTrue(app.transport.isPanicking, "routePanic() must reach the same transport.panic() Esc drives")
    }

    // MARK: - AppModel dispatch: OSCServer.onCommand → TriggerRouter

    func testOSCActionCommandDispatchesThroughTriggerRouter() {
        let app = AppModel()
        let cue = Cue(number: "1", body: .audio(AudioBody(media: MediaReference(absolutePath: "/fake/1.wav"))))
        app.document.mutate { $0.cues = [cue] }
        app.oscServer.onCommand?(.action(.go))
        XCTAssertEqual(app.transport.registry.instances.first?.cue.id, cue.id, ".action(.go) must reach the same GO transport.go() drives")
    }

    func testOSCPanicCommandDispatchesThroughTriggerRouter() {
        let app = AppModel()
        app.oscServer.onCommand?(.panic)
        XCTAssertTrue(app.transport.isPanicking)
    }

    func testOSCFireCueCommandDispatchesThroughTriggerRouter() {
        let app = AppModel()
        let cue = Cue(number: "7", body: .audio(AudioBody(media: MediaReference(absolutePath: "/fake/7.wav"))))
        app.document.mutate { $0.cues = [cue] }
        app.oscServer.onCommand?(.fireCue(number: "7"))
        XCTAssertEqual(app.transport.registry.instances.first?.cue.id, cue.id)
    }
}
