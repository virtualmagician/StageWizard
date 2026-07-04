import SwiftUI

/// Records a single keystroke into a KeyBinding. Esc cancels. The capture goes
/// through ShortcutManager so normal shortcut handling is suspended while
/// recording.
struct ShortcutRecorderField: View {
    @Environment(AppModel.self) private var app
    let binding: KeyBinding?
    let onRecord: (KeyBinding?) -> Void

    @State private var isRecording = false

    var body: some View {
        HStack(spacing: 6) {
            Button {
                startRecording()
            } label: {
                Text(isRecording ? "Press a key…" : (binding?.displayName ?? "Not set"))
                    .frame(minWidth: 110)
            }
            .buttonStyle(.bordered)
            .tint(isRecording ? .accentColor : nil)

            if binding != nil && !isRecording {
                Button {
                    onRecord(nil)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove shortcut")
            }
        }
        .onDisappear { cancelRecording() }
    }

    private func startRecording() {
        isRecording = true
        app.shortcuts.captureNext = { recorded in
            isRecording = false
            onRecord(recorded)
            return true
        }
    }

    private func cancelRecording() {
        if isRecording {
            app.shortcuts.captureNext = nil
            isRecording = false
        }
    }
}

/// Shortcut assignment form — a tab inside SettingsPanelView.
/// Esc/panic is shown but fixed.
struct ShortcutBindingsForm: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            HStack {
                Text("Panic (fixed)")
                Spacer()
                Text("Esc — press twice for hard stop")
                    .foregroundStyle(.secondary)
            }
            ForEach(ShortcutAction.assignable, id: \.self) { action in
                HStack {
                    Text(action.displayName)
                    Spacer()
                    ShortcutRecorderField(
                        binding: app.document.show.settings.keyBindings[action]
                    ) { newBinding in
                        assign(newBinding, to: action)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func assign(_ binding: KeyBinding?, to action: ShortcutAction) {
        app.document.mutate { show in
            // One key, one meaning: steal from other transport actions AND
            // from per-cue hotkeys (transport lookup wins at dispatch time,
            // so a duplicate hotkey would silently go dead).
            if let binding {
                for other in ShortcutAction.allCases where show.settings.keyBindings[other] == binding {
                    show.settings.keyBindings[other] = nil
                }
                for index in show.cues.indices where show.cues[index].hotkey == binding {
                    show.cues[index].hotkey = nil
                }
                show.settings.keyBindings[action] = binding
            } else {
                show.settings.keyBindings[action] = nil
            }
        }
    }
}
