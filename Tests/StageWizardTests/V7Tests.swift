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
