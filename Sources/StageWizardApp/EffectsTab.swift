import SwiftUI

/// Effects inspector tab for camera cues: person segmentation, chroma key,
/// magic dust (particle emitters), and gesture GO — everything that touches
/// what the camera's captured frame looks like or how it's classified,
/// separate from Output (source/routing) and Geometry (placement/scaling).
/// Edits push LIVE via `AppModel.pushEffects` — no session restart.
struct EffectsTab: View {
    @Environment(ShowDocumentController.self) private var document
    @Environment(AppModel.self) private var app
    let cueID: UUID

    var body: some View {
        if let cue = document.cue(withID: cueID), case .camera(let camera) = cue.body {
            Form {
                // D25: sensor-only draws to no output, so every VISUAL effect
                // (segmentation/chroma/dust) is meaningless — grouped and
                // disabled together. Gesture GO stays fully live, since
                // gesture tracking is the entire point of sensor-only mode.
                Section("Person") {
                    Toggle("Remove background (person segmentation)", isOn: Binding(
                        get: { camera.effects.segmentation },
                        set: { v in updateEffects { $0.segmentation = v } }
                    ))
                    Text("The background turns transparent — put video or images on a LOWER layer (Geometry tab) and they show behind the performer.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .disabled(camera.sensorOnly)

                Section("Chroma Key") {
                    Toggle("Chroma key", isOn: Binding(
                        get: { camera.effects.chromaKey },
                        set: { v in updateEffects { $0.chromaKey = v } }
                    ))
                    if camera.effects.chromaKey {
                        ColorPicker("Key color", selection: Binding(
                            get: {
                                let c = camera.effects.chromaKeyColor
                                return Color(red: c.red, green: c.green, blue: c.blue, opacity: c.alpha)
                            },
                            set: { color in
                                let resolved = NSColor(color).usingColorSpace(.sRGB) ?? .green
                                updateEffects {
                                    $0.chromaKeyColor = RGBAColor(
                                        red: resolved.redComponent, green: resolved.greenComponent,
                                        blue: resolved.blueComponent, alpha: resolved.alphaComponent
                                    )
                                }
                            }
                        ), supportsOpacity: false)
                        .frame(maxWidth: 280)

                        HStack(spacing: 8) {
                            Text("Tolerance")
                            Slider(value: Binding(
                                get: { camera.effects.chromaTolerance },
                                set: { v in updateEffects { $0.chromaTolerance = v } }
                            ), in: 0...1)
                            .frame(maxWidth: 240)
                            Text(String(format: "%.2f", camera.effects.chromaTolerance))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 48, alignment: .trailing)
                        }
                        HStack(spacing: 8) {
                            Text("Softness")
                            Slider(value: Binding(
                                get: { camera.effects.chromaSoftness },
                                set: { v in updateEffects { $0.chromaSoftness = v } }
                            ), in: 0...1)
                            .frame(maxWidth: 240)
                            Text(String(format: "%.2f", camera.effects.chromaSoftness))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 48, alignment: .trailing)
                        }
                        Text("Pixels near the key color turn transparent — put video or images on a LOWER layer (Geometry tab) and they show behind the performer.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .disabled(camera.sensorOnly)

                Section("Magic Dust") {
                    Toggle("Magic dust on hands", isOn: Binding(
                        get: { camera.effects.magicDust },
                        set: { v in updateEffects { $0.magicDust = v } }
                    ))
                    if camera.effects.magicDust {
                        HStack(spacing: 8) {
                            Picker("Emitter", selection: Binding(
                                get: {
                                    camera.effects.dustEmitter != nil
                                        ? "custom"
                                        : (camera.effects.dustPreset ?? DustPresets.defaultName)
                                },
                                set: { choice in
                                    guard choice != "custom" else { return }
                                    updateEffects {
                                        $0.dustPreset = choice
                                        $0.dustEmitter = nil
                                    }
                                }
                            )) {
                                ForEach(DustPresets.names, id: \.self) { name in
                                    Text(name).tag(name)
                                }
                                if let custom = camera.effects.dustEmitter {
                                    Text("Custom: \(custom.fileName)").tag("custom")
                                }
                            }
                            .frame(maxWidth: 280)

                            Button("Choose .pex…") {
                                let panel = NSOpenPanel()
                                panel.allowsMultipleSelection = false
                                panel.allowedContentTypes = [.init(filenameExtension: "pex") ?? .xml]
                                panel.message = "Choose a Particle Designer emitter"
                                if panel.runModal() == .OK, let url = panel.url {
                                    let ref = MediaReference(fileURL: url, showFolder: document.showFolder)
                                    updateEffects { $0.dustEmitter = ref }
                                }
                            }
                        }
                        HStack(spacing: 8) {
                            Text("Size")
                            Slider(value: Binding(
                                get: { camera.effects.dustScale },
                                set: { v in updateEffects { $0.dustScale = v } }
                            ), in: 0.5...10)
                            .frame(maxWidth: 240)
                            Text(String(format: "×%.1f", camera.effects.dustScale))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 48, alignment: .trailing)
                        }
                        Text("Particles follow the performer's hands — pick a preset or any Particle Designer .pex.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .disabled(camera.sensorOnly)

                Section("Gesture GO") {
                    Toggle("Gesture GO", isOn: Binding(
                        get: { camera.effects.gestureGo },
                        set: { v in updateEffects { $0.gestureGo = v } }
                    ))
                    if camera.effects.gestureGo {
                        Picker("Gesture", selection: Binding(
                            get: { camera.effects.goGesture },
                            set: { g in updateEffects { $0.goGesture = g } }
                        )) {
                            ForEach(HandGesture.allCases, id: \.self) { gesture in
                                Text(gesture.label).tag(gesture)
                            }
                        }
                        .frame(maxWidth: 280)

                        HStack(spacing: 8) {
                            Text("Hold")
                            Slider(value: Binding(
                                get: { camera.effects.gestureHoldSeconds },
                                set: { v in updateEffects { $0.gestureHoldSeconds = v } }
                            ), in: 0.25...5, step: 0.25)
                            .frame(maxWidth: 240)
                            Text(String(format: "%.2f s", camera.effects.gestureHoldSeconds))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 56, alignment: .trailing)
                        }
                    }
                    Text("Experimental — fires GO when the chosen gesture is held to the camera for the configured warm-up time. Active in Show and Rehearsal modes.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .formStyle(.grouped)
            .padding(12)
        }
    }

    private func updateEffects(_ change: (inout CameraEffects) -> Void) {
        document.updateCue(cueID) { cue in
            if case .camera(var b) = cue.body {
                change(&b.effects)
                cue.body = .camera(b)
            }
        }
        app.pushEffects(cueID: cueID)
    }
}
