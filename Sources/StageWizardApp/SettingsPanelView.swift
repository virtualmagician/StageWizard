import SwiftUI

/// Workspace settings, opened from the gear toolbar button.
/// Everything here writes into ShowSettings (travels with the show file).
struct SettingsPanelView: View {
    @Environment(ShowDocumentController.self) private var document
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .general

    enum Tab: String, CaseIterable {
        case general = "General"
        case outputs = "Video Outputs"
        case shortcuts = "Shortcuts"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Show Settings")
                    .font(.title3.weight(.semibold))
                Spacer()
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 340)
            }
            .padding()

            Divider()

            Group {
                switch tab {
                case .general: GeneralSettingsTab()
                case .outputs: OutputGroupsTab()
                case .shortcuts: ShortcutBindingsForm()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                Text("Settings are stored in the show file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 640, height: 480)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @Environment(ShowDocumentController.self) private var document

    var body: some View {
        Form {
            HStack {
                TimecodeField(label: "Panic duration", value: Binding(
                    get: { document.show.settings.panicDuration },
                    set: { v in document.mutate { $0.settings.panicDuration = max(0, v) } }
                ))
                Text("Esc fades everything out over this time; Esc twice = hard stop.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            HStack {
                TimecodeField(label: "Minimum time between GOs", value: Binding(
                    get: { document.show.settings.doubleGOProtection },
                    set: { v in document.mutate { $0.settings.doubleGOProtection = max(0, v) } }
                ))
                Text("Double-GO protection; 0 = off.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Video output groups

/// Manage the virtual outputs ("Internal", "External 1", "Prompter"...) that
/// video and camera cues target. Reassign displays here and every cue that
/// uses the group follows — no cue editing needed after a rig change.
private struct OutputGroupsTab: View {
    @Environment(ShowDocumentController.self) private var document
    @State private var selectedGroupID: UUID?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selectedGroupID) {
                    ForEach(document.show.settings.outputGroups) { group in
                        HStack {
                            Image(systemName: "tv")
                            Text(group.name)
                            Spacer()
                            Text("\(group.displays.count)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                        .tag(group.id)
                    }
                }
                .listStyle(.plain)
                Divider()
                HStack(spacing: 12) {
                    Button {
                        addGroup()
                    } label: {
                        Image(systemName: "plus")
                    }
                    Button {
                        deleteSelectedGroup()
                    } label: {
                        Image(systemName: "minus")
                    }
                    .disabled(selectedGroupID == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(minWidth: 180, idealWidth: 200, maxWidth: 260)

            Group {
                if let groupID = selectedGroupID,
                   let group = document.show.settings.group(withID: groupID) {
                    GroupDetail(groupID: groupID, group: group)
                } else {
                    Text(document.show.settings.outputGroups.isEmpty
                         ? "Add an output group (+), then assign displays to it."
                         : "Select an output group.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .layoutPriority(1)
        }
        .onAppear {
            if selectedGroupID == nil {
                selectedGroupID = document.show.settings.outputGroups.first?.id
            }
        }
    }

    private func addGroup() {
        let group = OutputGroup(name: "New Output \(document.show.settings.outputGroups.count + 1)")
        document.mutate { $0.settings.outputGroups.append(group) }
        selectedGroupID = group.id
    }

    private func deleteSelectedGroup() {
        guard let id = selectedGroupID else { return }
        let inUse = document.show.cues.contains { cue in
            switch cue.body {
            case .video(let b): return b.outputGroupID == id
            case .camera(let b): return b.outputGroupID == id
            default: return false
            }
        }
        if inUse {
            let alert = NSAlert()
            alert.messageText = "This output group is used by cues."
            alert.informativeText = "Cues pointing at it will fail to play until you assign them a different output."
            alert.addButton(withTitle: "Delete Anyway")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        document.mutate { $0.settings.outputGroups.removeAll { $0.id == id } }
        selectedGroupID = document.show.settings.outputGroups.first?.id
    }
}

private struct GroupDetail: View {
    @Environment(ShowDocumentController.self) private var document
    let groupID: UUID
    let group: OutputGroup

    var body: some View {
        Form {
            TextField("Name", text: Binding(
                get: { group.name },
                set: { v in update { $0.name = v } }
            ))
            .frame(maxWidth: 300)

            Section("Assigned displays — the same video mirrors onto all of them") {
                // Connected displays as toggles.
                ForEach(DisplayManager.shared.displays, id: \.displayID) { connected in
                    Toggle(isOn: assignmentBinding(for: connected.fingerprint)) {
                        HStack {
                            Text(connected.fingerprint.name)
                            Text("\(connected.fingerprint.pixelWidth)×\(connected.fingerprint.pixelHeight)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                // Assigned-but-offline fingerprints, listed as "(offline)".
                ForEach(offlineAssignments, id: \.self) { fingerprint in
                    HStack {
                        Image(systemName: "checkmark.square")
                            .foregroundStyle(.secondary)
                        Text("\(fingerprint.name) (offline)")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            update { $0.displays.removeAll { $0 == fingerprint } }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .help("Remove from this group")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var offlineAssignments: [DisplayFingerprint] {
        group.displays.filter { DisplayManager.shared.match($0) == nil }
    }

    private func assignmentBinding(for fingerprint: DisplayFingerprint) -> Binding<Bool> {
        Binding(
            get: {
                document.show.settings.group(withID: groupID)?.displays.contains {
                    $0.matchScore(against: fingerprint) > 0
                } ?? false
            },
            set: { assigned in
                update { group in
                    if assigned {
                        if !group.displays.contains(where: { $0.matchScore(against: fingerprint) > 0 }) {
                            group.displays.append(fingerprint)
                        }
                    } else {
                        group.displays.removeAll { $0.matchScore(against: fingerprint) > 0 }
                    }
                }
            }
        )
    }

    private func update(_ change: (inout OutputGroup) -> Void) {
        document.mutate { show in
            guard let index = show.settings.outputGroups.firstIndex(where: { $0.id == groupID }) else { return }
            change(&show.settings.outputGroups[index])
        }
    }
}

// MARK: - Shared output-group picker (used by cue Output tabs)

struct OutputGroupPicker: View {
    @Environment(ShowDocumentController.self) private var document
    @Binding var selection: UUID?

    var body: some View {
        Picker("Output", selection: $selection) {
            // Unassigned is a visible STATE, not a choice — once a group is
            // picked this row disappears. There is deliberately no implicit
            // "main display" target (it would cover the control screen).
            if selection == nil {
                Text("No output assigned").tag(nil as UUID?)
            }
            ForEach(document.show.settings.outputGroups) { group in
                Text("\(group.name) (\(group.displays.count) display\(group.displays.count == 1 ? "" : "s"))")
                    .tag(group.id as UUID?)
            }
            if let selection, document.show.settings.group(withID: selection) == nil {
                Text("Missing output group").tag(selection as UUID?)
            }
        }
        .frame(maxWidth: 400)
    }
}
