import AppKit

/// One local keyDown monitor dispatches every plain-key and assigned shortcut.
/// Menu items carry NO key equivalents for transport actions — this monitor is
/// the single source of truth, so Space/Esc can be suppressed during text entry.
@MainActor
public final class ShortcutManager {
    /// Esc — hardwired to panic, never reassignable — panic must always work.
    public static let panicKeyCode: UInt16 = 53

    public var onAction: (@MainActor (ShortcutAction) -> Void)?
    public var onCueHotkey: (@MainActor (UUID) -> Void)?
    public var onPanic: (@MainActor () -> Void)?

    /// Live lookup tables — provided by the app so edits apply instantly.
    public var bindingsProvider: @MainActor () -> [ShortcutAction: KeyBinding] = { [:] }
    public var hotkeysProvider: @MainActor () -> [KeyBinding: UUID] = { [:] }

    /// When a recorder view is capturing, it intercepts the next keystroke.
    /// Return true to consume. Esc always cancels capture instead of panicking.
    public var captureNext: (@MainActor (KeyBinding) -> Bool)?

    private var monitor: Any?

    /// Tests inject a fixed pass-through verdict; synthesized NSEvents carry
    /// no window so the real evaluator would always pass them through.
    var passthroughOverride: ((NSEvent) -> Bool)?

    public init() {}

    public func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    public func uninstall() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    /// Returns nil to consume the event, or the event to pass it on.
    /// Internal (not private) so the guard logic is unit-testable.
    func handle(_ event: NSEvent) -> NSEvent? {
        // Strip .function/.numericPad: arrow and function keys carry them
        // implicitly, so bindings recorded as "plain ↓" would never match.
        let binding = KeyBinding(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .subtracting([.function, .numericPad])
                .rawValue
        )

        // Recorder capture wins over everything (Esc cancels capture).
        if let captureNext {
            if event.keyCode == Self.panicKeyCode {
                self.captureNext = nil
                return nil
            }
            if captureNext(binding) {
                self.captureNext = nil
                return nil
            }
            return nil
        }

        // Pass-through guards: never fire cues while the operator is typing,
        // a sheet/modal is up, or a key is auto-repeating.
        if shouldPassThrough(event) { return event }

        // Esc = panic, hardcoded, plain Esc only.
        if event.keyCode == Self.panicKeyCode && binding.modifiers == 0 {
            onPanic?()
            return nil
        }

        if let (action, _) = bindingsProvider().first(where: { $0.value == binding }) {
            if !event.isARepeat { onAction?(action) }
            return nil   // consume repeats too, or Space repeat beeps/types
        }

        if let cueID = hotkeysProvider()[binding] {
            if !event.isARepeat { onCueHotkey?(cueID) }
            return nil
        }

        return event
    }

    private func shouldPassThrough(_ event: NSEvent) -> Bool {
        if let passthroughOverride { return passthroughOverride(event) }
        guard let window = event.window else { return true }
        // Text editing: field editors are NSTextView; NSText covers legacy.
        if let responder = window.firstResponder {
            if responder is NSTextView || responder is NSText { return true }
        }
        // Sheets and modal sessions get their native key handling — both when
        // the parent has a sheet attached AND when the event targets the sheet
        // itself (Esc must close the sheet, not fire panic).
        if window.attachedSheet != nil { return true }
        if window.isSheet { return true }
        if NSApp.modalWindow != nil { return true }
        // Only act on the key window (not popovers/panels).
        if !window.isKeyWindow { return true }
        return false
    }
}
