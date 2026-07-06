import XCTest
import AppKit
@testable import StageWizard

@MainActor
final class V7Tests: XCTestCase {

    // MARK: - Render layers (1 = background … 10 = front)

    func testLayerDecodesToFiveForOlderFiles() throws {
        // A pre-layer show file: encode with layer stripped via raw JSON.
        var show = ShowFile()
        show.cues = [
            Cue(number: "1", body: .video(VideoBody(media: MediaReference(absolutePath: "/v.mov")))),
            Cue(number: "2", body: .camera(CameraBody())),
            Cue(number: "3", body: .image(ImageBody(media: MediaReference(absolutePath: "/i.png")))),
            Cue(number: "4", body: .slide(SlideBody(media: MediaReference(absolutePath: "/s.png")))),
        ]
        var json = try JSONSerialization.jsonObject(with: show.encoded()) as! [String: Any]
        var cues = json["cues"] as! [[String: Any]]
        for index in cues.indices {
            var body = cues[index]["body"] as! [String: Any]
            body.removeValue(forKey: "layer")
            cues[index]["body"] = body
        }
        json["cues"] = cues
        let stripped = try JSONSerialization.data(withJSONObject: json)
        let decoded = try ShowFile.load(from: stripped)

        for cue in decoded.cues {
            let layer: Int? = switch cue.body {
            case .video(let b): b.layer
            case .camera(let b): b.layer
            case .image(let b): b.layer
            case .slide(let b): b.layer
            default: nil
            }
            XCTAssertEqual(layer, 5, "older files land on the middle layer (\(cue.number))")
        }
    }

    func testLayerClampsToValidRange() throws {
        let body = ImageBody(media: MediaReference(absolutePath: "/i.png"), layer: 99)
        XCTAssertEqual(body.layer, 10)
        let low = VideoBody(media: MediaReference(absolutePath: "/v.mov"), layer: -3)
        XCTAssertEqual(low.layer, 1)
    }

    // MARK: - .pex emitter parsing

    private func fixtureData(_ name: String, _ ext: String) throws -> Data {
        let url = Bundle(for: V7Tests.self).url(forResource: name, withExtension: ext)
        return try Data(contentsOf: try XCTUnwrap(url, "fixture \(name).\(ext) in test bundle"))
    }

    func testPEXParsesRealParticleDesignerFile() throws {
        let config = try XCTUnwrap(PEXEmitterConfig.parse(data: fixtureData("test1", "pex")))
        XCTAssertEqual(config.maxParticles, 750)
        XCTAssertEqual(config.particleLifeSpan, 3.9197, accuracy: 0.0001)
        XCTAssertEqual(config.speed, 43.85, accuracy: 0.001)
        XCTAssertEqual(config.angleVariance, 360)
        XCTAssertEqual(config.gravityX, 158.80, accuracy: 0.001)
        XCTAssertEqual(config.gravityY, -254.46, accuracy: 0.001)
        XCTAssertEqual(config.startColor.blue, 0.84, accuracy: 0.001)
        XCTAssertEqual(config.startParticleSize, 37)
        XCTAssertEqual(config.emitterType, 0, "gravity-type emitter")
        XCTAssertTrue(config.isAdditive, "770/1 = srcAlpha/one")
        XCTAssertNotNil(config.texture, "embedded gzip texture decodes")
        XCTAssertGreaterThan(config.texture?.width ?? 0, 0)
    }

    func testPEXEmitterLayerMapping() throws {
        let config = try XCTUnwrap(PEXEmitterConfig.parse(data: fixtureData("test1", "pex")))
        let layer = config.makeEmitterLayer()
        XCTAssertEqual(layer.birthRate, 0, "emitters start tapped off (no hand yet)")
        let cell = try XCTUnwrap(layer.emitterCells?.first)
        XCTAssertEqual(cell.birthRate, Float(750 / 3.9197), accuracy: 0.5)
        XCTAssertEqual(cell.lifetime, 3.9197, accuracy: 0.001)
        XCTAssertEqual(cell.velocity, 43.85, accuracy: 0.01)
        XCTAssertNotNil(cell.contents)
    }

    func testGunzipRejectsGarbageAndAcceptsGzip() throws {
        XCTAssertNil(PEXEmitterConfig.gunzip(Data([0, 1, 2, 3])))
        // Round-trip a known gzip blob (made by /usr/bin/gzip semantics is
        // overkill here — the embedded texture in test1.pex covers the
        // positive path; this pins the header validation).
        XCTAssertNil(PEXEmitterConfig.gunzip(Data()))
    }

    func testBuiltinSparkleIsUsable() {
        let config = PEXEmitterConfig.builtinSparkle()
        XCTAssertNotNil(config.texture)
        let layer = config.makeEmitterLayer()
        XCTAssertEqual(layer.emitterCells?.count, 1)
    }

    // MARK: - Camera effects

    func testCameraEffectsDefaultOffForOlderFiles() throws {
        var show = ShowFile()
        show.cues = [Cue(number: "1", body: .camera(CameraBody()))]
        var json = try JSONSerialization.jsonObject(with: show.encoded()) as! [String: Any]
        var cues = json["cues"] as! [[String: Any]]
        var body = cues[0]["body"] as! [String: Any]
        body.removeValue(forKey: "effects")
        cues[0]["body"] = body
        json["cues"] = cues
        let decoded = try ShowFile.load(from: try JSONSerialization.data(withJSONObject: json))
        guard case .camera(let camera) = decoded.cues[0].body else { return XCTFail() }
        XCTAssertFalse(camera.effects.segmentation)
        XCTAssertFalse(camera.effects.magicDust)
        XCTAssertFalse(camera.effects.anyEnabled)
    }

    func testCameraEffectsRoundTrip() throws {
        let effects = CameraEffects(
            segmentation: true, magicDust: true,
            dustEmitter: MediaReference(absolutePath: "/fx/sparkle.pex")
        )
        let body = CameraBody(effects: effects)
        let data = try JSONEncoder().encode(body)
        let decoded = try JSONDecoder().decode(CameraBody.self, from: data)
        XCTAssertTrue(decoded.effects.segmentation)
        XCTAssertTrue(decoded.effects.magicDust)
        XCTAssertEqual(decoded.effects.dustEmitter?.fileName, "sparkle.pex")
    }

    // MARK: - Capture → layer coordinate mapping

    func testMapNormalizedPointStretch() {
        let p = mapNormalizedPoint(
            CGPoint(x: 0.25, y: 0.5),
            bufferSize: CGSize(width: 1920, height: 1080),
            layerSize: CGSize(width: 800, height: 800),
            fillMode: .stretch
        )
        XCTAssertEqual(p, CGPoint(x: 200, y: 400))
    }

    func testMapNormalizedPointFitLetterboxes() {
        // 16:9 buffer in a square layer → letterboxed: 800×450 centered.
        let center = mapNormalizedPoint(
            CGPoint(x: 0.5, y: 0.5),
            bufferSize: CGSize(width: 1920, height: 1080),
            layerSize: CGSize(width: 800, height: 800),
            fillMode: .fit
        )
        XCTAssertEqual(center, CGPoint(x: 400, y: 400))
        let bottomLeft = mapNormalizedPoint(
            .zero,
            bufferSize: CGSize(width: 1920, height: 1080),
            layerSize: CGSize(width: 800, height: 800),
            fillMode: .fit
        )
        XCTAssertEqual(bottomLeft.x, 0, accuracy: 0.001)
        XCTAssertEqual(bottomLeft.y, (800 - 450) / 2, accuracy: 0.001, "letterbox band below the image")
    }

    func testMapNormalizedPointFillCrops() {
        // 16:9 buffer filling a square layer → 1422×800, x cropped.
        let bottomLeft = mapNormalizedPoint(
            .zero,
            bufferSize: CGSize(width: 1920, height: 1080),
            layerSize: CGSize(width: 800, height: 800),
            fillMode: .fill
        )
        XCTAssertEqual(bottomLeft.y, 0, accuracy: 0.001)
        XCTAssertLessThan(bottomLeft.x, 0, "cropped content maps off the left edge")
    }

    // MARK: - Text cues

    private func makeRTF(_ string: String) -> Data {
        let attributed = NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: 96, weight: .bold),
            .foregroundColor: NSColor.white,
        ])
        return attributed.rtf(from: NSRange(location: 0, length: attributed.length), documentAttributes: [:])!
    }

    func testTextBodyRoundTrip() throws {
        let group = UUID()
        var show = ShowFile()
        show.cues = [Cue(number: "10", body: .text(TextBody(
            rtf: makeRTF("Welcome to the show"),
            plainPreview: "Welcome to the show",
            backgroundColor: RGBAColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.9),
            outputGroupID: group,
            fadeInDuration: 0.5, fadeOutDuration: 1,
            layer: 9
        )))]
        let decoded = try ShowFile.load(from: show.encoded())
        guard case .text(let body) = decoded.cues[0].body else { return XCTFail() }
        XCTAssertEqual(body.outputGroupID, group)
        XCTAssertEqual(body.backgroundColor?.blue ?? 0, 0.3, accuracy: 0.0001)
        XCTAssertEqual(body.layer, 9)
        XCTAssertEqual(decoded.cues[0].displayName, "Welcome to the show")
        let attributed = NSAttributedString(rtf: body.rtf, documentAttributes: nil)
        XCTAssertEqual(attributed?.string, "Welcome to the show", "RTF survives the file round-trip")
        XCTAssertNil(DurationCache.shared.effectiveDuration(of: decoded.cues[0], in: decoded, showFolder: nil))
    }

    func testTransparentBackgroundIsNil() throws {
        let body = TextBody(rtf: makeRTF("x"))
        XCTAssertNil(body.backgroundColor, "default background is transparent")
        let data = try JSONEncoder().encode(body)
        let decoded = try JSONDecoder().decode(TextBody.self, from: data)
        XCTAssertNil(decoded.backgroundColor)
    }

    func testTextRenderUsesTheReferenceCanvas() {
        var body = TextBody(rtf: makeRTF("Hello"))
        body.backgroundColor = RGBAColor(red: 1, green: 0, blue: 0)
        let image = TextCuePlayer.render(body: body)
        XCTAssertNotNil(image)
        // Fixed 1920×1080 authoring canvas, 2x supersampled.
        XCTAssertEqual(image?.width, 3840)
        XCTAssertEqual(image?.height, 2160)
    }

    func testTextBoxRoundTripsAndDefaultsToLegacyLayout() throws {
        var body = TextBody(rtf: makeRTF("x"))
        body.box = StageRect(x: 0.1, y: 0.2, width: 0.5, height: 0.3)
        let decoded = try JSONDecoder().decode(TextBody.self, from: JSONEncoder().encode(body))
        XCTAssertEqual(decoded.box.width, 0.5)
        // Older files without the key land on the pre-box layout.
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as! [String: Any]
        json.removeValue(forKey: "box")
        let old = try JSONDecoder().decode(TextBody.self, from: try JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(old.box, .textDefault)
    }

    func testTextPlayerArmsStartsAndStopsOnPreviewTarget() async throws {
        let target = OutputTarget.preview(id: UUID(), title: "Text Test")
        let body = TextBody(rtf: makeRTF("Showtime"), fadeInDuration: 0.05, layer: 7)
        let player = try await TextCuePlayer.arm(body: body, targets: [target])
        XCTAssertNil(player.duration, "text holds until stopped")
        let host = OutputWindowManager.shared.window(for: target)?.contentView?.layer
        XCTAssertEqual(host?.sublayers?.first?.zPosition, 7)
        player.start()
        var updated = body
        updated.plainPreview = "Changed"
        updated.rtf = makeRTF("Changed")
        player.applyText(updated)   // live edit must not crash and keeps contents
        XCTAssertNotNil(host?.sublayers?.first?.contents)
        player.stop()
        XCTAssertNil(OutputWindowManager.shared.window(for: target), "lease released")
    }

    func testStillPlayerAppliesRenderLayerToZPosition() async throws {
        let png = FileManager.default.temporaryDirectory.appendingPathComponent("sw-layer-\(UUID().uuidString).png")
        let image = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill(); return true
        }
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try rep.representation(using: .png, properties: [:])!.write(to: png)
        defer { try? FileManager.default.removeItem(at: png) }

        let target = OutputTarget.preview(id: UUID(), title: "Layer Test")
        let back = try await StillCuePlayer.arm(
            body: ImageBody(media: MediaReference(absolutePath: png.path), layer: 2),
            imageURL: png, targets: [target]
        )
        let front = try await StillCuePlayer.arm(
            body: ImageBody(media: MediaReference(absolutePath: png.path), layer: 8),
            imageURL: png, targets: [target]
        )
        let host = OutputWindowManager.shared.window(for: target)?.contentView?.layer
        let zs = (host?.sublayers ?? []).map(\.zPosition).sorted()
        XCTAssertEqual(zs, [2, 8], "zPosition mirrors the cue layer")

        // Live change pulls the back layer to the very front.
        back.applyRenderLayer(10)
        let updated = (host?.sublayers ?? []).map(\.zPosition).sorted()
        XCTAssertEqual(updated, [8, 10])

        back.stop()
        front.stop()
        XCTAssertNil(OutputWindowManager.shared.window(for: target))
    }
}
