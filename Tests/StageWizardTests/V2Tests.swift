import XCTest
@testable import StageWizard

@MainActor
final class V2Tests: XCTestCase {

    // MARK: - Model round-trips

    func testCameraCueRoundTrip() throws {
        let camera = Cue(number: "50", name: "IMAG", body: .camera(CameraBody(
            cameraUID: "cam-123",
            cameraName: "ATEM Mini",
            display: DisplayFingerprint(name: "Projector", pixelWidth: 1920, pixelHeight: 1080),
            fillMode: .fill,
            fadeInDuration: 0.5,
            fadeOutDuration: 1
        )))
        let show = ShowFile(cues: [camera])
        let decoded = try ShowFile.load(from: show.encoded())
        XCTAssertEqual(decoded, show)
        guard case .camera(let body) = decoded.cues[0].body else { return XCTFail() }
        XCTAssertEqual(body.cameraName, "ATEM Mini")
    }

    func testGroupCollapsedRoundTripAndLegacyDecode() throws {
        var group = Cue(number: "10", body: .group(GroupBody(mode: .fireAll, collapsed: true)))
        group.name = "Part 1"
        let show = ShowFile(cues: [group])
        let decoded = try ShowFile.load(from: show.encoded())
        guard case .group(let body) = decoded.cues[0].body else { return XCTFail() }
        XCTAssertTrue(body.collapsed)

        // Pre-v2 group JSON without "collapsed" must decode to false.
        // (childOffsets is UUID-keyed → Codable encodes it as a flat array.)
        let legacy = """
        {"type": "group", "mode": "timeline", "childOffsets": []}
        """
        let legacyBody = try JSONDecoder().decode(CueBody.self, from: Data(legacy.utf8))
        guard case .group(let old) = legacyBody else { return XCTFail() }
        XCTAssertFalse(old.collapsed)
        XCTAssertEqual(old.mode, .timeline)
    }

    func testLegacyPauseResumeBindingsStillDecode() throws {
        // A pre-v2 show file with pauseAll/resumeAll bindings must load.
        let json = """
        {
          "formatVersion": 1,
          "settings": {"panicDuration": 3, "doubleGOProtection": 0, "armAheadCount": 3,
                       "keyBindings": {"pauseAll": {"keyCode": 35, "modifiers": 0},
                                       "resumeAll": {"keyCode": 15, "modifiers": 0}}},
          "cues": []
        }
        """
        let show = try ShowFile.load(from: Data(json.utf8))
        XCTAssertEqual(show.settings.keyBindings[.pauseAll]?.keyCode, 35)
        // Legacy actions are dispatchable but hidden from the recorder UI.
        XCTAssertFalse(ShortcutAction.assignable.contains(.pauseAll))
        XCTAssertTrue(ShortcutAction.assignable.contains(.togglePlayback))
    }

    // MARK: - Drag & drop import

    func testImportMediaClassifiesAndNumbers() {
        let document = ShowDocumentController()
        let skipped = CueFactory.importMedia(
            urls: [
                URL(fileURLWithPath: "/fake/song.wav"),
                URL(fileURLWithPath: "/fake/clip.mov"),
                URL(fileURLWithPath: "/fake/clip2.mp4"),
                URL(fileURLWithPath: "/fake/notes.txt"),
            ],
            at: nil,
            into: document
        )
        XCTAssertEqual(skipped, 1, "txt is not media")
        XCTAssertEqual(document.show.cues.count, 3)
        guard case .audio = document.show.cues[0].body else { return XCTFail("wav → audio") }
        guard case .video = document.show.cues[1].body else { return XCTFail("mov → video") }
        guard case .video = document.show.cues[2].body else { return XCTFail("mp4 → video") }
        XCTAssertEqual(document.show.cues.map(\.number), ["1", "2", "3"])
        XCTAssertEqual(document.selection.count, 3, "dropped cues are selected")
    }

    func testImportMediaInsideChildBlockJoinsGroup() {
        let document = ShowDocumentController()
        let group = Cue(number: "10", body: .group(GroupBody()))
        var c1 = Cue(number: "10.1", body: .stop(StopBody()))
        var c2 = Cue(number: "10.2", body: .stop(StopBody()))
        c1.parentID = group.id
        c2.parentID = group.id
        document.mutate { $0.cues = [group, c1, c2] }

        // Strictly between two children → deliberately inside the group.
        CueFactory.importMedia(
            urls: [URL(fileURLWithPath: "/fake/bed.wav")],
            at: 2,
            into: document
        )
        XCTAssertEqual(document.show.cues.count, 4)
        XCTAssertEqual(document.show.cues[2].parentID, group.id, "drop between children joins the group")
    }

    func testImportMediaBelowGroupBlockStaysTopLevel() {
        let document = ShowDocumentController()
        let group = Cue(number: "10", body: .group(GroupBody()))
        var child = Cue(number: "10.1", body: .stop(StopBody()))
        child.parentID = group.id
        document.mutate { $0.cues = [group, child] }

        // The seam below the last child is a block boundary — files dropped
        // there must NOT be absorbed into the group.
        CueFactory.importMedia(
            urls: [URL(fileURLWithPath: "/fake/bed.wav")],
            at: 2,
            into: document
        )
        XCTAssertEqual(document.show.cues.count, 3)
        XCTAssertNil(document.show.cues[2].parentID, "drop below the group lands at top level")
    }

    // MARK: - Timecode precision

    func testTimecodeMillisecondPrecisionRoundTrip() {
        let formatted = Timecode.format(208.542)
        XCTAssertEqual(formatted, "3:28.542")
        XCTAssertEqual(Timecode.parse(formatted)!, 208.542, accuracy: 0.0005)
    }
}
