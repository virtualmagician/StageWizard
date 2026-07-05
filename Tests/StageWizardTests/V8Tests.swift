import XCTest
@testable import StageWizard

@MainActor
final class V8Tests: XCTestCase {

    // MARK: - Workspace modes: only Show locks editing

    func testRehearsalModeKeepsEditingEnabled() {
        let app = AppModel()
        app.setMode(.rehearsal)
        XCTAssertEqual(app.mode, .rehearsal)
        XCTAssertFalse(app.isShowMode, "Rehearsal must stay editable")
        app.setMode(.show)
        XCTAssertTrue(app.isShowMode, "Show locks the workspace")
        app.setMode(.edit)
        XCTAssertFalse(app.isShowMode)
    }

    // MARK: - Virtual webcam plumbing

    func testOutputGroupVirtualCameraDefaultsOffForOlderFiles() throws {
        var show = ShowFile()
        show.settings.outputGroups = [OutputGroup(name: "External")]
        var json = try JSONSerialization.jsonObject(with: show.encoded()) as! [String: Any]
        var settings = json["settings"] as! [String: Any]
        var groups = settings["outputGroups"] as! [[String: Any]]
        groups[0].removeValue(forKey: "virtualCamera")
        settings["outputGroups"] = groups
        json["settings"] = settings
        let decoded = try ShowFile.load(from: try JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(decoded.settings.outputGroups[0].virtualCamera)
    }

    func testOutputGroupVirtualCameraRoundTrip() throws {
        var show = ShowFile()
        show.settings.outputGroups = [OutputGroup(name: "Stream", virtualCamera: true)]
        let decoded = try ShowFile.load(from: show.encoded())
        XCTAssertTrue(decoded.settings.outputGroups[0].virtualCamera)
    }

    // MARK: - Virtual-webcam feed state in the show file

    func testVirtualCameraFeedRoundTripsAndDefaultsOff() throws {
        var show = ShowFile()
        show.settings.virtualCameraFeed = true
        let decoded = try ShowFile.load(from: show.encoded())
        XCTAssertTrue(decoded.settings.virtualCameraFeed)

        // Older files without the key land on off.
        var json = try JSONSerialization.jsonObject(with: show.encoded()) as! [String: Any]
        var settings = json["settings"] as! [String: Any]
        settings.removeValue(forKey: "virtualCameraFeed")
        json["settings"] = settings
        let old = try ShowFile.load(from: try JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(old.settings.virtualCameraFeed)
    }

    // MARK: - Dust presets + scale

    func testDustScaleAndPresetRoundTripWithClamping() throws {
        let effects = CameraEffects(magicDust: true, dustPreset: "MagicFire", dustScale: 3.5)
        let decoded = try JSONDecoder().decode(CameraEffects.self, from: JSONEncoder().encode(effects))
        XCTAssertEqual(decoded.dustPreset, "MagicFire")
        XCTAssertEqual(decoded.dustScale, 3.5)

        XCTAssertEqual(CameraEffects(dustScale: 99).dustScale, 10, "clamped high")
        XCTAssertEqual(CameraEffects(dustScale: 0.01).dustScale, 0.5, "clamped low")
        // Older files without the new keys land on defaults.
        let old = try JSONDecoder().decode(CameraEffects.self, from: Data("{}".utf8))
        XCTAssertNil(old.dustPreset)
        XCTAssertEqual(old.dustScale, 1)
    }

    func testEmitterSizeScaleMultipliesParticleSize() throws {
        let url = try XCTUnwrap(Bundle(for: V8Tests.self).url(forResource: "test1", withExtension: "pex"))
        let config = try XCTUnwrap(PEXEmitterConfig.parse(url: url))
        let normal = try XCTUnwrap(config.makeEmitterLayer(sizeScale: 1).emitterCells?.first)
        let big = try XCTUnwrap(config.makeEmitterLayer(sizeScale: 4).emitterCells?.first)
        XCTAssertEqual(big.scale, normal.scale * 4, accuracy: 0.0001)
        XCTAssertEqual(big.scaleRange, normal.scaleRange * 4, accuracy: 0.0001)
        XCTAssertEqual(big.birthRate, normal.birthRate, "scale changes size, not density")
    }

    func testVirtualCameraMonitorTargetIsStable() {
        // The monitor's preview identity is baked into show routing — it
        // must never change between versions.
        XCTAssertEqual(
            VirtualCameraManager.monitorPreviewID.uuidString,
            "22222222-2222-2222-2222-222222222222"
        )
        XCTAssertNil(VirtualCameraManager.monitorTarget.displayID)
    }
}
