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
    /// True while the virtual webcam is feeding — groups flagged
    /// `virtualCamera` then mirror onto its monitor panel too.
    var virtualCameraFeeding: @MainActor () -> Bool = { false }
    /// D13: the output group the stage display's PROGRAM pane currently
    /// mirrors, or nil — nil whenever the stage display isn't open, or its
    /// program pane isn't enabled (see `StageDisplayController.isProgramPaneShowing`).
    /// Wired by AppModel, same shape as `virtualCameraFeeding`.
    var stageDisplayProgramGroupID: @MainActor () -> UUID? = { nil }
    /// D11 (experimental): fires when a live camera cue's gesture hold
    /// completes. Wired by AppModel to a mode-gated GO — see `AppModel.wireEngines`.
    var onGesture: (@MainActor () -> Void)?
    /// D15: fires with a camera cue's live gesture readout for the stage
    /// display's gesture pane — the cue id identifies WHICH cue it came
    /// from (so a stopping cue never clears a different cue's readout);
    /// `nil` clears it. Wired by AppModel — see `AppModel.gestureReadout`.
    var onGestureReadout: (@MainActor (UUID, GestureReadout?) -> Void)?

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
            let player = try await CameraCuePlayer.arm(
                body: body, targets: targets,
                dustEmitterURL: body.effects.dustEmitter?.resolve(showFolder: showFolder)
            )
            player.onGesture = { [weak self] in
                self?.onGesture?()
            }
            player.onGestureReadout = { [weak self] readout in
                self?.onGestureReadout?(cue.id, readout)
            }
            return player

        case .slide(let body):
            guard let url = body.media.resolve(showFolder: showFolder) else {
                throw ArmError.mediaMissing(cueName: cue.displayName)
            }
            let targets = try resolveTargets(
                groupID: body.outputGroupID, legacy: nil, cueNumber: cue.number
            )
            return try await StillCuePlayer.arm(body: body, imageURL: url, targets: targets)

        case .image(let body):
            guard let url = body.media.resolve(showFolder: showFolder) else {
                throw ArmError.mediaMissing(cueName: cue.displayName)
            }
            let targets = try resolveTargets(
                groupID: body.outputGroupID, legacy: nil, cueNumber: cue.number
            )
            return try await StillCuePlayer.arm(body: body, imageURL: url, targets: targets)

        case .text(let body):
            let targets = try resolveTargets(
                groupID: body.outputGroupID, legacy: nil, cueNumber: cue.number
            )
            return try await TextCuePlayer.arm(body: body, targets: targets)

        case .fade, .stop, .group, .broken:
            throw ArmError.notAMediaCue
        }
    }

    /// Output resolution, in order: floating-window group override → output
    /// group → legacy fingerprint → main display. Groups may span several
    /// displays (mirrored output). A group with NO connected member is a
    /// hard arm failure (never the wrong screen); a partially connected
    /// group plays on what's there, loudly.
    ///
    /// REHEARSAL: every cue maps to its group's floating preview window (one
    /// per group, plus one for "main display" cues), with no connectivity
    /// checks — that's the point: rehearse with no rig attached.
    ///
    /// D14: a group with `floatingWindow` set resolves to its own floating
    /// preview window in EVERY mode (Show included) — checked first, before
    /// the rehearsal branch, since rehearsal already resolves every group to
    /// the same preview target anyway.
    private func resolveTargets(
        groupID: UUID?,
        legacy: DisplayFingerprint?,
        cueNumber: String
    ) throws -> [OutputTarget] {
        let extra = Self.extraTargets(
            groupID: groupID,
            settings: settings(),
            virtualCameraFeeding: virtualCameraFeeding(),
            stageDisplayProgramGroupID: stageDisplayProgramGroupID()
        )
        if let floating = Self.floatingTarget(groupID: groupID, settings: settings()) {
            return [floating] + extra
        }
        if rehearsalActive() {
            if let groupID, let group = settings().group(withID: groupID) {
                return [.preview(id: group.id, title: group.name)] + extra
            }
            if let legacy {
                // Pre-migration direct assignment: one shared legacy preview.
                return [.preview(id: OutputTarget.mainPreviewID, title: legacy.name)]
            }
            throw ArmError.noOutputAssigned(cueName: cueNumber)
        }
        do {
            let displays = try resolveDisplayIDs(groupID: groupID, legacy: legacy, cueNumber: cueNumber)
                .map { OutputTarget.display($0) }
            return displays + extra
        } catch {
            // A webcam-only group (no displays assigned/connected) is valid
            // as long as the virtual camera is live.
            if !extra.isEmpty { return extra }
            throw error
        }
    }

    /// Extra output targets appended to a group's REAL routing regardless of
    /// mode or display connectivity. The virtual-webcam monitor panel and
    /// (D13) the stage display's program view are both "extra layers on top
    /// of the real routing" — a target added alongside whatever the group
    /// actually resolves to, so ONE decode also mirrors onto a preview
    /// window elsewhere. Factored out of `resolveTargets` as a pure
    /// function (no window/player/provider needed) so the append DECISION
    /// is unit-testable on its own.
    static func extraTargets(
        groupID: UUID?,
        settings: ShowSettings,
        virtualCameraFeeding: Bool,
        stageDisplayProgramGroupID: UUID?
    ) -> [OutputTarget] {
        var extra: [OutputTarget] = []
        if virtualCameraFeeding,
           let groupID, let group = settings.group(withID: groupID), group.virtualCamera {
            extra.append(VirtualCameraManager.monitorTarget)
        }
        if let groupID, let programGroupID = stageDisplayProgramGroupID, groupID == programGroupID {
            extra.append(StageDisplayController.programTarget)
        }
        return extra
    }

    /// D14: pure "should this group float, and if so where" decision —
    /// factored out for direct unit testing exactly like `extraTargets`
    /// above. A floating group's `displays` list is deliberately never
    /// consulted here (and no `DisplayManager`/window state is touched) —
    /// floating routing needs no connectivity at all.
    static func floatingTarget(groupID: UUID?, settings: ShowSettings) -> OutputTarget? {
        guard let groupID, let group = settings.group(withID: groupID), group.floatingWindow else {
            return nil
        }
        return .preview(id: group.id, title: group.name)
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
