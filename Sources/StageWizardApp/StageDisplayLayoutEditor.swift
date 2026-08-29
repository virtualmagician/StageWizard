import SwiftUI

/// Display label for each stage-display pane — shared between the Settings
/// panel's checklist and the layout editor's canvas/checklist.
extension StageDisplayPaneKind {
    var label: String {
        switch self {
        case .clock: "Clock"
        case .showTimer: "Show timer"
        case .standingBy: "Standing by"
        case .notes: "Notes"
        case .running: "Running cues"
        case .program: "Program"
        }
    }
}

/// "Edit Layout…" sheet for the stage display (D13): a fixed 16:9 canvas
/// standing in for the display, with each ENABLED pane drawn as a labeled,
/// draggable, corner-resizable box — the same drag-to-move/corner-handles
/// interaction as the text-cue bounding-box editor (`StageEditorView` /
/// `BoxChromeView` in RichTextEditor.swift), reimplemented in plain SwiftUI
/// here since this sheet manages SIX simultaneous boxes with no inner
/// editable content to protect (unlike the text editor, nothing needs to
/// "fall through" a click to something underneath).
///
/// Every edit writes straight through `app.updateStageDisplay`, exactly
/// like every other stage-display control — the open stage display window
/// (if any) re-syncs and moves live as you drag.
struct StageDisplayLayoutEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(ShowDocumentController.self) private var document
    @Environment(\.dismiss) private var dismiss

    private var settings: StageDisplaySettings { document.show.settings.stageDisplay }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Stage Display Layout")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Reset Layout", action: resetLayout)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            HStack(alignment: .top, spacing: 16) {
                LayoutCanvas(panes: settings.panes) { kind, rect in
                    updatePane(kind) { $0.rect = rect }
                }
                .frame(width: 640, height: 360)
                .background(Theme.insetBackground, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(0.4), lineWidth: 1))

                paneChecklist
                    .frame(width: 180, alignment: .leading)
            }
            .padding()

            Spacer(minLength: 0)
        }
        .frame(width: 720, height: 460)
    }

    private var paneChecklist: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Panes")
                .font(.headline)
            ForEach(StageDisplayPaneKind.allCases, id: \.self) { kind in
                Toggle(kind.label, isOn: Binding(
                    get: { settings.pane(kind).enabled },
                    set: { v in updatePane(kind) { $0.enabled = v } }
                ))
            }
            Spacer()
            Text("Drag a box to move it; drag a corner to resize.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .toggleStyle(.checkbox)
    }

    private func updatePane(_ kind: StageDisplayPaneKind, _ change: (inout StageDisplayPane) -> Void) {
        app.updateStageDisplay { s in
            guard let idx = s.panes.firstIndex(where: { $0.kind == kind }) else { return }
            change(&s.panes[idx])
            // Read-then-write as SEPARATE statements (never `a[i].x = f(a[i])`
            // in one line — Swift exclusivity trap; see CLAUDE.md).
            let clampedRect = StageDisplayPane.clamped(s.panes[idx].rect)
            s.panes[idx].rect = clampedRect
        }
    }

    private func resetLayout() {
        app.updateStageDisplay { s in
            for idx in s.panes.indices {
                let defaultRect = StageDisplayPane.defaultRect(for: s.panes[idx].kind)
                s.panes[idx].rect = defaultRect
            }
        }
    }
}

/// The 16:9 canvas: black background, one `PaneBox` per ENABLED pane.
private struct LayoutCanvas: View {
    let panes: [StageDisplayPane]
    let onRectChanged: (StageDisplayPaneKind, StageRect) -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.black
                ForEach(panes.filter(\.enabled)) { pane in
                    PaneBox(pane: pane, canvasSize: geo.size) { newRect in
                        onRectChanged(pane.kind, newRect)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
    }
}

/// One draggable, corner-resizable box, positioned from `pane.rect`
/// (normalized, Y-DOWN — SwiftUI's own coordinate system already matches
/// this convention directly, no flip needed here unlike the AppKit program
/// layer). Dragging the body moves it; dragging a corner handle resizes
/// from that corner. Every drag reports through `onChange` pre-clamped via
/// `StageDisplayPane.clamped` — the same clamp/minimum-size rule enforced
/// on decode.
private struct PaneBox: View {
    let pane: StageDisplayPane
    let canvasSize: CGSize
    let onChange: (StageRect) -> Void

    @State private var dragStartRect: StageRect?

    private let handleSize: CGFloat = 10

    private var frame: CGRect {
        CGRect(
            x: pane.rect.x * canvasSize.width,
            y: pane.rect.y * canvasSize.height,
            width: pane.rect.width * canvasSize.width,
            height: pane.rect.height * canvasSize.height
        )
    }

    var body: some View {
        let boxFrame = frame
        ZStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(Theme.accent.opacity(0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                )
            Text(pane.kind.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .padding(4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: max(boxFrame.width, 4), height: max(boxFrame.height, 4))
        .position(x: boxFrame.midX, y: boxFrame.midY)
        .gesture(moveDrag)
        .overlay(handles(in: boxFrame))
        .help("Drag to move; drag a corner to resize")
    }

    private var moveDrag: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard canvasSize.width > 0, canvasSize.height > 0 else { return }
                let start = dragStartRect ?? pane.rect
                if dragStartRect == nil { dragStartRect = start }
                var rect = start
                rect.x = start.x + Double(value.translation.width / canvasSize.width)
                rect.y = start.y + Double(value.translation.height / canvasSize.height)
                onChange(StageDisplayPane.clamped(rect))
            }
            .onEnded { _ in dragStartRect = nil }
    }

    private enum Corner: CaseIterable {
        case topLeading, topTrailing, bottomLeading, bottomTrailing

        func point(in frame: CGRect) -> CGPoint {
            switch self {
            case .topLeading: CGPoint(x: frame.minX, y: frame.minY)
            case .topTrailing: CGPoint(x: frame.maxX, y: frame.minY)
            case .bottomLeading: CGPoint(x: frame.minX, y: frame.maxY)
            case .bottomTrailing: CGPoint(x: frame.maxX, y: frame.maxY)
            }
        }
    }

    @ViewBuilder
    private func handles(in boxFrame: CGRect) -> some View {
        ForEach(Corner.allCases, id: \.self) { corner in
            Rectangle()
                .fill(Theme.accent)
                .frame(width: handleSize, height: handleSize)
                .position(corner.point(in: boxFrame))
                .gesture(resizeDrag(corner: corner))
        }
    }

    private func resizeDrag(corner: Corner) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard canvasSize.width > 0, canvasSize.height > 0 else { return }
                let start = dragStartRect ?? pane.rect
                if dragStartRect == nil { dragStartRect = start }
                let dx = Double(value.translation.width / canvasSize.width)
                let dy = Double(value.translation.height / canvasSize.height)
                var rect = start
                switch corner {
                case .topLeading:
                    rect.x = start.x + dx
                    rect.width = start.width - dx
                    rect.y = start.y + dy
                    rect.height = start.height - dy
                case .topTrailing:
                    rect.width = start.width + dx
                    rect.y = start.y + dy
                    rect.height = start.height - dy
                case .bottomLeading:
                    rect.x = start.x + dx
                    rect.width = start.width - dx
                    rect.height = start.height + dy
                case .bottomTrailing:
                    rect.width = start.width + dx
                    rect.height = start.height + dy
                }
                onChange(StageDisplayPane.clamped(rect))
            }
            .onEnded { _ in dragStartRect = nil }
    }
}
