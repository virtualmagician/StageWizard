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
