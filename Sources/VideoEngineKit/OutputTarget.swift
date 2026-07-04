import CoreGraphics
import Foundation

/// Where a video/camera cue renders: a real display's fullscreen output
/// window, or a floating rehearsal preview window standing in for an output
/// group. Identity for leasing ignores the preview title (it's only used
/// when the window is first created).
public enum OutputTarget: Sendable {
    case display(CGDirectDisplayID)
    case preview(id: UUID, title: String)

    /// Stable id for the app's "main display" rehearsal preview.
    public static let mainPreviewID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
}

extension OutputTarget: Hashable {
    public static func == (lhs: OutputTarget, rhs: OutputTarget) -> Bool {
        switch (lhs, rhs) {
        case (.display(let a), .display(let b)): return a == b
        case (.preview(let a, _), .preview(let b, _)): return a == b
        default: return false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .display(let id):
            hasher.combine(0)
            hasher.combine(id)
        case .preview(let id, _):
            hasher.combine(1)
            hasher.combine(id)
        }
    }
}

extension OutputTarget {
    /// The real display this target occupies, if any (previews return nil —
    /// they're immune to display hot-plug).
    public var displayID: CGDirectDisplayID? {
        if case .display(let id) = self { return id }
        return nil
    }
}
