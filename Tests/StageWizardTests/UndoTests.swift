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

    func testSaveBreaksCoalescingSoPostSaveEditIsNeverLostToRedo() async throws {
        // Regression for: a save landing mid-coalesce-burst left
        // savePointDepth == undoStack.count, so an edit arriving right after
        // (still inside the 500ms coalesce window) folded into the entry
        // that now anchored the save point instead of appending — leaving
        // undo depth == savePointDepth despite the unsaved edit, which made
        // a later redo report isDirty == false with real changes on screen.
        let document = ShowDocumentController()
        let cue = addCue(document, number: "10")
        XCTAssertEqual(document.undoDepthForTesting, 1)

        // `markSaved()` is exactly what `write(to:)` calls on a successful
        // save — exercised directly so the test doesn't need NSSavePanel or
        // real disk I/O.
        document.markSaved()
        XCTAssertFalse(document.isDirty)
        let depthAtSave = document.undoDepthForTesting

        // An edit landing well inside the coalesce window, immediately after
        // the simulated save.
        document.updateCue(cue.id) { $0.preWait = 5 }

        XCTAssertGreaterThan(
            document.undoDepthForTesting, depthAtSave,
            "a post-save edit must append a fresh undo entry, never coalesce into the save point"
        )
        XCTAssertTrue(document.isDirty)
    }

    func testRevalidateClearsPlayheadWhenCueLeavesTheGOSequence() {
        let app = AppModel()
        let group = Cue(number: "1", body: .group(GroupBody(mode: .fireAll)))
        let cue = Cue(number: "2", body: .audio(AudioBody(media: MediaReference(absolutePath: "/fake/1.wav"))))
        app.document.mutate { $0.cues = [group, cue] }
        app.transport.setPlayhead(cue.id)
        XCTAssertEqual(app.transport.standingByCue?.id, cue.id)

        // An undone edit can keep the cue but move it inside a fire-all
        // group: it still EXISTS, yet is no longer a GO position — bare
        // existence checking would leave GO silently dead here.
        app.document.mutate { $0.cues[1].parentID = group.id }
        app.transport.revalidatePlayhead()
        XCTAssertEqual(app.transport.standingByCue?.id, group.id,
                       "playhead cleared, GO falls back to the first GO-able cue")
    }
}
