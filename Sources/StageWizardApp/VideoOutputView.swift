import SwiftUI

/// Output tab contents for a video cue: output-group assignment + fill mode.
/// Cues target virtual output groups (managed in Settings → Video Outputs);
/// reassigning a group's displays re-routes every cue that uses it.
struct VideoOutputSettingsView: View {
    @Environment(ShowDocumentController.self) private var document
    let cueID: UUID

    init(cueID: UUID) {
        self.cueID = cueID
    }

    var body: some View {
        if let cue = document.cue(withID: cueID), case .video(let video) = cue.body {
            Form {
                OutputGroupPicker(selection: Binding(
                    get: { currentVideoBody()?.outputGroupID },
                    set: { newValue in
                        updateVideo {
                            $0.outputGroupID = newValue
                            $0.display = nil   // group assignment supersedes legacy pinning
                        }
                    }
                ))

                groupStatus(video)

                Text("Placement and scaling moved to the Geometry tab.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .formStyle(.columns)
            .padding(12)
        }
    }

    /// Inline health check: deleted group, empty group, or offline members.
    @ViewBuilder
    private func groupStatus(_ video: VideoBody) -> some View {
        if let groupID = video.outputGroupID {
            if let group = document.show.settings.group(withID: groupID) {
                let offline = group.displays.filter { DisplayManager.shared.match($0) == nil }
                if group.displays.isEmpty {
                    Label("“\(group.name)” has no displays assigned — the cue won't play.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                } else if offline.count == group.displays.count {
                    Label("All displays of “\(group.name)” are offline.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                } else if !offline.isEmpty {
                    Label("\(offline.map(\.name).joined(separator: ", ")) offline — plays on the rest.",
                          systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                Label("The assigned output group was deleted — pick another.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        } else if let legacy = video.display {
            Label("Legacy direct display “\(legacy.name)” — assign an output group instead.",
                  systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            Label("No output assigned — the cue won't play. Create groups in Settings → Video Outputs.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
        }
    }

    // MARK: - Model plumbing

    private func currentVideoBody() -> VideoBody? {
        guard let cue = document.cue(withID: cueID), case .video(let body) = cue.body else {
            return nil
        }
        return body
    }

    private func updateVideo(_ change: (inout VideoBody) -> Void) {
        document.updateCue(cueID) { cue in
            if case .video(var body) = cue.body {
                change(&body)
                cue.body = .video(body)
            }
        }
    }
}
