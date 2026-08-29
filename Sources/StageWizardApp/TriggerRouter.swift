import Foundation

/// Single funnel every remote-control surface — MIDI today, OSC/web/gesture
/// later — routes through to reach the transport. Thin on purpose: it only
/// resolves WHAT to fire (a transport verb, or a cue by its show-file
/// number); the semantics (double-GO protection, panic guards, playhead
/// advance, …) live entirely in AppModel.perform / TransportController and
/// are never duplicated here.
///
/// Owned by AppModel; holds a weak back-reference set once AppModel finishes
/// its own composition (mirrors the rest of AppModel's wiring — see `wire()`
/// — rather than being handed `self` mid-init).
@MainActor
final class TriggerRouter {
    weak var appModel: AppModel?

    /// Perform a transport-level action (GO, Stop All, …) exactly as if a
    /// bound key had fired it.
    func route(_ action: ShortcutAction) {
        appModel?.perform(action)
    }

    /// Panic, exactly as if Esc had fired it. Panic is hardwired to Esc (see
    /// ShortcutManager.panicKeyCode) rather than being a ShortcutAction, so
    /// it needs its own entry point here — this calls the SAME code path as
    /// the keyboard handler (`AppModel.wire()`'s `shortcuts.onPanic`), never
    /// the keyboard path itself.
    func routePanic() {
        appModel?.transport.panic()
    }

    /// Fire the cue whose show-file `number` matches, resolving group
    /// headers the same way a per-cue hotkey would. An unknown number is a
    /// silent no-op — a remote surface has no operator-facing warning UI.
    func route(cueNumber: String) {
        guard let appModel,
              let cue = appModel.document.show.cues.first(where: { $0.number == cueNumber }) else { return }
        appModel.transport.fire(cueID: cue.id)
    }

    /// D21: stand the cue whose show-file `number` matches on the playhead,
    /// WITHOUT firing it (StageWand's cue-select control). Same number
    /// lookup as `route(cueNumber:)`, minus the `resolveGOTarget` step —
    /// `TransportController.setPlayhead` already resolves an
    /// enter-and-play-first group header to its first child AND verifies
    /// GO-sequence membership on its own, so an unknown number, or a cue
    /// that exists but isn't GO-able (e.g. a fire-all/timeline group child),
    /// is a silent no-op that leaves the playhead exactly where it was.
    func route(selectCueNumber: String) {
        guard let appModel,
              let cue = appModel.document.show.cues.first(where: { $0.number == selectCueNumber }) else { return }
        appModel.transport.setPlayhead(cue.id)
    }
}
