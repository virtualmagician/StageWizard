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
