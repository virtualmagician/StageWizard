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
}
