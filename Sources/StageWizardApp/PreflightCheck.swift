import SwiftUI

/// One thing preflight found wrong (or worth a warning about) with the show.
struct PreflightIssue: Identifiable, Sendable {
    enum Severity: Sendable, Equatable {
        case error
        case warning
    }

    let id = UUID()
    /// The cue this issue is about, or nil for a show/output-wide issue.
    let cueNumber: String?
    let message: String
    let severity: Severity
}

/// Read-only sweep of the current show for problems that would surface as a
/// failed cue mid-show — run before the first GO so the operator can fix them
/// in the calm of Edit mode instead.
///
/// Deliberately pure: camera authorization, virtual-webcam feed state, and
/// connected audio devices are passed IN rather than read from AppModel/live
/// singletons, so this is unit-testable without a running app. Display
/// connectivity is the one exception — it reads `DisplayManager.shared`
/// directly, mirroring exactly how the runtime resolves output groups at arm
/// time (see `DisplayManager.match`).
@MainActor
enum Preflight {
    static func run(
        show: ShowFile,
        showFolder: URL?,
        cameraAuthorized: Bool,
        virtualCamFeeding: Bool,
        connectedDevices: [AudioOutputDevice],
        stageDisplayCoversOperatorScreen: Bool = false
    ) -> [PreflightIssue] {
        var issues: [PreflightIssue] = []
        // Ordered (not a Set) so issue order is stable — nice for tests and
        // for the operator reading the sheet top to bottom.
        var armedOutputGroupIDs: [UUID] = []

        for cue in show.cues {
            // 7. Unknown cue types (a show edited by a newer app version, or
            // hand-corrupted JSON) can't play — always an error.
            if case .broken(let body) = cue.body {
                issues.append(PreflightIssue(
                    cueNumber: cue.number,
                    message: "Cue \(cue.number): unknown cue type (\(body.originalType)) — was this show edited by a newer version of StageWizard?",
                    severity: .error
                ))
            }

            // 1. Media resolution — reported even for disarmed cues, but only
            // as a warning (it won't stop the show since it never plays).
            if let media = mediaReference(for: cue.body), media.resolve(showFolder: showFolder) == nil {
                issues.append(PreflightIssue(
                    cueNumber: cue.number,
                    message: "Cue \(cue.number): media file missing (\(media.fileName))",
                    severity: cue.armed ? .error : .warning
                ))
            }

            // Output/device checks only matter for cues that will actually
            // fire — a disarmed cue with a stale output or device is a no-op.
            guard cue.armed else { continue }

            // 2. Output group assignment for visual cues.
            if let requirement = outputGroupRequirement(for: cue.body) {
                if let groupID = requirement {
                    if show.settings.group(withID: groupID) == nil {
                        issues.append(PreflightIssue(
                            cueNumber: cue.number,
                            message: "Cue \(cue.number): output group missing (it was deleted from Show Settings)",
                            severity: .error
                        ))
                    } else if !armedOutputGroupIDs.contains(groupID) {
                        armedOutputGroupIDs.append(groupID)
                    }
                } else {
                    issues.append(PreflightIssue(
                        cueNumber: cue.number,
                        message: "Cue \(cue.number): no video output assigned",
                        severity: .error
                    ))
                }
            }

            // 6. Audio device resolution (own output, or a video's embedded track).
            if let uid = audioDeviceUID(for: cue.body), !connectedDevices.contains(where: { $0.uid == uid }) {
                issues.append(PreflightIssue(
                    cueNumber: cue.number,
                    message: "Cue \(cue.number): audio device not connected — will fall back to default.",
                    severity: .warning
                ))
            }

            // 8. D29: OSC Send cues need a destination host to do anything,
            // and a well-formed address (a missing leading "/" still sends,
            // per OSC 1.0, but is almost certainly a typo) — the second is a
            // warning only, since it doesn't actually stop the cue from firing.
            if case .oscSend(let osc) = cue.body {
                if osc.host.isEmpty {
                    issues.append(PreflightIssue(
                        cueNumber: cue.number,
                        message: "Cue \(cue.number): OSC cue has no destination host",
                        severity: .error
                    ))
                }
                if !osc.address.hasPrefix("/") {
                    issues.append(PreflightIssue(
                        cueNumber: cue.number,
                        message: "Cue \(cue.number): OSC address “\(osc.address)” doesn't start with “/”",
                        severity: .warning
                    ))
                }
            }
        }

        // 4. Camera permission — show-wide, mirrors
        // AppModel.checkPermissionsForCurrentShow's own detection (any camera
        // cue, armed or not: a disarmed one can be armed later mid-show).
        let usesCamera = show.cues.contains { cue in
            if case .camera = cue.body { return true }
            return false
        }
        if usesCamera, !cameraAuthorized {
            issues.append(PreflightIssue(
                cueNumber: nil,
                message: "Camera access is not authorized — camera cues will fail.",
                severity: .error
            ))
        }

        // D17, updated D18 (FIX 1): the stage display is set to the SAME
        // screen as the operator's own window (or that can't be determined
        // yet) — Show mode will open it as a floating window instead of
        // fullscreen so it never buries the console. Not an error (the show
        // still plays fine either way), but worth flagging before the
        // operator finds out live.
        if stageDisplayCoversOperatorScreen {
            issues.append(PreflightIssue(
                cueNumber: nil,
                message: "Stage display is set to the operator's own screen — Show mode will open it as a floating window instead of fullscreen.",
                severity: .warning
            ))
        }

        // 3 & 5. Every output group actually in play: display connectivity,
        // and (separately) whether its virtual-webcam feed is running.
        for groupID in armedOutputGroupIDs {
            guard let group = show.settings.group(withID: groupID) else { continue }
            // D14: a floating-window group needs neither a connected display
            // nor the webcam feed — it always has somewhere to play.
            if !group.floatingWindow {
                let hasConnectedDisplay = group.displays.contains { DisplayManager.shared.match($0) != nil }
                let coveredByVirtualCam = group.virtualCamera && virtualCamFeeding
                if !hasConnectedDisplay, !coveredByVirtualCam {
                    issues.append(PreflightIssue(
                        cueNumber: nil,
                        message: "Output '\(group.name)': no assigned display is connected",
                        severity: .error
                    ))
                }
            }
            if group.virtualCamera, !virtualCamFeeding {
                issues.append(PreflightIssue(
                    cueNumber: nil,
                    message: "Output '\(group.name)': virtual webcam feed is not running",
                    severity: .warning
                ))
            }
        }

        return issues
    }

    // MARK: - Body accessors (mirror CueListView's isMediaBroken / isOutputMissing)

    private static func mediaReference(for body: CueBody) -> MediaReference? {
        switch body {
        case .audio(let b): return b.media
        case .video(let b): return b.media
        case .image(let b): return b.media
        case .slide(let b): return b.media
        default: return nil
        }
    }

    /// nil = not a visual-output cue, or a legacy direct-display cue (handled
    /// at arm time, not here). `.some(nil)` = visual cue with no group
    /// assigned. `.some(.some(id))` = the group id to validate. D25: a
    /// sensor-only camera cue draws nowhere, so it's exempt entirely — same
    /// nil as a legacy direct-display cue.
    private static func outputGroupRequirement(for body: CueBody) -> UUID?? {
        switch body {
        case .video(let b): return b.display == nil ? .some(b.outputGroupID) : nil
        case .camera(let b): return (b.display == nil && !b.sensorOnly) ? .some(b.outputGroupID) : nil
        case .image(let b): return .some(b.outputGroupID)
        case .text(let b): return .some(b.outputGroupID)
        case .slide(let b): return .some(b.outputGroupID)
        default: return nil
        }
    }

    private static func audioDeviceUID(for body: CueBody) -> String? {
        switch body {
        case .audio(let b): return b.outputDeviceUID
        case .video(let b): return b.audioDeviceUID
        default: return nil
        }
    }
}

// MARK: - Results sheet

/// Preflight results sheet — red xmark rows for errors, orange triangle for
/// warnings, or a big green checkmark when the show is clean.
struct PreflightResultsView: View {
    @Environment(\.dismiss) private var dismiss
    let issues: [PreflightIssue]

    private var errorCount: Int { issues.filter { $0.severity == .error }.count }
    private var warningCount: Int { issues.filter { $0.severity == .warning }.count }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if issues.isEmpty {
                    allClear
                } else {
                    List(issues) { issue in
                        row(for: issue)
                            .listRowBackground(Theme.listBackground)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.listBackground)
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 520, height: 420)
        .background(Theme.panelBackground)
    }

    private var header: some View {
        HStack {
            Text(issues.isEmpty
                 ? "Preflight"
                 : "Preflight — \(errorCount) error\(errorCount == 1 ? "" : "s"), \(warningCount) warning\(warningCount == 1 ? "" : "s")")
                .font(.title3.weight(.semibold))
            Spacer()
        }
        .padding()
    }

    private var allClear: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(Theme.standby)
            Text("All clear — ready for the show")
                .font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(for issue: PreflightIssue) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: issue.severity == .error ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(issue.severity == .error ? Theme.panic : .orange)
                .frame(width: 18)
            Text(issue.message)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.vertical, 4)
    }
}
