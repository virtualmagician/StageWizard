import AppKit

/// One local keyDown monitor dispatches every plain-key and assigned shortcut.
/// Menu items carry NO key equivalents for transport actions — this monitor is
/// the single source of truth, so Space/Esc can be suppressed during text entry.
/// D18: ⌘Esc (exit Show mode) is the deliberate exception — `ShowCommands`
/// ALSO carries a menu item with this key equivalent, as a second, independent
/// path out of a locked Show-mode workspace that fires even when this monitor
/// can't (see that file's own comment for why the two paths never double-fire).
@MainActor
public final class ShortcutManager {
    /// Esc — hardwired to panic, never reassignable — panic must always work.
    public static let panicKeyCode: UInt16 = 53
    /// ⌘Esc — hardwired to exit Show mode, never reassignable, never a
    /// `ShortcutAction` — the one guaranteed way out when a fullscreen stage
    /// display is covering the operator's own screen (D17).
    public static let exitShowModeModifiers = NSEvent.ModifierFlags.command

    public var onAction: (@MainActor (ShortcutAction) -> Void)?
    public var onCueHotkey: (@MainActor (UUID) -> Void)?
    public var onPanic: (@MainActor () -> Void)?
    /// ⌘Esc — see `exitShowModeModifiers`.
    public var onExitShowMode: (@MainActor () -> Void)?

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

        // D18 (FIX 2): hardwired keys — Esc = panic, plain Esc only; ⌘Esc =
        // exit Show mode, same physical key-53, split by modifier so
        // there's no ambiguity between them — are checked BEFORE the full
        // pass-through guard, behind their OWN reduced guard
        // (`shouldPassThroughHardwired`). This is the operator-trap fix: the
        // full guard below treats any windowless or non-key-window event as
        // "pass through", which silently swallowed panic and ⌘Esc exactly
        // when the operator most needed them (no key window at all — e.g.
        // the stage display's own non-activating window covering the
        // operator's screen, or focus having slipped to another app). The
        // reduced guard only suppresses for active text editing or a
        // sheet/modal session — never for a merely absent/non-key window.
        if event.keyCode == Self.panicKeyCode, !shouldPassThroughHardwired(event) {
            if binding.modifiers == 0 {
                onPanic?()
                return nil
            }
            if binding.modifiers == Self.exitShowModeModifiers.rawValue {
                onExitShowMode?()
                return nil
            }
        }

        // Pass-through guard for everything else (unchanged): never fire
        // cues while the operator is typing, a sheet/modal is up, a key is
        // auto-repeating, or the event isn't targeting the app's own key
        // window.
        if shouldPassThrough(event) { return event }

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

    /// D18 (FIX 2): the reduced pass-through guard for hardwired keys
    /// (panic, ⌘Esc exit-Show) — deliberately NOT the same guard as
    /// ordinary bindings/hotkeys. A nil `event.window` or a non-key window
    /// must NOT suppress a hardwired key: that's exactly the state a
    /// trapped operator is in (no window able to receive the keystroke as
    /// its "key" window), and it's precisely when panic/exit-Show must
    /// still fire. Only two conditions still suppress: the operator is
    /// actively typing (checking that needs a window, so this is a no-op
    /// without one), or a sheet/modal session is up (Esc must close the
    /// sheet, not panic/exit-Show underneath it). `passthroughOverride`
    /// overrides this guard too, exactly like `shouldPassThrough`, so tests
    /// keep one simple seam for both.
    private func shouldPassThroughHardwired(_ event: NSEvent) -> Bool {
        if let passthroughOverride { return passthroughOverride(event) }
        if let window = event.window {
            if let responder = window.firstResponder {
                if responder is NSTextView || responder is NSText { return true }
            }
            if window.attachedSheet != nil { return true }
            if window.isSheet { return true }
        }
        if NSApp.modalWindow != nil { return true }
        return false
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
