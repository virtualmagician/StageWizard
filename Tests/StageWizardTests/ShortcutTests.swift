import XCTest
import AppKit
@testable import StageWizard

@MainActor
final class ShortcutTests: XCTestCase {
    private var manager: ShortcutManager!
    private var actions: [ShortcutAction] = []
    private var hotkeys: [UUID] = []
    private var panics = 0
    private var exitShowModes = 0

    private let cueID = UUID()

    override func setUp() async throws {
        manager = ShortcutManager()
        actions = []
        hotkeys = []
        panics = 0
        exitShowModes = 0
        manager.passthroughOverride = { _ in false }   // simulate: key window, no text focus
        manager.bindingsProvider = {
            [.go: KeyBinding(keyCode: 49), .stopAll: KeyBinding(keyCode: 46, modifiers: NSEvent.ModifierFlags.command.rawValue)]
        }
        manager.hotkeysProvider = { [KeyBinding(keyCode: 18): self.cueID] }   // "1"
        manager.onAction = { self.actions.append($0) }
        manager.onCueHotkey = { self.hotkeys.append($0) }
        manager.onPanic = { self.panics += 1 }
        manager.onExitShowMode = { self.exitShowModes += 1 }
    }

    private func keyEvent(_ keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [], isRepeat: Bool = false) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, characters: " ", charactersIgnoringModifiers: " ",
            isARepeat: isRepeat, keyCode: keyCode
        )!
    }

    func testSpaceFiresGoAndIsConsumed() {
        let result = manager.handle(keyEvent(49))
        XCTAssertNil(result, "bound key must be consumed")
        XCTAssertEqual(actions, [.go])
    }

    func testModifierBindingDispatches() {
        let result = manager.handle(keyEvent(46, modifiers: .command))
        XCTAssertNil(result)
        XCTAssertEqual(actions, [.stopAll])
    }

    func testEscFiresPanicAlways() {
        let result = manager.handle(keyEvent(53))
        XCTAssertNil(result)
        XCTAssertEqual(panics, 1)
        XCTAssertTrue(actions.isEmpty)
    }

    // MARK: - D17: ⌘Esc hardwired exit-Show-mode (never reassignable, never a ShortcutAction)

    func testCommandEscFiresExitShowModeNotPanic() {
        let result = manager.handle(keyEvent(53, modifiers: .command))
        XCTAssertNil(result, "⌘Esc must be consumed")
        XCTAssertEqual(exitShowModes, 1)
        XCTAssertEqual(panics, 0, "⌘Esc must not also panic")
        XCTAssertTrue(actions.isEmpty)
    }

    func testPlainEscStillPanicsAndNeverExitsShowMode() {
        let result = manager.handle(keyEvent(53))
        XCTAssertNil(result)
        XCTAssertEqual(panics, 1)
        XCTAssertEqual(exitShowModes, 0, "plain Esc must not exit Show mode")
    }

    func testCommandEscPassesThroughWhileTextEditing() {
        manager.passthroughOverride = { _ in true }   // simulate: text field focused
        let result = manager.handle(keyEvent(53, modifiers: .command))
        XCTAssertNotNil(result, "⌘Esc while typing must pass through, matching panic's own gating")
        XCTAssertEqual(exitShowModes, 0)
        XCTAssertEqual(panics, 0)
    }

    // MARK: - D18 (FIX 2): the reduced hardwired guard — nil/non-key window
    // must NOT suppress panic/⌘Esc; text editing and sheets/modals still do.

    /// The exact operator-trap regression: a synthesized ⌘Esc event with no
    /// window (as it arrives when nothing can claim "key window" status —
    /// the state the live incident left the operator in) must still fire
    /// exit-Show-mode. Resets `passthroughOverride` to nil so the REAL
    /// guard runs instead of the test-simulated one `setUp` installs.
    func testNilWindowCommandEscFiresExitShowModeThroughRealGuard() {
        manager.passthroughOverride = nil
        let result = manager.handle(keyEvent(53, modifiers: .command))
        XCTAssertNil(result, "⌘Esc must be consumed even with no window")
        XCTAssertEqual(exitShowModes, 1)
        XCTAssertEqual(panics, 0)
    }

    /// Same regression, plain Esc / panic.
    func testNilWindowPlainEscFiresPanicThroughRealGuard() {
        manager.passthroughOverride = nil
        let result = manager.handle(keyEvent(53))
        XCTAssertNil(result, "Esc must be consumed even with no window")
        XCTAssertEqual(panics, 1)
        XCTAssertEqual(exitShowModes, 0)
    }

    /// A non-hardwired binding must keep requiring a window — FIX 2 only
    /// changes the guard for panic/⌘Esc, `shouldPassThrough` (used for every
    /// ordinary binding/hotkey) is untouched.
    func testNilWindowNonHardwiredActionStillPassesThroughUnchanged() {
        manager.passthroughOverride = nil
        let result = manager.handle(keyEvent(49))   // Space -> bound to .go
        XCTAssertNotNil(result, "non-hardwired actions still require a window (unchanged)")
        XCTAssertTrue(actions.isEmpty)
    }

    /// Text editing must still suppress plain Esc (panic) — mirrors the
    /// existing ⌘Esc coverage above so both hardwired keys are pinned.
    func testPlainEscPassesThroughWhileTextEditing() {
        manager.passthroughOverride = { _ in true }   // simulate: text field focused
        let result = manager.handle(keyEvent(53))
        XCTAssertNotNil(result, "Esc while typing must pass through, not panic")
        XCTAssertEqual(panics, 0)
        XCTAssertEqual(exitShowModes, 0)
    }

    /// A sheet/modal session must suppress both hardwired keys too — Esc
    /// closes the sheet, ⌘Esc doesn't reach through it either. Simulated via
    /// the same override seam as text editing (the override is a single
    /// pass-through verdict, same as `shouldPassThrough` already uses it for
    /// the equivalent real AppKit state).
    func testCommandEscPassesThroughWhenSheetOrModalIsUp() {
        manager.passthroughOverride = { _ in true }   // simulate: sheet/modal attached
        let result = manager.handle(keyEvent(53, modifiers: .command))
        XCTAssertNotNil(result, "⌘Esc must not reach through a sheet/modal")
        XCTAssertEqual(exitShowModes, 0)
        XCTAssertEqual(panics, 0)
    }

    func testPlainEscPassesThroughWhenSheetOrModalIsUp() {
        manager.passthroughOverride = { _ in true }   // simulate: sheet/modal attached
        let result = manager.handle(keyEvent(53))
        XCTAssertNotNil(result, "Esc must close the sheet, not panic")
        XCTAssertEqual(panics, 0)
        XCTAssertEqual(exitShowModes, 0)
    }

    func testRepeatIsConsumedButDoesNotRefire() {
        _ = manager.handle(keyEvent(49))
        let result = manager.handle(keyEvent(49, isRepeat: true))
        XCTAssertNil(result, "repeat of a bound key is swallowed")
        XCTAssertEqual(actions, [.go], "…but must not fire GO again")
    }

    func testUnboundKeyPassesThrough() {
        let event = keyEvent(40)   // "K", unbound
        XCTAssertNotNil(manager.handle(event), "unbound keys must reach the responder chain")
        XCTAssertTrue(actions.isEmpty)
    }

    func testCueHotkeyFires() {
        let result = manager.handle(keyEvent(18))
        XCTAssertNil(result)
        XCTAssertEqual(hotkeys, [cueID])
    }

    func testTextEditingPassThroughBlocksGo() {
        manager.passthroughOverride = { _ in true }   // simulate: text field focused
        let result = manager.handle(keyEvent(49))
        XCTAssertNotNil(result, "Space while typing must type, not fire GO")
        XCTAssertTrue(actions.isEmpty)
    }

    func testRecorderCaptureInterceptsAndEscCancels() {
        var captured: [KeyBinding] = []
        manager.captureNext = { binding in
            captured.append(binding)
            return true
        }
        _ = manager.handle(keyEvent(3, modifiers: [.command, .shift]))   // ⌘⇧F
        XCTAssertEqual(captured, [KeyBinding(keyCode: 3, modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue)])
        XCTAssertNil(manager.captureNext, "capture is one-shot")
        XCTAssertTrue(actions.isEmpty, "captured keystroke must not dispatch")

        manager.captureNext = { _ in XCTFail("Esc must cancel, not capture"); return true }
        _ = manager.handle(keyEvent(53))
        XCTAssertNil(manager.captureNext, "Esc cancels recording")
        XCTAssertEqual(panics, 0, "Esc during recording must not panic")
    }

    func testBindingDisplayNames() {
        XCTAssertEqual(KeyBinding(keyCode: 49).displayName, "Space")
        XCTAssertEqual(KeyBinding(keyCode: 3, modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue).displayName, "⇧⌘F")
        XCTAssertEqual(KeyBinding(keyCode: 96).displayName, "F5")
    }
}
