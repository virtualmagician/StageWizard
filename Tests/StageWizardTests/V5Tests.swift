import XCTest
import PDFKit
import AppKit
@testable import StageWizard

@MainActor
final class V5Tests: XCTestCase {

    // MARK: - Slide model

    func testSlideBodyRoundTrip() throws {
        let group = UUID()
        var show = ShowFile()
        show.cues = [Cue(number: "10", body: .slide(SlideBody(
            media: MediaReference(absolutePath: "/cache/slide-001.png"),
            sourceDeck: MediaReference(absolutePath: "/decks/talk.pptx"),
            slideIndex: 1, slideCount: 12,
            outputGroupID: group
        )))]
        let decoded = try ShowFile.load(from: show.encoded())
        guard case .slide(let body) = decoded.cues[0].body else { return XCTFail() }
        XCTAssertEqual(body.slideIndex, 1)
        XCTAssertEqual(body.slideCount, 12)
        XCTAssertEqual(body.outputGroupID, group)
        XCTAssertTrue(body.replacesPreviousSlide)
        XCTAssertEqual(body.deckName, "talk")
        XCTAssertEqual(decoded.cues[0].displayName, "talk · 1/12")
    }

    // MARK: - Replace-on-output runtime semantics

    func testNewSlideReplacesRunningSlideOnSameOutputOnly() async {
        var show = ShowFile()
        show.settings.panicDuration = 0.2
        let provider = MockProvider()
        let transport = TransportController(provider: provider, show: { show }, showFolder: { nil })

        let groupA = UUID(), groupB = UUID()
        func slideCue(_ number: String, group: UUID) -> Cue {
            let cue = Cue(number: number, body: .slide(SlideBody(
                media: MediaReference(absolutePath: "/s\(number).png"),
                outputGroupID: group
            )))
            provider.durations[cue.id] = 60   // slides "hold" — long mock duration
            return cue
        }
        let s1 = slideCue("1", group: groupA)
        let s2 = slideCue("2", group: groupA)
        let other = slideCue("3", group: groupB)
        show.cues = [s1, s2, other]

        transport.fire(cueID: s1.id)
        transport.fire(cueID: other.id)
        try? await Task.sleep(for: .seconds(0.1))
        XCTAssertEqual(transport.registry.instances.count, 2)

        transport.fire(cueID: s2.id)
        try? await Task.sleep(for: .seconds(0.1))
        let p1 = provider.players[s1.id]!
        XCTAssertEqual(p1.fadeOutRequests.count, 1, "slide on the same output gets faded out")
        XCTAssertTrue(p1.fadeOutRequests[0].thenStop)
        XCTAssertTrue(provider.players[other.id]!.fadeOutRequests.isEmpty, "other output untouched")
        try? await Task.sleep(for: .seconds(0.3))
        XCTAssertEqual(transport.registry.instances.count, 2, "s2 + other remain; s1 replaced")
    }

    // MARK: - StillCuePlayer end-to-end on a preview target

    func testStillPlayerShowsAndStopsOnPreviewTarget() async throws {
        // Render a tiny PNG to display.
        let png = FileManager.default.temporaryDirectory.appendingPathComponent("sw-still-\(UUID().uuidString).png")
        let image = NSImage(size: NSSize(width: 64, height: 36), flipped: false) { rect in
            NSColor.systemTeal.setFill()
            rect.fill()
            return true
        }
        let tiff = image.tiffRepresentation!
        let rep = NSBitmapImageRep(data: tiff)!
        try rep.representation(using: .png, properties: [:])!.write(to: png)
        defer { try? FileManager.default.removeItem(at: png) }

        let target = OutputTarget.preview(id: UUID(), title: "Slide Test")
        let body = SlideBody(media: MediaReference(absolutePath: png.path), fadeInDuration: 0.05)
        let player = try await StillCuePlayer.arm(body: body, imageURL: png, targets: [target])
        XCTAssertNotNil(OutputWindowManager.shared.window(for: target))
        XCTAssertNil(player.duration, "stills hold until stopped")
        player.start()
        try? await Task.sleep(for: .seconds(0.15))

        var finishes = 0
        player.onFinished = { _ in finishes += 1 }
        player.stop()
        player.stop()
        XCTAssertEqual(finishes, 1, "idempotent stop")
        XCTAssertNil(OutputWindowManager.shared.window(for: target), "lease released")
    }

    // MARK: - Conversion pipeline

    func testPDFRendersToPerPagePNGs() async throws {
        // Build a 3-page PDF in memory.
        let pdf = PDFDocument()
        for pageIndex in 0..<3 {
            let image = NSImage(size: NSSize(width: 200, height: 112), flipped: false) { rect in
                NSColor(calibratedHue: CGFloat(pageIndex) / 3, saturation: 0.8, brightness: 0.8, alpha: 1).setFill()
                rect.fill()
                return true
            }
            pdf.insert(PDFPage(image: image)!, at: pageIndex)
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sw-pdf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pdfURL = dir.appendingPathComponent("deck.pdf")
        pdf.write(to: pdfURL)

        let images = try await SlideDeckImporter.renderPDF(url: pdfURL, into: dir, renderSize: CGSize(width: 640, height: 360))
        XCTAssertEqual(images.count, 3)
        XCTAssertEqual(images[0].lastPathComponent, "slide-001.png")
        // Pages render at the requested size (aspect-fit).
        let source = CGImageSourceCreateWithURL(images[0] as CFURL, nil)!
        let first = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        XCTAssertEqual(first.width, 640)
    }

    func testX2TParamsAndProbe() {
        let paths = X2TConverter.Paths(
            binary: URL(fileURLWithPath: "/x2t"),
            allFonts: URL(fileURLWithPath: "/fonts/AllFonts.js"),
            fontDir: URL(fileURLWithPath: "/fonts")
        )
        let xml = X2TConverter.paramsXML(
            paths: paths,
            deckURL: URL(fileURLWithPath: "/deck.pptx"),
            outputPNG: URL(fileURLWithPath: "/out/slide.png"),
            renderSize: CGSize(width: 2560, height: 1440)
        )
        XCTAssertTrue(xml.contains("<m_nFormatTo>1029</m_nFormatTo>"))
        XCTAssertTrue(xml.contains("<m_sAllFontsPath>/fonts/AllFonts.js</m_sAllFontsPath>"))
        XCTAssertTrue(xml.contains("<m_sFontDir>/fonts</m_sFontDir>"), "both font params are load-bearing")
        XCTAssertTrue(xml.contains("<first>false</first>"), "false = emit every slide")
        XCTAssertTrue(xml.contains("<width>2560</width>"))
    }

    /// Real end-to-end x2t conversion — runs only where ONLYOFFICE is installed.
    func testX2TConvertsRealDeck() async throws {
        guard let x2t = X2TConverter.probe() else {
            throw XCTSkip("ONLYOFFICE not installed")
        }
        let deck = URL(fileURLWithPath: "/private/tmp/claude-501/-Users-marcotempest-Library-CloudStorage-Dropbox-Newmagic-Marco-Tempest-StageWizard/a83b7efe-bf75-4a8e-9816-4dcae404fa60/scratchpad/test.pptx")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: deck.path), "no fixture deck")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sw-x2t-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let images = try await X2TConverter.convert(x2t: x2t, deckURL: deck, into: dir, renderSize: CGSize(width: 1280, height: 720))
        XCTAssertFalse(images.isEmpty, "x2t produced slides")
        XCTAssertTrue(images[0].lastPathComponent.hasPrefix("slide-"))
    }

    // MARK: - Enter-and-play-first groups

    @MainActor
    private func makeEnterGroupShow() -> (ShowFile, MockProvider, Cue, [Cue], Cue) {
        var show = ShowFile()
        let provider = MockProvider()
        let group = Cue(number: "10", name: "Deck", body: .group(GroupBody(mode: .enterAndPlayFirst)))
        var children: [Cue] = []
        for i in 1...3 {
            var cue = Cue(number: "10.\(i)", body: .slide(SlideBody(
                media: MediaReference(absolutePath: "/s\(i).png"),
                outputGroupID: UUID()
            )))
            cue.parentID = group.id
            provider.durations[cue.id] = 60
            children.append(cue)
        }
        let after = Cue(number: "20", body: .stop(StopBody()))
        show.cues = [group] + children + [after]
        return (show, provider, group, children, after)
    }

    func testEnterGroupGOWalksChildrenThenExits() async {
        var (show, provider, group, children, after) = makeEnterGroupShow()
        _ = group
        let transport = TransportController(provider: provider, show: { show }, showFolder: { nil })

        transport.go()   // enters the deck: child 1
        try? await Task.sleep(for: .seconds(0.1))
        XCTAssertNotNil(provider.players[children[0].id])
        XCTAssertEqual(transport.playheadID, children[1].id, "playhead steps INSIDE the group")

        transport.go()   // child 2
        try? await Task.sleep(for: .seconds(0.1))
        XCTAssertNotNil(provider.players[children[1].id])
        XCTAssertEqual(transport.playheadID, children[2].id)

        transport.go()   // child 3 → exits past the group
        try? await Task.sleep(for: .seconds(0.1))
        XCTAssertEqual(transport.playheadID, after.id, "playhead exits to the cue after the group")
    }

    func testFiringEnterGroupHeaderPlaysFirstChild() async {
        var (show, provider, group, children, _) = makeEnterGroupShow()
        let transport = TransportController(provider: provider, show: { show }, showFolder: { nil })
        transport.fire(cueID: group.id)
        try? await Task.sleep(for: .seconds(0.1))
        XCTAssertNotNil(provider.players[children[0].id], "header fire redirects to first child")
        _ = show
    }

    func testAutoFollowChainsInsideEnterGroup() async {
        var (show, provider, group, children, _) = makeEnterGroupShow()
        _ = group
        // Child 1 auto-follows into child 2; give it a short duration.
        if let index = show.cues.firstIndex(where: { $0.id == children[0].id }) {
            show.cues[index].follow = .autoFollow
        }
        provider.durations[children[0].id] = 0.15
        let transport = TransportController(provider: provider, show: { show }, showFolder: { nil })
        transport.go()
        try? await Task.sleep(for: .seconds(0.4))
        XCTAssertNotNil(provider.players[children[1].id], "enter-group children may chain follows")
    }

    // MARK: - Importer structure

    func testImporterWrapsDeckInEnterGroup() {
        let document = ShowDocumentController()
        let app = AppModel()
        let images = (1...3).map { URL(fileURLWithPath: "/cache/slide-00\($0).png") }
        SlideDeckImporter.insertSlideCues(
            images: images,
            deckURL: URL(fileURLWithPath: "/decks/Opening Talk.pptx"),
            at: nil, into: document, app: app
        )
        let cues = document.show.cues
        XCTAssertEqual(cues.count, 5, "group + 3 slides + clear stop")
        guard case .group(let groupBody) = cues[0].body else { return XCTFail() }
        XCTAssertEqual(groupBody.mode, .enterAndPlayFirst)
        XCTAssertEqual(cues[0].name, "Opening Talk")
        XCTAssertEqual(cues[0].number, "1")
        for child in cues[1...] {
            XCTAssertEqual(child.parentID, cues[0].id, "all content nests under the deck group")
        }
        XCTAssertEqual(cues.map(\.number), ["1", "1.1", "1.2", "1.3", "1.4"])
        guard case .stop(let stopBody) = cues[4].body else { return XCTFail("trailing clear cue") }
        XCTAssertEqual(stopBody.targetID, cues[3].id, "clear stops the last slide")
    }

    // MARK: - Renumbering

    func testRenumberAllTopToBottom() {
        let group = Cue(number: "3", body: .group(GroupBody()))
        var c1 = Cue(number: "x", body: .stop(StopBody()))
        var c2 = Cue(number: "y", body: .stop(StopBody()))
        c1.parentID = group.id
        c2.parentID = group.id
        let a = Cue(number: "99", body: .stop(StopBody()))
        let b = Cue(number: "1.5", body: .stop(StopBody()))

        let renumbered = CueFactory.renumbered([a, group, c1, c2, b])
        XCTAssertEqual(renumbered.map(\.number), ["10", "20", "20.1", "20.2", "30"])
    }
}
