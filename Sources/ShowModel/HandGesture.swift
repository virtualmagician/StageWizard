import Foundation

/// One hand shape the camera's gesture-GO pipeline can recognize (D15).
/// Pure, Codable model type — persisted as `CameraEffects.goGesture`. The
/// actual per-frame Vision classification lives in VideoEngineKit's
/// `GestureClassifier`; this file only owns the vocabulary and its display
/// metadata (label, SF Symbol) so the model, the inspector picker, and the
/// stage display's gesture pane all share one source of truth.
public enum HandGesture: String, Codable, Hashable, CaseIterable, Sendable {
    case openPalm, fist, thumbsUp, handsTogether

    public var label: String {
        switch self {
        case .openPalm: return "Open palm"
        case .fist: return "Closed fist"
        case .thumbsUp: return "Thumbs up"
        case .handsTogether: return "Hands together"
        }
    }

    /// SF Symbol shown on the inspector picker and the stage display's
    /// gesture pane. There is no dedicated "fist" glyph in the system
    /// symbol catalog, so `.fist` uses a plain filled circle rather than a
    /// misleadingly-signed alternative (e.g. a "slash" glyph, which reads
    /// as "blocked/muted" everywhere else in macOS).
    public var symbolName: String {
        switch self {
        case .openPalm: return "hand.raised.fill"
        case .fist: return "circle.fill"
        case .thumbsUp: return "hand.thumbsup.fill"
        case .handsTogether: return "hands.clap.fill"
        }
    }
}
