import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var app
    @Environment(ShowDocumentController.self) private var document
    @State private var showingShortcuts = false

    var body: some View {
        VStack(spacing: 0) {
            GoMasthead()
            Divider()
            // In flow, right under the transport strip: warnings surface at
            // the top of the window where the operator is already looking,
            // and never cover the cue list or the GO button.
            WarningBanner()
            HSplitView {
                VSplitView {
                    CueListView()
                        .frame(minHeight: 240)
                    // Show mode: the inspector (an editing surface) disappears
                    // and the list gets the full height.
                    if !app.isShowMode {
                        InspectorView()
                            .frame(minHeight: 180, idealHeight: 230)
                    }
                }
                .layoutPriority(1)

                ActiveCuesPanel()
                    .frame(minWidth: 230, idealWidth: 270, maxWidth: 400)
            }
            Divider()
            ModeBar()
        }
        .navigationTitle(document.windowTitle)
        .toolbar { toolbarContent }
        .sheet(isPresented: $showingShortcuts) {
            SettingsPanelView()
        }
        .onChange(of: document.selection) {
            app.selectionChanged()
        }
        .onChange(of: app.transport.playheadID) {
            app.playheadChanged()
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            if !app.isShowMode {
                editingToolbarItems
            }

            Spacer()

            Button {
                showingShortcuts = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Show settings: general, video outputs, shortcuts")
        }
    }

    @ViewBuilder
    private var editingToolbarItems: some View {
        Group {
            Menu {
                Button("Audio Cue…") { CueFactory.addMediaCue(kind: .audio, to: document) }
                Button("Video Cue…") { CueFactory.addMediaCue(kind: .video, to: document) }
                Button("Camera Cue") { CueFactory.addControlCue(.camera(CameraBody()), to: document) }
                Button("Image Cue…") { CueFactory.addMediaCue(kind: .image, to: document) }
                Button("Text Cue") { CueFactory.addControlCue(.text(CueFactory.defaultTextBody()), to: document) }
                Button("Slides from Deck…") { SlideDeckImporter.importDeckViaPanel(into: document, app: app) }
                Divider()
                Button("Fade Cue") { CueFactory.addControlCue(.fade(FadeBody()), to: document) }
                Button("Stop Cue") { CueFactory.addControlCue(.stop(StopBody()), to: document) }
                Button("Group") { CueFactory.addControlCue(.group(GroupBody()), to: document) }
            } label: {
                Label("Add Cue", systemImage: "plus")
            }
            Button {
                CueFactory.deleteSelection(in: document)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(document.selection.isEmpty)
        }
    }
}

/// Slim bottom bar: Edit | Show mode switch + cue count.
struct ModeBar: View {
    @Environment(AppModel.self) private var app
    @Environment(ShowDocumentController.self) private var document

    var body: some View {
        HStack {
            Picker("", selection: Binding(
                get: { app.mode },
                set: { app.setMode($0) }
            )) {
                Text("Edit").tag(WorkspaceMode.edit)
                Text("Show").tag(WorkspaceMode.show)
                Text("Rehearsal").tag(WorkspaceMode.rehearsal)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 230)
            .help("Show locks editing (⌘E); Rehearsal also routes video into floating preview windows (⌘R). GO, panic, and the Active Cues panel always stay live.")

            switch app.mode {
            case .edit:
                EmptyView()
            case .show:
                Label("Workspace locked", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .rehearsal:
                Label("Rehearsal — outputs go to preview windows", systemImage: "rectangle.on.rectangle")
                    .font(.caption)
                    .foregroundStyle(Theme.hold)
            }

            Spacer()

            Text("\(document.show.cues.count) cues")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Theme.headerBackground)
    }
}
