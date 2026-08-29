import XCTest
@testable import StageWizard

@MainActor
final class UndoTests: XCTestCase {

    private func addCue(_ document: ShowDocumentController, number: String) -> Cue {
        let cue = Cue(number: number, body: .stop(StopBody()))
        document.mutate { $0.cues.append(cue) }
        return cue
    }

    func testUndoRedoRoundTrip() async throws {
        let document = ShowDocumentController()
        XCTAssertFalse(document.canUndo)

        _ = addCue(document, number: "10")
        try await Task.sleep(for: .milliseconds(600))   // separate steps
        _ = addCue(document, number: "20")

        XCTAssertEqual(document.show.cues.count, 2)
        document.undo()
        XCTAssertEqual(document.show.cues.map(\.number), ["10"])
        document.undo()
        XCTAssertTrue(document.show.cues.isEmpty)
        XCTAssertFalse(document.canUndo)

        document.redo()
        XCTAssertEqual(document.show.cues.map(\.number), ["10"])
        document.redo()
        XCTAssertEqual(document.show.cues.map(\.number), ["10", "20"])
        XCTAssertFalse(document.canRedo)
    }

    func testBurstEditsCoalesceIntoOneStep() async throws {
        let document = ShowDocumentController()
        let cue = addCue(document, number: "10")
        try await Task.sleep(for: .milliseconds(600))

        // A drag: many rapid mutations well inside the coalesce window.
        for value in 1...10 {
            document.updateCue(cue.id) { $0.preWait = TimeInterval(value) }
        }
        XCTAssertEqual(document.cue(withID: cue.id)?.preWait, 10)

        document.undo()   // the whole burst reverts at once
        XCTAssertEqual(document.cue(withID: cue.id)?.preWait, 0)
        document.undo()   // then the add itself
        XCTAssertTrue(document.show.cues.isEmpty)
    }

    func testNewEditClearsRedo() async throws {
        let document = ShowDocumentController()
        _ = addCue(document, number: "10")
        document.undo()
        XCTAssertTrue(document.canRedo)
        _ = addCue(document, number: "99")
        XCTAssertFalse(document.canRedo, "a fresh edit invalidates the redo branch")
    }

    func testSelectionRestoresAndFiltersDeadIDs() async throws {
        let document = ShowDocumentController()
        let cue = addCue(document, number: "10")
        document.selection = [cue.id]
        try await Task.sleep(for: .milliseconds(600))

        document.mutate { $0.cues.removeAll() }
        document.selection = []
        document.undo()
        XCTAssertEqual(document.selection, [cue.id], "selection travels with the snapshot")
    }

    func testUndoToBottomClearsDirty() {
        let document = ShowDocumentController()
        XCTAssertFalse(document.isDirty)
        _ = addCue(document, number: "10")
        XCTAssertTrue(document.isDirty)
        document.undo()
        XCTAssertFalse(document.isDirty, "back at the save point (fresh document) = clean")
        document.redo()
        XCTAssertTrue(document.isDirty)
    }

    func testUndoRevalidatesPlayhead() {
        let document = ShowDocumentController()
        var fired = false
        document.onUndoRestore = { fired = true }
        _ = addCue(document, number: "10")
        document.undo()
        XCTAssertTrue(fired, "restore notifies so the transport can revalidate")
    }
}
