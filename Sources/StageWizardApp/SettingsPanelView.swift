import AVFoundation
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
        case remote = "Remote"
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
                .frame(width: 420)
            }
            .padding()

            Divider()

            Group {
                switch tab {
                case .general: GeneralSettingsTab()
                case .outputs: OutputGroupsTab()
                case .shortcuts: ShortcutBindingsForm()
                case .remote: RemoteSettingsTab()
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
    @Environment(AppModel.self) private var app
    /// Identifiable wrapper so the sheet is presented via `.sheet(item:)` —
    /// presenting with `isPresented` + a separate issues @State let the sheet
    /// body render with the PRE-press (empty) state and show "All clear" over
    /// a banner that had just counted real issues.
    private struct PreflightRun: Identifiable {
        let id = UUID()
        let issues: [PreflightIssue]
    }
    @State private var preflightRun: PreflightRun?

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
            HStack {
                Button("Preflight…") {
                    preflightRun = PreflightRun(issues: runPreflight())
                }
                Text("Check media, outputs, and permissions before the show.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $preflightRun) { run in
            PreflightResultsView(issues: run.issues)
        }
    }

    private func runPreflight() -> [PreflightIssue] {
        Preflight.run(
            show: document.show,
            showFolder: document.showFolder,
            cameraAuthorized: AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
            virtualCamFeeding: app.virtualCamera.isFeeding,
            connectedDevices: AudioDeviceManager.shared.outputDevices,
            stageDisplayCoversOperatorScreen: app.stageDisplayCoversOperatorScreen
        )
    }
}

// MARK: - Video output groups

/// Manage the virtual outputs ("Internal", "External 1", "Prompter"...) that
/// video and camera cues target. Reassign displays here and every cue that
/// uses the group follows — no cue editing needed after a rig change.
private struct OutputGroupsTab: View {
    @Environment(ShowDocumentController.self) private var document
    @Environment(AppModel.self) private var app
    @State private var selectedGroupID: UUID?
    @State private var showingLayoutEditor = false

    var body: some View {
        VStack(spacing: 0) {
            virtualWebcamBar
            Divider()
            stageDisplaySection
            Divider()
            groupsSplit
        }
    }

    /// Activation + status for the "StageWizard Camera" other apps can use.
    private var virtualWebcamBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "web.camera")
            Text("Virtual Webcam")
                .fontWeight(.semibold)
            Text(app.virtualCamera.status.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            switch app.virtualCamera.status {
            case .active:
                if !app.virtualCamera.isFeeding {
                    Button("Start Feed") { app.setVirtualCameraFeed(true) }
                } else {
                    Button("Stop Feed") { app.setVirtualCameraFeed(false) }
                }
                Button("Deactivate") {
                    app.setVirtualCameraFeed(false)
                    app.virtualCamera.deactivate()
                }
            case .activating:
                ProgressView().controlSize(.small)
            default:
                Button("Activate…") { app.virtualCamera.activate() }
                    .help("Installs the StageWizard Camera extension (one-time macOS approval). Requires running from /Applications.")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// A performer-facing confidence monitor on a chosen display — enable,
    /// pick a display, choose what it shows. Reads transport state only;
    /// never a cue target, so it lives alongside output routing but isn't
    /// part of it.
    private var stageDisplaySection: some View {
        let settings = document.show.settings.stageDisplay
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.on.rectangle")
                Text("Stage Display")
                    .fontWeight(.semibold)
                Spacer()
                Toggle("Enabled", isOn: Binding(
                    get: { settings.enabled },
                    set: { v in app.updateStageDisplay { $0.enabled = v } }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }

            HStack(spacing: 10) {
                Text("Display")
                    .foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { document.show.settings.stageDisplay.display },
                    set: { fingerprint in app.updateStageDisplay { $0.display = fingerprint } }
                )) {
                    Text("None selected").tag(nil as DisplayFingerprint?)
                    ForEach(DisplayManager.shared.displays, id: \.displayID) { connected in
                        Text(connected.fingerprint.name).tag(connected.fingerprint as DisplayFingerprint?)
                    }
                }
                .labelsHidden()
                .frame(width: 220)

                if let chosen = settings.display, DisplayManager.shared.match(chosen) == nil {
                    Label("“\(chosen.name)” is not connected", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            if !document.show.settings.outputGroups.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Mirror on stage display")
                        .foregroundStyle(.secondary)
                    HStack(spacing: 16) {
                        ForEach(document.show.settings.outputGroups) { group in
                            Toggle(group.name, isOn: Binding(
                                get: { document.show.settings.stageDisplay.programPane(forGroup: group.id) != nil },
                                set: { isOn in setGroupMirrored(group.id, isOn) }
                            ))
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }

            HStack(spacing: 16) {
                ForEach(StageDisplayPaneKind.allCases.filter { $0 != .program }, id: \.self) { kind in
                    Toggle(kind.label, isOn: Binding(
                        get: { settings.pane(kind).enabled },
                        set: { v in app.updateStageDisplay { s in
                            if let idx = s.panes.firstIndex(where: { $0.kind == kind }) {
                                s.panes[idx].enabled = v
                            }
                        } }
                    ))
                }
            }
            .toggleStyle(.checkbox)

            HStack(spacing: 10) {
                Button("Edit Layout…") { showingLayoutEditor = true }
                Text("A performer-facing view — never a cue output. Shows in Show and Rehearsal modes. Mirroring picks up already-running cues immediately. ⌘⎋ always exits Show mode.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .sheet(isPresented: $showingLayoutEditor) {
            StageDisplayLayoutEditor()
        }
    }

    /// D16: check a group's "Mirror on stage display" box to append a new
    /// `.program` pane for it; uncheck to remove that pane entirely —
    /// unlike every other pane kind, a program pane's existence in `panes`
    /// IS the mirroring decision, so there's nothing left to disable-but-keep.
    /// D24: the new pane's starting rect is the slot it would occupy in a
    /// freshly RESET multiview grid for the resulting count
    /// (`StageDisplayPane.multiviewCenterCellRect`) — a closer first guess
    /// than the old diagonal stagger, without moving any program pane
    /// already on the canvas (see that function's doc comment for why).
    private func setGroupMirrored(_ groupID: UUID, _ isOn: Bool) {
        app.updateStageDisplay { s in
            if isOn {
                guard s.programPane(forGroup: groupID) == nil else { return }
                let rect = StageDisplayPane.multiviewCenterCellRect(
                    index: s.programPanes.count, ofCount: s.programPanes.count + 1
                )
                s.panes.append(StageDisplayPane(kind: .program, enabled: true, rect: rect, programGroupID: groupID))
            } else {
                s.panes.removeAll { $0.kind == .program && $0.programGroupID == groupID }
            }
        }
    }

    private var groupsSplit: some View {
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

            Toggle("Send to Virtual Webcam", isOn: Binding(
                get: { group.virtualCamera },
                set: { v in update { $0.virtualCamera = v } }
            ))
            .help("Mirror this output into the “StageWizard Camera” that Zoom/Teams/OBS can use (activate it above).")

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Floating window", isOn: Binding(
                    get: { group.floatingWindow },
                    set: { v in
                        update { $0.floatingWindow = v }
                        // Routing stops immediately (EngineBridge checks the
                        // flag on every arm) — close the now-orphaned window
                        // rather than leave it pinned open with nothing left
                        // to play into it. Turning it ON needs no window
                        // action here: hostLayer(for:) opens it lazily the
                        // next time a cue on this group arms.
                        if !v { OutputWindowManager.shared.closePreview(id: groupID) }
                    }
                ))
                if group.floatingWindow {
                    Text("Plays in a floating, resizable window instead of fullscreen displays.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

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
            .disabled(group.floatingWindow)
            .opacity(group.floatingWindow ? 0.4 : 1.0)
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
