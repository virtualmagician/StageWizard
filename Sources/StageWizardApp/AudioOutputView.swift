import SwiftUI

/// Output-device routing editor for an audio cue — the Output tab's content
/// for `.audio` bodies. Self-contained: reads/writes AudioBody.outputDeviceUID
/// and outputDeviceName through ShowDocumentController; the integrator drops
/// `AudioOutputSettingsView(cueID:)` into InspectorView's OutputTab.
struct AudioOutputSettingsView: View {
    @Environment(ShowDocumentController.self) private var document
    let cueID: UUID

    // @Observable: reading outputDevices in body subscribes this view to
    // hot-plug re-enumerations from the HAL listener.
    private var deviceManager: AudioDeviceManager { AudioDeviceManager.shared }

    var body: some View {
        if let cue = document.cue(withID: cueID), case .audio(let audio) = cue.body {
            Form {
                Picker("Output device", selection: selectionBinding(for: audio)) {
                    Text(systemDefaultLabel).tag(nil as String?)
                    ForEach(deviceManager.outputDevices) { device in
                        Text("\(device.name) (\(device.channelCount) ch)").tag(device.uid as String?)
                    }
                    // Keep a saved-but-disconnected device selectable so the
                    // Picker's selection stays valid and the choice isn't lost.
                    if let uid = audio.outputDeviceUID, !isConnected(uid) {
                        Text("\(audio.outputDeviceName ?? "Saved device") (not connected)")
                            .tag(uid as String?)
                    }
                }
                .frame(maxWidth: 400)

                if let uid = audio.outputDeviceUID, !isConnected(uid) {
                    Label {
                        Text("“\(audio.outputDeviceName ?? uid)” is not connected. This cue will play on the system default output.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
            .formStyle(.columns)
            .padding(12)
        } else {
            Text("No audio output settings for this cue.")
                .foregroundStyle(.secondary)
                .padding(12)
        }
    }

    private var systemDefaultLabel: String {
        if let defaultDevice = deviceManager.defaultOutputDevice {
            return "System Default (\(defaultDevice.name))"
        }
        return "System Default"
    }

    private func isConnected(_ uid: String) -> Bool {
        deviceManager.outputDevices.contains { $0.uid == uid }
    }

    private func selectionBinding(for audio: AudioBody) -> Binding<String?> {
        Binding(
            get: { audio.outputDeviceUID },
            set: { newUID in
                let connectedName = newUID.flatMap { uid in
                    AudioDeviceManager.shared.outputDevices.first { $0.uid == uid }?.name
                }
                document.updateCue(cueID) { cue in
                    guard case .audio(var body) = cue.body else { return }
                    body.outputDeviceUID = newUID
                    if let newUID {
                        // Keep the old human-readable name when re-selecting a
                        // device that is currently disconnected.
                        body.outputDeviceName = connectedName
                            ?? (newUID == audio.outputDeviceUID ? audio.outputDeviceName : nil)
                    } else {
                        body.outputDeviceName = nil
                    }
                    cue.body = .audio(body)
                }
            }
        )
    }
}
