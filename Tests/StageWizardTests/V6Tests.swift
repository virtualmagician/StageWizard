import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import StageWizard

@MainActor
final class V6Tests: XCTestCase {

    // MARK: - Image cue model

    func testImageBodyRoundTrip() throws {
        let group = UUID()
        var show = ShowFile()
        show.cues = [Cue(number: "10", body: .image(ImageBody(
            media: MediaReference(absolutePath: "/pics/logo.png"),
            outputGroupID: group,
            fillMode: .fill,
            geometry: VideoGeometry(mode: .custom, x: 0.1, y: -0.2, scaleX: 0.5, scaleY: 0.5),
            fadeInDuration: 1, fadeOutDuration: 2
        )))]
        let decoded = try ShowFile.load(from: show.encoded())
        guard case .image(let body) = decoded.cues[0].body else { return XCTFail() }
        XCTAssertEqual(body.outputGroupID, group)
        XCTAssertEqual(body.fillMode, .fill)
        XCTAssertEqual(body.geometry.mode, .custom)
        XCTAssertEqual(body.fadeInDuration, 1)
        XCTAssertEqual(body.fadeOutDuration, 2)
        XCTAssertEqual(decoded.cues[0].displayName, "logo.png")
        XCTAssertNil(DurationCache.shared.effectiveDuration(
            of: decoded.cues[0], in: decoded, showFolder: nil
        ), "images hold until stopped — no fixed duration")
    }

    // MARK: - Import routing

    func testImportMediaRoutesImagesToImageCues() {
        let document = ShowDocumentController()
        let stage = OutputGroup(name: "Stage", displays: [])
        document.mutate { $0.settings.outputGroups = [stage] }

        CueFactory.importMedia(
            urls: [URL(fileURLWithPath: "/pics/backdrop.jpg")],
            at: nil, into: document
        )
        XCTAssertEqual(document.show.cues.count, 1)
        guard case .image(let body) = document.show.cues[0].body else {
            return XCTFail("jpg should import as an image cue")
        }
        XCTAssertEqual(body.media.fileName, "backdrop.jpg")
        XCTAssertEqual(body.outputGroupID, stage.id, "new image cues route to the first output group")
    }

    func testImportMediaStillSkipsNonMedia() {
        let document = ShowDocumentController()
        let skipped = CueFactory.importMedia(
            urls: [URL(fileURLWithPath: "/notes/readme.txt")],
            at: nil, into: document
        )
        XCTAssertEqual(skipped, 1)
        XCTAssertTrue(document.show.cues.isEmpty)
    }

    // MARK: - Relink plumbing

    func testMediaRelinkAcceptsMatchingTypesOnly() {
        let audio = Cue(number: "1", body: .audio(AudioBody(media: MediaReference(absolutePath: "/a.wav"))))
        let video = Cue(number: "2", body: .video(VideoBody(media: MediaReference(absolutePath: "/v.mov"))))
        let image = Cue(number: "3", body: .image(ImageBody(media: MediaReference(absolutePath: "/i.png"))))
        let wav = URL(fileURLWithPath: "/new.wav")
        let mov = URL(fileURLWithPath: "/new.mov")
        let png = URL(fileURLWithPath: "/new.png")

        XCTAssertTrue(MediaRelink.accepts(wav, for: audio))
        XCTAssertFalse(MediaRelink.accepts(png, for: audio))
        XCTAssertTrue(MediaRelink.accepts(mov, for: video))
        XCTAssertFalse(MediaRelink.accepts(wav, for: video))
        XCTAssertTrue(MediaRelink.accepts(png, for: image))
        XCTAssertFalse(MediaRelink.accepts(mov, for: image))
    }

    func testMediaRelinkReplaceKeepsOtherSettings() {
        let document = ShowDocumentController()
        var body = AudioBody(media: MediaReference(absolutePath: "/old/track.wav"))
        body.startTime = 3
        body.volumeDB = -6
        let cue = Cue(number: "1", body: .audio(body))
        document.mutate { $0.cues = [cue] }

        MediaRelink.replace(cueID: cue.id, with: URL(fileURLWithPath: "/new/track2.wav"), document: document)

        guard case .audio(let updated) = document.show.cues[0].body else { return XCTFail() }
        XCTAssertEqual(updated.media.fileName, "track2.wav")
        XCTAssertEqual(updated.startTime, 3, "trim survives a media swap")
        XCTAssertEqual(updated.volumeDB, -6, "volume survives a media swap")
    }

    // MARK: - Player reuse

    func testStillPlayerArmsFromImageBody() async throws {
        let png = FileManager.default.temporaryDirectory.appendingPathComponent("sw-image-\(UUID().uuidString).png")
        let image = NSImage(size: NSSize(width: 64, height: 36), flipped: false) { rect in
            NSColor.systemOrange.setFill()
            rect.fill()
            return true
        }
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try rep.representation(using: .png, properties: [:])!.write(to: png)
        defer { try? FileManager.default.removeItem(at: png) }

        let target = OutputTarget.preview(id: UUID(), title: "Image Test")
        let body = ImageBody(media: MediaReference(absolutePath: png.path), fadeInDuration: 0.05)
        let player = try await StillCuePlayer.arm(body: body, imageURL: png, targets: [target])
        XCTAssertNotNil(OutputWindowManager.shared.window(for: target))
        XCTAssertNil(player.duration, "images hold until stopped")
        player.start()
        player.stop()
        XCTAssertNil(OutputWindowManager.shared.window(for: target), "lease released")
    }
}
