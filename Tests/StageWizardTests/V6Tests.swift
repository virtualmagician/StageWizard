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

    // MARK: - Drag seam rule (landing parent by BOTH neighbors)

    /// [group, c1, c2, loose] — one open group with two children, one
    /// top-level cue after the block.
    private func seamFixture() -> (document: ShowDocumentController, group: Cue, c1: Cue, c2: Cue, loose: Cue) {
        let document = ShowDocumentController()
        let group = Cue(number: "10", body: .group(GroupBody()))
        var c1 = Cue(number: "10.1", body: .stop(StopBody()))
        var c2 = Cue(number: "10.2", body: .stop(StopBody()))
        c1.parentID = group.id
        c2.parentID = group.id
        let loose = Cue(number: "20", body: .stop(StopBody()))
        document.mutate { $0.cues = [group, c1, c2, loose] }
        return (document, group, c1, c2, loose)
    }

    func testDragChildToSeamBelowGroupExtractsIt() {
        let (document, group, c1, _, _) = seamFixture()
        // Drag c1 (index 1) to the seam below the block (before "loose").
        CueFactory.moveCues(in: document, from: IndexSet(integer: 1), to: 3)
        XCTAssertNil(document.show.cue(withID: c1.id)?.parentID,
                     "the seam below a group is the way OUT of it")
        XCTAssertEqual(document.show.cues.map(\.number), ["10", "10.2", "10.1", "20"])
        _ = group
    }

    func testDragChildToEndOfListExtractsIt() {
        let (document, _, c1, _, _) = seamFixture()
        CueFactory.moveCues(in: document, from: IndexSet(integer: 1), to: 4)
        XCTAssertNil(document.show.cue(withID: c1.id)?.parentID,
                     "extraction works even when nothing follows the group")
    }

    func testDragLooseCueToSeamBelowGroupIsNotAbsorbed() {
        let (document, _, _, _, loose) = seamFixture()
        // Drag "loose" (index 3) up to the seam right below c2 (index 3 → same
        // spot via index 3 after removing? use destination 3: between c2 and loose).
        CueFactory.moveCues(in: document, from: IndexSet(integer: 3), to: 3)
        XCTAssertNil(document.show.cue(withID: loose.id)?.parentID,
                     "block boundary never absorbs")
    }

    func testDragLooseCueBetweenChildrenJoinsGroup() {
        let (document, group, _, _, loose) = seamFixture()
        // Drop strictly between c1 (index 1) and c2 (index 2).
        CueFactory.moveCues(in: document, from: IndexSet(integer: 3), to: 2)
        XCTAssertEqual(document.show.cue(withID: loose.id)?.parentID, group.id,
                       "strictly inside the child block joins the group")
        XCTAssertEqual(document.show.cues.map(\.number), ["10", "10.1", "20", "10.2"])
    }

    func testDragUnderCollapsedEmptyGroupStaysTopLevel() {
        let document = ShowDocumentController()
        let group = Cue(number: "10", body: .group(GroupBody(collapsed: true)))
        let loose = Cue(number: "20", body: .stop(StopBody()))
        document.mutate { $0.cues = [loose, group] }
        // Drag "loose" below the collapsed header.
        CueFactory.moveCues(in: document, from: IndexSet(integer: 0), to: 2)
        XCTAssertNil(document.show.cue(withID: loose.id)?.parentID,
                     "a collapsed header never captures drops")
    }

    func testMoveOutOfGroupCommand() {
        let (document, group, c1, c2, _) = seamFixture()
        document.selection = [c1.id]
        CueFactory.moveOutOfGroup(in: document)
        XCTAssertNil(document.show.cue(withID: c1.id)?.parentID)
        XCTAssertEqual(document.show.cue(withID: c2.id)?.parentID, group.id, "siblings stay put")
        XCTAssertEqual(document.show.cues.map(\.number), ["10", "10.2", "10.1", "20"],
                       "extracted cue lands right after its group block")
    }

    func testHeaderDraggedWithOwnChildKeepsChildInGroup() {
        let (document, group, c1, _, _) = seamFixture()
        // Multi-select the header (0) and c1 (1); drag both to the end.
        CueFactory.moveCues(in: document, from: IndexSet([0, 1]), to: 4)
        XCTAssertEqual(document.show.cue(withID: c1.id)?.parentID, group.id,
                       "a child moved together with its header travels with the group")
        XCTAssertNil(document.show.cue(withID: group.id)?.parentID)
        // Block re-glues wherever the header landed.
        XCTAssertEqual(document.show.cues.map(\.number), ["20", "10", "10.1", "10.2"])
    }

    func testDeckDroppedInsideGroupSlidesToBlockBoundary() {
        let (document, group, _, c2, _) = seamFixture()
        let app = AppModel()
        // Deck dropped between the two children (flat index 2).
        SlideDeckImporter.insertSlideCues(
            images: [URL(fileURLWithPath: "/cache/slide-001.png")],
            deckURL: URL(fileURLWithPath: "/decks/Talk.pptx"),
            at: 2, into: document, app: app
        )
        // The deck group must start after the host group's child block.
        let cues = document.show.cues
        let deckHeaderIndex = cues.firstIndex { $0.name == "Talk" }
        XCTAssertEqual(deckHeaderIndex, 3, "deck slides past the child block")
        XCTAssertEqual(cues[1].parentID, group.id)
        XCTAssertEqual(cues[2].id, c2.id)
        XCTAssertEqual(cues[2].parentID, group.id, "host group's block stays intact")
        XCTAssertNil(cues[3].parentID, "deck group is top-level")
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
