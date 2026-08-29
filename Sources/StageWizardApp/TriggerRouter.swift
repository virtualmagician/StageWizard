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

    /// Fire the cue whose show-file `number` matches, resolving group
    /// headers the same way a per-cue hotkey would. An unknown number is a
    /// silent no-op — a remote surface has no operator-facing warning UI.
    func route(cueNumber: String) {
        guard let appModel,
              let cue = appModel.document.show.cues.first(where: { $0.number == cueNumber }) else { return }
        appModel.transport.fire(cueID: cue.id)
    }
}
