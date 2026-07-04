import Foundation

/// A recorded keyboard shortcut. Uses the physical key code (layout-independent,
/// like pro cue software) plus device-independent modifier flags.
public struct KeyBinding: Codable, Hashable, Sendable {
    public var keyCode: UInt16
    /// NSEvent.ModifierFlags.deviceIndependentFlagsMask intersection, raw value.
    public var modifiers: UInt

    public init(keyCode: UInt16, modifiers: UInt = 0) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

/// Transport-level actions that can carry an assignable shortcut.
/// Panic is intentionally absent: Esc is hardcoded for safety.
/// CodingKeyRepresentable so [ShortcutAction: KeyBinding] persists as a JSON
/// object keyed by action name, not a flat array.
public enum ShortcutAction: String, Codable, CaseIterable, Sendable, CodingKeyRepresentable {
    case go
    case stopAll
    case togglePlayback
    /// Legacy (pre-v2) — kept so old show files still decode; dispatches as
    /// togglePlayback and is hidden from the recorder UI.
    case pauseAll
    /// Legacy (pre-v2) — see pauseAll.
    case resumeAll
    case previousCue
    case nextCue
    case load

    public var displayName: String {
        switch self {
        case .go: return "GO"
        case .stopAll: return "Stop All"
        case .togglePlayback: return "Pause / Resume All"
        case .pauseAll: return "Pause All (legacy)"
        case .resumeAll: return "Resume All (legacy)"
        case .previousCue: return "Previous Cue"
        case .nextCue: return "Next Cue"
        case .load: return "Load Selected Cue"
        }
    }

    /// Actions shown in the shortcuts editor (legacy cases hidden).
    public static let assignable: [ShortcutAction] = [
        .go, .togglePlayback, .stopAll, .previousCue, .nextCue, .load,
    ]
}
