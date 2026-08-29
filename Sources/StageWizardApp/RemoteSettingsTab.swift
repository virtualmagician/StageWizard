import SwiftUI

/// Operator-facing description of a captured MIDI-Learn binding
/// ("Note 60 ch 1" / "CC 64 ch 1"). Mirrors KeyBinding.displayName's role
/// for keyboard shortcuts — channels are displayed 1-based, as every DAW/
/// controller does, even though the wire value is 0-15.
extension MIDIBinding {
    var displayName: String {
        switch kind {
        case .noteOn: return "Note \(number) ch \(channel + 1)"
        case .controlChange: return "CC \(number) ch \(channel + 1)"
        }
    }
}

/// MIDI remote-control settings — a tab inside SettingsPanelView. Enable
/// toggle, connected-source list, and one MIDI-Learn binding row per
/// bindable transport action (the same set the keyboard shortcuts tab
/// exposes — see ShortcutAction.assignable).
struct RemoteSettingsTab: View {
    @Environment(ShowDocumentController.self) private var document
    @Environment(AppModel.self) private var app
    @State private var learningAction: ShortcutAction?

    var body: some View {
        Form {
            Section("MIDI Control") {
                Toggle("Enable MIDI Control", isOn: Binding(
                    get: { document.show.settings.midiEnabled },
                    set: { app.setMIDIEnabled($0) }
                ))

                if app.midiController.sources.isEmpty {
                    Text("No MIDI sources")
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(app.midiController.sources, id: \.self) { name in
                        Label(name, systemImage: "pianokeys")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Bindings") {
                ForEach(ShortcutAction.assignable, id: \.self) { action in
                    bindingRow(for: action)
                }
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            Text("MIDI triggers are active in every mode while enabled.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.bottom, 8)
        }
        .onDisappear {
            if learningAction != nil { cancelLearning() }
        }
    }

    private func bindingRow(for action: ShortcutAction) -> some View {
        let binding = document.show.settings.midiBindings.first { $0.action == action }?.binding
        let isLearning = learningAction == action

        return HStack {
            Text(action.displayName)
            Spacer()
            Text(isLearning ? "Listening…" : (binding?.displayName ?? "—"))
                .foregroundStyle(binding == nil && !isLearning ? .secondary : .primary)
                .frame(minWidth: 110, alignment: .trailing)
            Button(isLearning ? "Cancel" : "Learn") {
                if isLearning {
                    cancelLearning()
                } else {
                    startLearning(for: action)
                }
            }
            .disabled(learningAction != nil && !isLearning)
            if binding != nil && !isLearning {
                Button {
                    clearBinding(for: action)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove MIDI binding")
            }
        }
    }

    private func startLearning(for action: ShortcutAction) {
        learningAction = action
        app.midiController.onLearned = { binding in
            assign(binding, to: action)
            learningAction = nil
        }
        app.midiController.learning = true
    }

    private func cancelLearning() {
        app.midiController.cancelLearning()
        learningAction = nil
    }

    private func assign(_ binding: MIDIBinding, to action: ShortcutAction) {
        document.mutate { show in
            // One trigger, one meaning: steal from any other action already
            // using this exact MIDI message — same rule ShortcutBindingsForm
            // applies to keyboard bindings, so a duplicate can't go dead.
            show.settings.midiBindings.removeAll { $0.binding == binding || $0.action == action }
            show.settings.midiBindings.append(MIDIBindingEntry(binding: binding, action: action))
        }
    }

    private func clearBinding(for action: ShortcutAction) {
        document.mutate { show in
            show.settings.midiBindings.removeAll { $0.action == action }
        }
    }
}
