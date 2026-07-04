import XCTest
import AppKit
@testable import StageWizard

@MainActor
final class ShortcutTests: XCTestCase {
    private var manager: ShortcutManager!
    private var actions: [ShortcutAction] = []
    private var hotkeys: [UUID] = []
    private var panics = 0

    private let cueID = UUID()

    override func setUp() async throws {
        manager = ShortcutManager()
        actions = []
        hotkeys = []
        panics = 0
        manager.passthroughOverride = { _ in false }   // simulate: key window, no text focus
        manager.bindingsProvider = {
            [.go: KeyBinding(keyCode: 49), .stopAll: KeyBinding(keyCode: 46, modifiers: NSEvent.ModifierFlags.command.rawValue)]
        }
        manager.hotkeysProvider = { [KeyBinding(keyCode: 18): self.cueID] }   // "1"
        manager.onAction = { self.actions.append($0) }
        manager.onCueHotkey = { self.hotkeys.append($0) }
        manager.onPanic = { self.panics += 1 }
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
