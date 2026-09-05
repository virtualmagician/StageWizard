import XCTest
@testable import StageWizard

@MainActor
final class PreflightTests: XCTestCase {

    private func makeTempMediaFile(extension ext: String = "wav") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sw-preflight-\(UUID().uuidString).\(ext)")
        try? Data("not really media, just needs to exist".utf8).write(to: url)
        return url
    }

    /// A fingerprint that cannot plausibly match any display actually
    /// attached to the test machine — mirrors the pattern VideoEngineTests
    /// and V3Tests use for "offline" display fixtures.
    private func unmatchableFingerprint() -> DisplayFingerprint {
        DisplayFingerprint(
            vendorNumber: 0xDEAD_BEEF,
            modelNumber: 0xDEAD_BEEF,
            serialNumber: 0xDEAD_BEEF,
            name: "Nonexistent Preflight Test Display",
            pixelWidth: 1,
            pixelHeight: 1
        )
    }

    // MARK: - Media resolution

    func testMissingMediaOnArmedAudioCueIsOneError() {
        var show = ShowFile()
        show.cues = [Cue(number: "1", body: .audio(AudioBody(media: MediaReference(absolutePath: "/nonexistent/tone.wav"))))]
        let issues = Preflight.run(
            show: show, showFolder: nil, cameraAuthorized: true, virtualCamFeeding: false, connectedDevices: []
        )
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.severity, .error)
        XCTAssertTrue(issues.first?.message.contains("media file missing") ?? false)
        XCTAssertEqual(issues.first?.cueNumber, "1")
    }

    func testResolvableMediaProducesNoMediaIssue() {
        let file = makeTempMediaFile()
        defer { try? FileManager.default.removeItem(at: file) }
        var show = ShowFile()
        show.cues = [Cue(number: "1", body: .audio(AudioBody(media: MediaReference(absolutePath: file.path))))]
        let issues = Preflight.run(
            show: show, showFolder: nil, cameraAuthorized: true, virtualCamFeeding: false, connectedDevices: []
        )
        XCTAssertTrue(issues.isEmpty, "a plain resolvable audio cue should be clean: \(issues)")
    }

    // MARK: - Output group assignment (visual cues)

    func testVideoCueWithNilOutputGroupIsError() {
        let file = makeTempMediaFile(extension: "mov")
        defer { try? FileManager.default.removeItem(at: file) }
        var show = ShowFile()
        show.cues = [Cue(number: "1", body: .video(VideoBody(media: MediaReference(absolutePath: file.path))))]
        let issues = Preflight.run(
            show: show, showFolder: nil, cameraAuthorized: true, virtualCamFeeding: false, connectedDevices: []
        )
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.severity, .error)
        XCTAssertTrue(issues.first?.message.contains("no video output assigned") ?? false)
    }

    func testCameraCueWithNilOutputGroupIsErrorMatchingVideo() {
        var show = ShowFile()
        show.cues = [Cue(number: "1", body: .camera(CameraBody()))]
        let issues = Preflight.run(
            show: show, showFolder: nil, cameraAuthorized: true, virtualCamFeeding: false, connectedDevices: []
        )
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.severity, .error)
        XCTAssertTrue(issues.first?.message.contains("no video output assigned") ?? false)
    }

    // MARK: - D25: sensor-only camera cues are exempt from the output-group checks

    func testSensorOnlyCameraCueWithNilOutputGroupHasNoError() {
        var show = ShowFile()
        show.cues = [Cue(number: "1", body: .camera(CameraBody(sensorOnly: true)))]
        let issues = Preflight.run(
            show: show, showFolder: nil, cameraAuthorized: true, virtualCamFeeding: false, connectedDevices: []
        )
        XCTAssertTrue(issues.isEmpty, "a sensor-only camera cue needs no output group: \(issues)")
    }

    func testSensorOnlyCameraCueStillNeedsCameraAuthorization() {
        var show = ShowFile()
        show.cues = [Cue(number: "1", body: .camera(CameraBody(sensorOnly: true)))]
        let issues = Preflight.run(
            show: show, showFolder: nil, cameraAuthorized: false, virtualCamFeeding: false, connectedDevices: []
        )
        XCTAssertTrue(issues.contains {
            $0.cueNumber == nil && $0.severity == .error && $0.message.contains("Camera access")
        }, "sensor-only still needs camera permission — only the output-group check is exempt")
    }

    // MARK: - Output group display connectivity, and the virtual-webcam carve-out

    func testVideoCueWithAllGroupDisplaysDisconnectedIsError() {
        let file = makeTempMediaFile(extension: "mov")
        defer { try? FileManager.default.removeItem(at: file) }
        let group = OutputGroup(name: "Offline Output", displays: [unmatchableFingerprint()])
        var show = ShowFile()
        show.settings.outputGroups = [group]
        show.cues = [Cue(
            number: "1",
            body: .video(VideoBody(media: MediaReference(absolutePath: file.path), outputGroupID: group.id))
        )]
        let issues = Preflight.run(
            show: show, showFolder: nil, cameraAuthorized: true, virtualCamFeeding: false, connectedDevices: []
        )
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.severity, .error)
        XCTAssertTrue(issues.first?.message.contains("no assigned display is connected") ?? false)
    }

    func testVirtualCameraGroupUnfedStillErrorsAndAlsoWarns() {
        let file = makeTempMediaFile(extension: "mov")
        defer { try? FileManager.default.removeItem(at: file) }
        let group = OutputGroup(name: "Stream Output", displays: [unmatchableFingerprint()], virtualCamera: true)
        var show = ShowFile()
        show.settings.outputGroups = [group]
        show.cues = [Cue(
            number: "1",
            body: .video(VideoBody(media: MediaReference(absolutePath: file.path), outputGroupID: group.id))
        )]

        // Not feeding: the missing-display error is NOT suppressed, and the
        // separate "feed isn't running" warning also fires.
        let unfed = Preflight.run(
            show: show, showFolder: nil, cameraAuthorized: true, virtualCamFeeding: false, connectedDevices: []
        )
        XCTAssertEqual(unfed.count, 2, "\(unfed)")
        XCTAssertTrue(unfed.contains { $0.severity == .error && $0.message.contains("no assigned display is connected") })
        XCTAssertTrue(unfed.contains { $0.severity == .warning && $0.message.contains("virtual webcam feed is not running") })

        // Feeding: the virtual cam covers for the missing physical display,
        // and there's nothing left to warn about either.
        let fed = Preflight.run(
            show: show, showFolder: nil, cameraAuthorized: true, virtualCamFeeding: true, connectedDevices: []
        )
        XCTAssertTrue(fed.isEmpty, "a fed virtual-cam output should be clean: \(fed)")
    }

    // MARK: - D14: floating-window output groups skip the connectivity check

    func testFloatingWindowGroupWithZeroDisplaysHasNoConnectivityError() {
        let file = makeTempMediaFile(extension: "mov")
        defer { try? FileManager.default.removeItem(at: file) }
        let group = OutputGroup(name: "Prompter", displays: [], floatingWindow: true)
        var show = ShowFile()
        show.settings.outputGroups = [group]
        show.cues = [Cue(
            number: "1",
            body: .video(VideoBody(media: MediaReference(absolutePath: file.path), outputGroupID: group.id))
        )]
        let issues = Preflight.run(
            show: show, showFolder: nil, cameraAuthorized: true, virtualCamFeeding: false, connectedDevices: []
        )
        XCTAssertTrue(issues.isEmpty, "a floating-window group needs no display at all: \(issues)")
    }

    func testSameGroupWithoutFloatingWindowStillErrorsWithZeroDisplays() {
        let file = makeTempMediaFile(extension: "mov")
        defer { try? FileManager.default.removeItem(at: file) }
        let group = OutputGroup(name: "Prompter", displays: [], floatingWindow: false)
        var show = ShowFile()
        show.settings.outputGroups = [group]
        show.cues = [Cue(
            number: "1",
            body: .video(VideoBody(media: MediaReference(absolutePath: file.path), outputGroupID: group.id))
        )]
        let issues = Preflight.run(
            show: show, showFolder: nil, cameraAuthorized: true, virtualCamFeeding: false, connectedDevices: []
        )
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.severity, .error)
        XCTAssertTrue(issues.first?.message.contains("no assigned display is connected") ?? false)
    }

    // MARK: - Broken cue bodies

    func testBrokenCueBodyIsError() {
        var show = ShowFile()
        show.cues = [Cue(number: "1", body: .broken(BrokenBody(originalType: "hologram")))]
        let issues = Preflight.run(
            show: show, showFolder: nil, cameraAuthorized: true, virtualCamFeeding: false, connectedDevices: []
        )
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.severity, .error)
    }

    // MARK: - Disarmed cues

    func testDisarmedCueWithMissingMediaIsWarningNotError() {
        var show = ShowFile()
        show.cues = [Cue(
            number: "1", armed: false,
            body: .audio(AudioBody(media: MediaReference(absolutePath: "/nonexistent/tone.wav")))
        )]
        let issues = Preflight.run(
            show: show, showFolder: nil, cameraAuthorized: true, virtualCamFeeding: false, connectedDevices: []
        )
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.severity, .warning)
    }

    func testDisarmedVideoCueSkipsOutputCheckEntirely() {
        let file = makeTempMediaFile(extension: "mov")
        defer { try? FileManager.default.removeItem(at: file) }
        var show = ShowFile()
        show.cues = [Cue(
            number: "1", armed: false,
            body: .video(VideoBody(media: MediaReference(absolutePath: file.path)))
        )]
        let issues = Preflight.run(
            show: show, showFolder: nil, cameraAuthorized: true, virtualCamFeeding: false, connectedDevices: []
        )
        XCTAssertTrue(issues.isEmpty, "disarmed cues skip output/device checks entirely: \(issues)")
    }

    // MARK: - Camera permission

    func testCameraCuePresentAndUnauthorizedIsError() {
        var show = ShowFile()
        show.cues = [Cue(number: "1", body: .camera(CameraBody()))]
        let issues = Preflight.run(
            show: show, showFolder: nil, cameraAuthorized: false, virtualCamFeeding: false, connectedDevices: []
        )
        XCTAssertTrue(issues.contains {
            $0.cueNumber == nil && $0.severity == .error && $0.message.contains("Camera access")
        })
    }

    func testCameraCuePresentAndAuthorizedHasNoPermissionIssue() {
        var show = ShowFile()
        show.cues = [Cue(number: "1", body: .camera(CameraBody()))]
        let issues = Preflight.run(
            show: show, showFolder: nil, cameraAuthorized: true, virtualCamFeeding: false, connectedDevices: []
        )
        XCTAssertFalse(issues.contains { $0.message.contains("Camera access") })
    }

    // MARK: - Audio device resolution

    func testAudioCueWithDisconnectedDeviceUIDIsWarning() {
        let file = makeTempMediaFile()
        defer { try? FileManager.default.removeItem(at: file) }
        var show = ShowFile()
        show.cues = [Cue(number: "1", body: .audio(AudioBody(
            media: MediaReference(absolutePath: file.path),
            outputDeviceUID: "com.example.gone"
        )))]
        let issues = Preflight.run(
            show: show, showFolder: nil, cameraAuthorized: true, virtualCamFeeding: false, connectedDevices: []
        )
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.severity, .warning)
        XCTAssertTrue(issues.first?.message.contains("audio device not connected") ?? false)
    }

    func testAudioCueWithConnectedDeviceUIDHasNoDeviceIssue() {
        let file = makeTempMediaFile()
        defer { try? FileManager.default.removeItem(at: file) }
        var show = ShowFile()
        show.cues = [Cue(number: "1", body: .audio(AudioBody(
            media: MediaReference(absolutePath: file.path),
            outputDeviceUID: "com.example.present"
        )))]
        let devices = [AudioOutputDevice(deviceID: 1, uid: "com.example.present", name: "Test Interface", channelCount: 2)]
        let issues = Preflight.run(
            show: show, showFolder: nil, cameraAuthorized: true, virtualCamFeeding: false, connectedDevices: devices
        )
        XCTAssertTrue(issues.isEmpty, "\(issues)")
    }

    // MARK: - D17: operator-screen collision warning

    func testStageDisplayCoveringOperatorScreenProducesAWarning() {
        let issues = Preflight.run(
            show: ShowFile(), showFolder: nil, cameraAuthorized: true, virtualCamFeeding: false,
            connectedDevices: [], stageDisplayCoversOperatorScreen: true
        )
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.severity, .warning)
        XCTAssertNil(issues.first?.cueNumber, "show-wide, not tied to a cue")
        XCTAssertTrue(issues.first?.message.contains("operator's own screen") ?? false)
    }

    func testStageDisplayNotCoveringOperatorScreenProducesNoWarning() {
        let issues = Preflight.run(
            show: ShowFile(), showFolder: nil, cameraAuthorized: true, virtualCamFeeding: false,
            connectedDevices: [], stageDisplayCoversOperatorScreen: false
        )
        XCTAssertTrue(issues.isEmpty, "\(issues)")
    }

    // MARK: - D29: OSC Send cues

    func testArmedOSCCueWithEmptyHostIsError() {
        var show = ShowFile()
        show.cues = [Cue(number: "1", body: .oscSend(OSCSendBody(host: "")))]
        let issues = Preflight.run(
            show: show, showFolder: nil, cameraAuthorized: true, virtualCamFeeding: false, connectedDevices: []
        )
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.severity, .error)
        XCTAssertTrue(issues.first?.message.contains("no destination host") ?? false)
    }

    func testArmedOSCCueWithHostAndDefaultAddressHasNoIssue() {
        var show = ShowFile()
        show.cues = [Cue(number: "1", body: .oscSend(OSCSendBody(host: "127.0.0.1")))]
        let issues = Preflight.run(
            show: show, showFolder: nil, cameraAuthorized: true, virtualCamFeeding: false, connectedDevices: []
        )
        XCTAssertTrue(issues.isEmpty, "a configured OSC cue should be clean: \(issues)")
    }

    func testOSCCueWithMalformedAddressIsWarning() {
        var show = ShowFile()
        show.cues = [Cue(number: "1", body: .oscSend(OSCSendBody(host: "127.0.0.1", address: "go")))]
        let issues = Preflight.run(
            show: show, showFolder: nil, cameraAuthorized: true, virtualCamFeeding: false, connectedDevices: []
        )
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.severity, .warning)
        XCTAssertTrue(issues.first?.message.contains("doesn't start with") ?? false)
    }

    func testDisarmedOSCCueWithEmptyHostSkipsCheckEntirely() {
        var show = ShowFile()
        show.cues = [Cue(number: "1", armed: false, body: .oscSend(OSCSendBody(host: "")))]
        let issues = Preflight.run(
            show: show, showFolder: nil, cameraAuthorized: true, virtualCamFeeding: false, connectedDevices: []
        )
        XCTAssertTrue(issues.isEmpty, "disarmed cues skip the OSC checks entirely, like output/device checks: \(issues)")
    }

    // MARK: - D30: MIDI Send cues

    func testArmedMIDICueWithUnmatchedDestinationNameIsWarning() {
        var show = ShowFile()
        show.cues = [Cue(number: "1", body: .midiSend(MIDISendBody(destinationName: "Nonexistent Synth")))]
        let issues = Preflight.run(
            show: show, showFolder: nil, cameraAuthorized: true, virtualCamFeeding: false, connectedDevices: [],
            midiDestinations: ["Some Other Device"]
        )
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.severity, .warning)
        XCTAssertTrue(issues.first?.message.contains("Nonexistent Synth") ?? false)
        XCTAssertTrue(issues.first?.message.contains("is not connected") ?? false)
    }

    func testArmedMIDICueWithMatchingDestinationNameHasNoIssueCaseInsensitively() {
        var show = ShowFile()
        show.cues = [Cue(number: "1", body: .midiSend(MIDISendBody(destinationName: "iac driver bus 1")))]
        let issues = Preflight.run(
            show: show, showFolder: nil, cameraAuthorized: true, virtualCamFeeding: false, connectedDevices: [],
            midiDestinations: ["IAC Driver Bus 1"]
        )
        XCTAssertTrue(issues.isEmpty, "a case-insensitive match must not warn: \(issues)")
    }

    func testArmedMIDICueWithEmptyDestinationNameHasNoIssueEvenWithNoDestinations() {
        // "" = ALL destinations — unlike OSC's empty host, this is a valid
        // configuration, never an error or a warning.
        var show = ShowFile()
        show.cues = [Cue(number: "1", body: .midiSend(MIDISendBody(destinationName: "")))]
        let issues = Preflight.run(
            show: show, showFolder: nil, cameraAuthorized: true, virtualCamFeeding: false, connectedDevices: [],
            midiDestinations: []
        )
        XCTAssertTrue(issues.isEmpty, "an empty (ALL) destination name is never flagged: \(issues)")
    }

    func testDisarmedMIDICueWithUnmatchedDestinationNameSkipsCheckEntirely() {
        var show = ShowFile()
        show.cues = [Cue(number: "1", armed: false, body: .midiSend(MIDISendBody(destinationName: "Nonexistent Synth")))]
        let issues = Preflight.run(
            show: show, showFolder: nil, cameraAuthorized: true, virtualCamFeeding: false, connectedDevices: [],
            midiDestinations: []
        )
        XCTAssertTrue(issues.isEmpty, "disarmed cues skip the MIDI check entirely, like output/device checks: \(issues)")
    }

    func testMIDIDestinationsParameterDefaultsToEmptyWhenOmitted() {
        // Existing call sites (and every other test above) don't pass this
        // parameter at all — a non-empty configured destination must still
        // warn rather than silently matching everything.
        var show = ShowFile()
        show.cues = [Cue(number: "1", body: .midiSend(MIDISendBody(destinationName: "Nonexistent Synth")))]
        let issues = Preflight.run(
            show: show, showFolder: nil, cameraAuthorized: true, virtualCamFeeding: false, connectedDevices: []
        )
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.severity, .warning)
    }

    // MARK: - D31: GoTo cues

    func testArmedGoToCueWithNilTargetIsError() {
        var show = ShowFile()
        show.cues = [Cue(number: "1", body: .goTo(GoToBody(targetID: nil)))]
        let issues = Preflight.run(
            show: show, showFolder: nil, cameraAuthorized: true, virtualCamFeeding: false, connectedDevices: []
        )
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.severity, .error)
        XCTAssertTrue(issues.first?.message.contains("no target assigned") ?? false)
    }

    func testArmedGoToCueWithDeletedTargetIsError() {
        var show = ShowFile()
        show.cues = [Cue(number: "1", body: .goTo(GoToBody(targetID: UUID())))]
        let issues = Preflight.run(
            show: show, showFolder: nil, cameraAuthorized: true, virtualCamFeeding: false, connectedDevices: []
        )
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.severity, .error)
        XCTAssertTrue(issues.first?.message.contains("no longer exists") ?? false)
    }

    func testArmedGoToCueTargetingItselfIsError() {
        var show = ShowFile()
        let id = UUID()
        show.cues = [Cue(id: id, number: "1", body: .goTo(GoToBody(targetID: id)))]
        let issues = Preflight.run(
            show: show, showFolder: nil, cameraAuthorized: true, virtualCamFeeding: false, connectedDevices: []
        )
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.severity, .error)
        XCTAssertTrue(issues.first?.message.contains("targets itself") ?? false)
    }

    func testArmedGoToCueWithValidDistinctTargetHasNoIssue() {
        var show = ShowFile()
        let target = Cue(number: "2", body: .stop(StopBody()))
        show.cues = [Cue(number: "1", body: .goTo(GoToBody(targetID: target.id))), target]
        let issues = Preflight.run(
            show: show, showFolder: nil, cameraAuthorized: true, virtualCamFeeding: false, connectedDevices: []
        )
        XCTAssertTrue(issues.isEmpty, "a configured GoTo cue should be clean: \(issues)")
    }

    func testDisarmedGoToCueWithNilTargetSkipsCheckEntirely() {
        var show = ShowFile()
        show.cues = [Cue(number: "1", armed: false, body: .goTo(GoToBody(targetID: nil)))]
        let issues = Preflight.run(
            show: show, showFolder: nil, cameraAuthorized: true, virtualCamFeeding: false, connectedDevices: []
        )
        XCTAssertTrue(issues.isEmpty, "disarmed cues skip the GoTo check entirely, like output/device checks: \(issues)")
    }

    // MARK: - D31: HTTP Request cues

    func testArmedHTTPCueWithEmptyURLIsError() {
        var show = ShowFile()
        show.cues = [Cue(number: "1", body: .httpRequest(HTTPRequestBody(urlString: "")))]
        let issues = Preflight.run(
            show: show, showFolder: nil, cameraAuthorized: true, virtualCamFeeding: false, connectedDevices: []
        )
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.severity, .error)
        XCTAssertTrue(issues.first?.message.contains("no URL set") ?? false)
    }

    func testArmedHTTPCueWithURLThatFailsToParseIsError() {
        var show = ShowFile()
        // An unterminated IPv6-literal bracket is rejected outright by
        // URL(string:) on this Foundation (unlike plain unescaped spaces,
        // which it percent-encodes rather than refusing).
        show.cues = [Cue(number: "1", body: .httpRequest(HTTPRequestBody(urlString: "http://[invalid")))]
        let issues = Preflight.run(
            show: show, showFolder: nil, cameraAuthorized: true, virtualCamFeeding: false, connectedDevices: []
        )
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.severity, .error)
        XCTAssertTrue(issues.first?.message.contains("not valid") ?? false)
    }

    func testArmedHTTPCueWithPlainHTTPURLHasNoWarning() {
        // Plain http:// is the NORM for show-network gear — never flagged,
        // not even as a warning (see project.yml's ATS exemption).
        var show = ShowFile()
        show.cues = [Cue(number: "1", body: .httpRequest(HTTPRequestBody(urlString: "http://10.0.0.5/relay/on")))]
        let issues = Preflight.run(
            show: show, showFolder: nil, cameraAuthorized: true, virtualCamFeeding: false, connectedDevices: []
        )
        XCTAssertTrue(issues.isEmpty, "plain http:// must never be flagged: \(issues)")
    }

    func testDisarmedHTTPCueWithEmptyURLSkipsCheckEntirely() {
        var show = ShowFile()
        show.cues = [Cue(number: "1", armed: false, body: .httpRequest(HTTPRequestBody(urlString: "")))]
        let issues = Preflight.run(
            show: show, showFolder: nil, cameraAuthorized: true, virtualCamFeeding: false, connectedDevices: []
        )
        XCTAssertTrue(issues.isEmpty, "disarmed cues skip the HTTP check entirely, like output/device checks: \(issues)")
    }

    func testStageDisplayCollisionWarningDefaultsToFalseWhenOmitted() {
        // Existing call sites (and every other test above) don't pass this
        // parameter at all — it must default to "no collision", not crash
        // or silently warn.
        let issues = Preflight.run(
            show: ShowFile(), showFolder: nil, cameraAuthorized: true, virtualCamFeeding: false, connectedDevices: []
        )
        XCTAssertTrue(issues.isEmpty, "\(issues)")
    }
}
