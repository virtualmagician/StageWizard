import SwiftUI

/// Geometry inspector tab for video and camera cues: Fill Stage (the whole
/// output, per fill mode) or Custom (position + scale of the aspect-fit image,
/// in stage-relative units). Edits push LIVE to running instances — position
/// against the real stage or a rehearsal preview and watch it move.
struct GeometryTab: View {
    @Environment(ShowDocumentController.self) private var document
    @Environment(AppModel.self) private var app
    let cueID: UUID

    @State private var uniformScale = true

    var body: some View {
        if let cue = document.cue(withID: cueID), let geometry = currentGeometry(cue) {
            HStack(alignment: .top, spacing: 16) {
                Form {
                    Picker("Mode", selection: Binding(
                        get: { geometry.mode },
                        set: { newMode in update { $0.mode = newMode } }
                    )) {
                        Text("Fill Stage").tag(VideoGeometry.Mode.fillStage)
                        Text("Custom").tag(VideoGeometry.Mode.custom)
                    }
                    .frame(width: 240)

                    if geometry.mode == .fillStage {
                        Picker("Style", selection: fillModeBinding(cue)) {
                            Text("Fit").tag(FillMode.fit)
                            Text("Fill").tag(FillMode.fill)
                            Text("Stretch").tag(FillMode.stretch)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 240)
                    } else {
                        percentField("X", value: geometry.x) { v in update { $0.x = v } }
                        percentField("Y", value: geometry.y) { v in update { $0.y = v } }
                        HStack(spacing: 8) {
                            percentField("Scale X", value: geometry.scaleX) { v in
                                update {
                                    $0.scaleX = max(v, 0.01)
                                    if uniformScale { $0.scaleY = max(v, 0.01) }
                                }
                            }
                            Button {
                                uniformScale.toggle()
                                if uniformScale { update { $0.scaleY = $0.scaleX } }
                            } label: {
                                Image(systemName: uniformScale ? "lock.fill" : "lock.open")
                            }
                            .buttonStyle(.plain)
                            .help(uniformScale ? "Scale X and Y together" : "Scale X and Y independently")
                        }
                        percentField("Scale Y", value: geometry.scaleY) { v in
                            update {
                                $0.scaleY = max(v, 0.01)
                                if uniformScale { $0.scaleX = max(v, 0.01) }
                            }
                        }
                        .disabled(uniformScale)
                        Button("Reset") {
                            update { g in
                                g.x = 0; g.y = 0; g.scaleX = 1; g.scaleY = 1
                            }
                        }
                    }
                }
                .formStyle(.columns)
                .frame(width: 300)
                .disabled(app.isShowMode)

                if geometry.mode == .custom {
                    StageCanvas(cueID: cueID, geometry: geometry, locked: app.isShowMode) { newX, newY in
                        update { $0.x = newX; $0.y = newY }
                    }
                    .frame(minWidth: 260, maxWidth: .infinity, minHeight: 150, maxHeight: 220)
                }
            }
            .padding(12)
        }
    }

    /// Percent field over a stage-relative fraction (X/Y: 0 % = centered;
    /// scale: 100 % = aspect-fit size).
    private func percentField(_ label: String, value: Double, set: @escaping (Double) -> Void) -> some View {
        HStack {
            Text(label)
            TextField("", value: Binding(
                get: { value * 100 },
                set: { set($0 / 100) }
            ), format: .number.precision(.fractionLength(1)))
            .textFieldStyle(.roundedBorder)
            .frame(width: 80)
            .multilineTextAlignment(.trailing)
            Text("%")
                .foregroundStyle(.secondary)
        }
    }

    private func currentGeometry(_ cue: Cue) -> VideoGeometry? {
        switch cue.body {
        case .video(let body): return body.geometry
        case .camera(let body): return body.geometry
        default: return nil
        }
    }

    private func fillModeBinding(_ cue: Cue) -> Binding<FillMode> {
        Binding(
            get: {
                switch document.cue(withID: cueID)?.body {
                case .video(let body): body.fillMode
                case .camera(let body): body.fillMode
                default: .fit
                }
            },
            set: { newValue in
                document.updateCue(cueID) { cue in
                    switch cue.body {
                    case .video(var body): body.fillMode = newValue; cue.body = .video(body)
                    case .camera(var body): body.fillMode = newValue; cue.body = .camera(body)
                    default: break
                    }
                }
                app.pushGeometry(cueID: cueID)
            }
        )
    }

    private func update(_ change: (inout VideoGeometry) -> Void) {
        document.updateCue(cueID) { cue in
            switch cue.body {
            case .video(var body): change(&body.geometry); cue.body = .video(body)
            case .camera(var body): change(&body.geometry); cue.body = .camera(body)
            default: break
            }
        }
        app.pushGeometry(cueID: cueID)
    }
}

/// Mini stage: a 16:9 stage rectangle with the media rect drawn at its
/// computed position — drag the rect to set X/Y.
private struct StageCanvas: View {
    @Environment(ShowDocumentController.self) private var document
    let cueID: UUID
    let geometry: VideoGeometry
    let locked: Bool
    let onMove: (Double, Double) -> Void

    @State private var dragStart: (x: Double, y: Double)?

    var body: some View {
        GeometryReader { geo in
            let stage = fittedStage(in: geo.size)
            ZStack {
                // Stage
                Rectangle()
                    .fill(Theme.insetBackground)
                    .overlay(Rectangle().strokeBorder(.secondary.opacity(0.5), lineWidth: 1))
                    .frame(width: stage.width, height: stage.height)

                // Media rect (aspect-fit base × scale, offset by x/y; canvas y is flipped vs stage +y-up)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.hold.opacity(0.45))
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .strokeBorder(Theme.hold, lineWidth: 1.5)
                    )
                    .overlay(
                        Image(systemName: "play.rectangle")
                            .foregroundStyle(.white.opacity(0.8))
                    )
                    .frame(
                        width: max(stage.width * geometry.scaleX, 8),
                        height: max(stage.height * geometry.scaleY, 8)
                    )
                    .offset(
                        x: geometry.x * stage.width,
                        y: -geometry.y * stage.height
                    )
                    .gesture(locked ? nil : drag(stage: stage))
                    .help(locked ? "Unlock Edit mode to move" : "Drag to position the media on the stage")
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Theme.listBackground, in: RoundedRectangle(cornerRadius: 6))
    }

    private func fittedStage(in size: CGSize) -> CGSize {
        let aspect: CGFloat = 16.0 / 9.0
        let width = min(size.width - 16, (size.height - 16) * aspect)
        return CGSize(width: max(width, 40), height: max(width / aspect, 22))
    }

    private func drag(stage: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = dragStart ?? (geometry.x, geometry.y)
                if dragStart == nil { dragStart = start }
                let newX = start.x + Double(value.translation.width / stage.width)
                let newY = start.y - Double(value.translation.height / stage.height)
                // Snap to 0.5 % steps; clamp to ±150 % so it can't get lost.
                onMove(
                    min(max((newX * 200).rounded() / 200, -1.5), 1.5),
                    min(max((newY * 200).rounded() / 200, -1.5), 1.5)
                )
            }
            .onEnded { _ in dragStart = nil }
    }
}
