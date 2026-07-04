import XCTest
@testable import StageWizard

final class ShowModelTests: XCTestCase {

    // MARK: - Round trip

    func testShowFileRoundTrip() throws {
        let group = Cue(number: "10", body: .group(GroupBody(mode: .timeline)))
        var child = Cue(
            number: "10.1",
            name: "Thunder",
            body: .audio(AudioBody(
                media: MediaReference(absolutePath: "/Media/thunder.wav"),
                startTime: 1.5,
                endTime: 9.25,
                playCount: 3,
                volumeDB: -6,
                fadeInDuration: 0.5,
                fadeOutDuration: 2,
                outputDeviceUID: "AppleUSBAudioEngine:123",
                outputDeviceName: "Stage Interface"
            ))
        )
        child.parentID = group.id
        child.preWait = 0.25
        child.follow = .autoContinue(postWait: 4)
        child.hotkey = KeyBinding(keyCode: 18, modifiers: 0)

        let video = Cue(
            number: "11",
            body: .video(VideoBody(
                media: MediaReference(relativePath: "Media/intro.mov", absolutePath: "/Shows/Media/intro.mov"),
                endTime: 42,
                display: DisplayFingerprint(vendorNumber: 1552, modelNumber: 999, name: "Projector", pixelWidth: 3840, pixelHeight: 2160),
                fillMode: .fill,
                endBehavior: .holdLastFrame
            ))
        )
        let fade = Cue(number: "12", body: .fade(FadeBody(targetID: child.id, duration: 5, curve: .equalPower, toVolumeDB: -20, stopTargetWhenDone: false)))
        let stop = Cue(number: "13", body: .stop(StopBody(targetID: nil, fadeOutTime: 3)))

        var settings = ShowSettings()
        settings.panicDuration = 5
        settings.keyBindings[.stopAll] = KeyBinding(keyCode: 46, modifiers: 1 << 20)

        let original = ShowFile(settings: settings, cues: [group, child, video, fade, stop])
        let decoded = try ShowFile.load(from: original.encoded())
        XCTAssertEqual(decoded, original)
    }

    func testFollowActionJSONShape() throws {
        let cue = Cue(number: "1", follow: .autoContinue(postWait: 2.5), body: .stop(StopBody()))
        let json = String(data: try JSONEncoder().encode(cue), encoding: .utf8)!
        XCTAssertTrue(json.contains("\"mode\":\"autoContinue\""))
        XCTAssertTrue(json.contains("\"postWait\":2.5"))
    }

    // MARK: - Forward compatibility

    func testUnknownCueTypeDecodesToBroken() throws {
        let json = """
        {
          "formatVersion": 1,
          "settings": {"panicDuration": 3, "doubleGOProtection": 0, "armAheadCount": 3, "keyBindings": {}},
          "cues": [
            {"id": "6F9B95F5-2CBA-44C9-8E1E-6E63C2AF1BC1", "number": "1", "notes": "",
             "armed": true, "preWait": 0, "follow": {"mode": "none"},
             "body": {"type": "hologram", "beamStrength": 11}}
          ]
        }
        """
        let show = try ShowFile.load(from: Data(json.utf8))
        guard case .broken(let broken) = show.cues[0].body else {
            return XCTFail("expected .broken, got \(show.cues[0].body)")
        }
        XCTAssertEqual(broken.originalType, "hologram")
        // Re-encoding must not crash and must preserve the type tag.
        let reencoded = String(data: try show.encoded(), encoding: .utf8)!
        XCTAssertTrue(reencoded.contains("hologram"))
    }

    func testNewerFormatVersionRefusesToLoad() {
        let json = """
        {"formatVersion": 99, "settings": {"panicDuration": 3, "doubleGOProtection": 0, "armAheadCount": 3, "keyBindings": {}}, "cues": []}
        """
        XCTAssertThrowsError(try ShowFile.load(from: Data(json.utf8))) { error in
            guard case ShowFileError.newerFormat(99) = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    // MARK: - Structure helpers

    func testGroupChildrenAndOffsets() {
        var group = GroupBody(mode: .timeline)
        let childID = UUID()
        group.childOffsets[childID] = 2.5
        XCTAssertEqual(group.offset(for: childID), 2.5)
        XCTAssertEqual(group.offset(for: UUID()), 0)

        let fireAll = GroupBody(mode: .fireAll, childOffsets: [childID: 99])
        XCTAssertEqual(fireAll.offset(for: childID), 0, "fire-all ignores offsets")
    }

    func testNextCueNumberSkipsFractions() {
        var show = ShowFile()
        show.cues = [
            Cue(number: "1", body: .stop(StopBody())),
            Cue(number: "2.5", body: .stop(StopBody())),
            Cue(number: "intro", body: .stop(StopBody())),
        ]
        XCTAssertEqual(show.nextCueNumber(), "3")
        XCTAssertEqual(ShowFile().nextCueNumber(), "1")
    }

    // MARK: - Media references

    func testRelativePathComputation() {
        let folder = URL(fileURLWithPath: "/Users/marco/Shows/Tour2026")
        XCTAssertEqual(
            MediaReference.relativePath(of: URL(fileURLWithPath: "/Users/marco/Shows/Tour2026/Media/a.wav"), from: folder),
            "Media/a.wav"
        )
        XCTAssertEqual(
            MediaReference.relativePath(of: URL(fileURLWithPath: "/Users/marco/Media/b.mov"), from: folder),
            "../../Media/b.mov"
        )
    }

    func testMediaResolutionPrefersRelativePath() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sw-test-\(UUID().uuidString)")
        let showFolder = root.appendingPathComponent("Show")
        let mediaFolder = showFolder.appendingPathComponent("Media")
        try fm.createDirectory(at: mediaFolder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let file = mediaFolder.appendingPathComponent("tone.wav")
        try Data("RIFF".utf8).write(to: file)

        // Absolute path points somewhere stale; relative must win.
        let ref = MediaReference(relativePath: "Media/tone.wav", absolutePath: "/nonexistent/tone.wav")
        let resolved = ref.resolve(showFolder: showFolder)
        XCTAssertEqual(resolved?.standardizedFileURL.path, file.standardizedFileURL.path)

        let missing = MediaReference(relativePath: "Media/gone.wav", absolutePath: "/nonexistent/gone.wav")
        XCTAssertNil(missing.resolve(showFolder: showFolder))
    }

    // MARK: - Fade curves

    func testFadeCurveEndpoints() {
        for curve in FadeCurve.allCases {
            XCTAssertEqual(curve.interpolateDB(from: 0, to: -60, at: 0), 0, accuracy: 0.001, "\(curve) start")
            XCTAssertEqual(curve.interpolateDB(from: 0, to: -60, at: 1), -60, accuracy: 0.001, "\(curve) end")
        }
    }

    func testSilenceFloorMapsToZeroAmplitude() {
        XCTAssertEqual(FadeCurve.amplitude(fromDB: silenceFloorDB), 0)
        XCTAssertEqual(FadeCurve.amplitude(fromDB: silenceFloorDB - 40), 0)
        XCTAssertEqual(FadeCurve.amplitude(fromDB: 0), 1, accuracy: 0.0001)
        XCTAssertEqual(FadeCurve.dB(fromAmplitude: 0), silenceFloorDB)
    }

    func testDbLinearIsMonotonic() {
        let curve = FadeCurve.dbLinear
        var last = curve.interpolateDB(from: 0, to: silenceFloorDB, at: 0)
        for step in 1...100 {
            let t = Double(step) / 100
            let level = curve.interpolateDB(from: 0, to: silenceFloorDB, at: t)
            XCTAssertLessThanOrEqual(level, last + 0.0001, "not monotonic at t=\(t)")
            last = level
        }
        XCTAssertEqual(last, silenceFloorDB)
    }

    // MARK: - Timecode

    func testTimecodeParsing() {
        XCTAssertEqual(Timecode.parse("83.5"), 83.5)
        XCTAssertEqual(Timecode.parse("1:23.5"), 83.5)
        XCTAssertEqual(Timecode.parse("01:02:03"), 3723)
        XCTAssertNil(Timecode.parse("abc"))
        XCTAssertNil(Timecode.parse("1:2:3:4"))
        XCTAssertNil(Timecode.parse(""))
    }

    func testTimecodeFormatting() {
        XCTAssertEqual(Timecode.format(83.5), "1:23.500")
        XCTAssertEqual(Timecode.format(9.25), "9.250")
        XCTAssertEqual(Timecode.format(-5), "0.000")
        XCTAssertEqual(Timecode.format(208.542), "3:28.542", "millisecond precision")
    }
}
