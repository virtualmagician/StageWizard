import XCTest
import QuartzCore
@testable import StageWizard

@MainActor
final class V4Tests: XCTestCase {

    // MARK: - Geometry model

    func testGeometryRoundTripAndLegacyDefault() throws {
        var show = ShowFile()
        show.cues = [Cue(number: "1", body: .video(VideoBody(
            media: MediaReference(absolutePath: "/x.mov"),
            geometry: VideoGeometry(mode: .custom, x: 0.25, y: -0.1, scaleX: 0.5, scaleY: 0.5)
        )))]
        let decoded = try ShowFile.load(from: show.encoded())
        guard case .video(let body) = decoded.cues[0].body else { return XCTFail() }
        XCTAssertEqual(body.geometry.mode, .custom)
        XCTAssertEqual(body.geometry.x, 0.25)
        XCTAssertEqual(body.geometry.scaleY, 0.5)

        // Pre-v4 video JSON without "geometry" decodes to fillStage.
        let legacy = """
        {"type": "video",
         "media": {"absolutePath": "/x.mov"},
         "startTime": 0, "playCount": 1, "infiniteLoop": false, "volumeDB": 0,
         "fillMode": "fit", "endBehavior": "stopAndUnload",
         "fadeInDuration": 0, "fadeOutDuration": 0}
        """
        let legacyBody = try JSONDecoder().decode(CueBody.self, from: Data(legacy.utf8))
        guard case .video(let old) = legacyBody else { return XCTFail() }
        XCTAssertEqual(old.geometry, .fillStage)

        let legacyCamera = """
        {"type": "camera", "fillMode": "fit", "fadeInDuration": 0, "fadeOutDuration": 0}
        """
        let cameraBody = try JSONDecoder().decode(CueBody.self, from: Data(legacyCamera.utf8))
        guard case .camera(let oldCamera) = cameraBody else { return XCTFail() }
        XCTAssertEqual(oldCamera.geometry, .fillStage)
    }

    // MARK: - Transform math

    func testTransformIsIdentityInFillStage() {
        let transform = VideoGeometry.fillStage.transform(stageSize: CGSize(width: 1920, height: 1080))
        XCTAssertTrue(CATransform3DIsIdentity(transform))
    }

    func testCustomTransformTranslatesInStageUnitsAndScales() {
        let geometry = VideoGeometry(mode: .custom, x: 0.25, y: -0.5, scaleX: 0.5, scaleY: 2)
        let t = geometry.transform(stageSize: CGSize(width: 1000, height: 800))
        // Column-major CATransform3D: m41/m42 are the translation.
        XCTAssertEqual(t.m41, 250, accuracy: 0.001, "x = 25% of 1000")
        XCTAssertEqual(t.m42, -400, accuracy: 0.001, "y = -50% of 800")
        XCTAssertEqual(t.m11, 0.5, accuracy: 0.001, "scaleX")
        XCTAssertEqual(t.m22, 2.0, accuracy: 0.001, "scaleY")
    }

    func testCustomGravityIsAlwaysAspectFit() {
        let custom = VideoGeometry(mode: .custom)
        XCTAssertEqual(custom.gravity(fillMode: .stretch), .resizeAspect,
                       "custom mode transforms the aspect-fit image, regardless of fill mode")
        let fill = VideoGeometry.fillStage
        XCTAssertEqual(fill.gravity(fillMode: .stretch), .resize)
        XCTAssertEqual(fill.gravity(fillMode: .fill), .resizeAspectFill)
    }

    // MARK: - Live apply on a preview target

    func testApplyGeometryUpdatesLiveLayers() async throws {
        let mediaDir = IntegrationTests.mediaDir
        let url = mediaDir.appendingPathComponent("ident-5s.mov")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "TestMedia missing")

        let target = OutputTarget.preview(id: UUID(), title: "Geometry Test")
        let body = VideoBody(
            media: MediaReference(absolutePath: url.path),
            startTime: 0, endTime: 2, volumeDB: -50,
            geometry: VideoGeometry(mode: .custom, x: 0.1, y: 0.1, scaleX: 0.5, scaleY: 0.5)
        )
        let player = try await VideoCuePlayer.arm(body: body, fileURL: url, targets: [target])
        let layer = player.playerLayers.first!
        XCTAssertEqual(layer.videoGravity, .resizeAspect)
        XCTAssertEqual(layer.transform.m11, 0.5, accuracy: 0.001, "custom scale applied at arm")

        var geometry = body.geometry
        geometry.x = 0.5
        geometry.scaleX = 1
        geometry.scaleY = 1
        player.applyGeometry(geometry, fillMode: .fit)
        XCTAssertEqual(layer.transform.m11, 1.0, accuracy: 0.001, "live update rescaled")
        let stageWidth = layer.superlayer!.bounds.width
        XCTAssertEqual(layer.transform.m41, stageWidth * 0.5, accuracy: 0.5, "live update moved in stage units")

        player.stop()
    }
}
