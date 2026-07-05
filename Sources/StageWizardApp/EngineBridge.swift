import AppKit
import CoreGraphics

/// Bridges the cue engine to the real audio/video engines. This is the only
/// place the runtime's abstract arm request meets AVFoundation-backed players.
@MainActor
final class EnginePlayerProvider: CuePlayerProviding {
    /// Surfaced to the operator banner (routing fallbacks, display problems).
    var onWarning: (@MainActor (String) -> Void)?
    /// Show settings lookup (output groups live there). Wired by AppModel.
    var settings: @MainActor () -> ShowSettings = { ShowSettings() }
    /// True while the workspace is in Rehearsal mode — video/camera cues then
    /// render into floating preview windows instead of the real displays.
    var rehearsalActive: @MainActor () -> Bool = { false }

    func armPlayer(for cue: Cue, showFolder: URL?) async throws -> MediaPlayback {
        switch cue.body {
        case .audio(let body):
            guard let url = body.media.resolve(showFolder: showFolder) else {
                throw ArmError.mediaMissing(cueName: cue.displayName)
            }
            let player = try await AudioCuePlayer.arm(body: body, fileURL: url)
            if let warning = player.routingWarning {
                onWarning?("Cue \(cue.number): \(warning.description)")
            }
            return player

        case .video(var body):
            guard let url = body.media.resolve(showFolder: showFolder) else {
                throw ArmError.mediaMissing(cueName: cue.displayName)
            }
            // A saved-but-disconnected embedded-audio device would play into
            // the void — fall back to the system default, loudly.
            if let uid = body.audioDeviceUID,
               !AudioDeviceManager.shared.outputDevices.contains(where: { $0.uid == uid }) {
                onWarning?("Cue \(cue.number): audio device “\(body.audioDeviceName ?? uid)” not connected — using system default.")
                body.audioDeviceUID = nil
            }
            let targets = try resolveTargets(
                groupID: body.outputGroupID, legacy: body.display, cueNumber: cue.number
            )
            return try await VideoCuePlayer.arm(body: body, fileURL: url, targets: targets)

        case .camera(var body):
            // Missing camera falls back to any available one, loudly.
            if let uid = body.cameraUID, CameraDeviceManager.shared.device(forUID: uid) == nil {
                onWarning?("Cue \(cue.number): camera “\(body.cameraName ?? uid)” not connected — using the default camera.")
                body.cameraUID = nil
                body.cameraName = nil
            }
            let targets = try resolveTargets(
                groupID: body.outputGroupID, legacy: body.display, cueNumber: cue.number
            )
            return try await CameraCuePlayer.arm(body: body, targets: targets)

        case .slide(let body):
            guard let url = body.media.resolve(showFolder: showFolder) else {
                throw ArmError.mediaMissing(cueName: cue.displayName)
            }
            let targets = try resolveTargets(
                groupID: body.outputGroupID, legacy: nil, cueNumber: cue.number
            )
            return try await StillCuePlayer.arm(body: body, imageURL: url, targets: targets)

        case .fade, .stop, .group, .broken:
            throw ArmError.notAMediaCue
        }
    }

    /// Output resolution, in order: output group → legacy fingerprint → main
    /// display. Groups may span several displays (mirrored output). A group
    /// with NO connected member is a hard arm failure (never the wrong
    /// screen); a partially connected group plays on what's there, loudly.
    ///
    /// REHEARSAL: every cue maps to its group's floating preview window (one
    /// per group, plus one for "main display" cues), with no connectivity
    /// checks — that's the point: rehearse with no rig attached.
    private func resolveTargets(
        groupID: UUID?,
        legacy: DisplayFingerprint?,
        cueNumber: String
    ) throws -> [OutputTarget] {
        if rehearsalActive() {
            if let groupID, let group = settings().group(withID: groupID) {
                return [.preview(id: group.id, title: group.name)]
            }
            if let legacy {
                // Pre-migration direct assignment: one shared legacy preview.
                return [.preview(id: OutputTarget.mainPreviewID, title: legacy.name)]
            }
            throw ArmError.noOutputAssigned(cueName: cueNumber)
        }
        return try resolveDisplayIDs(groupID: groupID, legacy: legacy, cueNumber: cueNumber)
            .map { .display($0) }
    }

    private func resolveDisplayIDs(
        groupID: UUID?,
        legacy: DisplayFingerprint?,
        cueNumber: String
    ) throws -> [CGDirectDisplayID] {
        if let groupID {
            guard let group = settings().group(withID: groupID) else {
                throw ArmError.displayMissing(cueName: cueNumber, displayName: "deleted output group")
            }
            guard !group.displays.isEmpty else {
                throw ArmError.displayMissing(cueName: cueNumber, displayName: "\(group.name) (no displays assigned)")
            }
            var ids: [CGDirectDisplayID] = []
            var seen = Set<CGDirectDisplayID>()
            var missing: [String] = []
            for fingerprint in group.displays {
                if let match = DisplayManager.shared.match(fingerprint) {
                    if seen.insert(match.displayID).inserted {
                        ids.append(match.displayID)
                    }
                } else {
                    missing.append(fingerprint.name)
                }
            }
            guard !ids.isEmpty else {
                throw ArmError.displayMissing(cueName: cueNumber, displayName: group.name)
            }
            if !missing.isEmpty {
                onWarning?("Cue \(cueNumber): output “\(group.name)” is missing \(missing.joined(separator: ", ")) — playing on the connected display\(ids.count == 1 ? "" : "s").")
            }
            return ids
        }
        if let legacy {
            if let match = DisplayManager.shared.match(legacy) {
                return [match.displayID]
            }
            throw ArmError.displayMissing(cueName: cueNumber, displayName: legacy.name)
        }
        // No implicit main-display fallback: an unrouted cue must never paint
        // fullscreen video over the operator's control screen.
        throw ArmError.noOutputAssigned(cueName: cueNumber)
    }
}
