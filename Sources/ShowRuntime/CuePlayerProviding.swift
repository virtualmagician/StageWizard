import Foundation

public enum ArmError: LocalizedError {
    case mediaMissing(cueName: String)
    case displayMissing(cueName: String, displayName: String)
    case noOutputAssigned(cueName: String)
    case notAMediaCue

    public var errorDescription: String? {
        switch self {
        case .mediaMissing(let name):
            return "Media file for “\(name)” not found — relink it in the inspector."
        case .displayMissing(let name, let display):
            return "Display “\(display)” for “\(name)” is not connected."
        case .noOutputAssigned(let name):
            return "“\(name)” has no video output assigned — pick one in the Output tab (create groups in Settings → Video Outputs)."
        case .notAMediaCue:
            return "Cue has no playable media."
        }
    }
}

/// Bridges the cue engine to the audio/video engines. The runtime never
/// imports AVFoundation — it drives players only through MediaPlayback.
/// Implemented by the app layer once the engines exist; mocked in tests.
@MainActor
public protocol CuePlayerProviding: AnyObject {
    /// Load + seek + preroll a player for a media cue so `start()` is instant.
    func armPlayer(for cue: Cue, showFolder: URL?) async throws -> MediaPlayback
}
