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
        case .gesture: "Gesture"
        }
    }
}

extension StageDisplayPane {
    /// D16: default rect for a NEWLY mirrored group's program pane — the
    /// base program rect (`defaultRect(for: .program)`), staggered by
    /// +0.03/+0.03 for each program pane already on the canvas so a second,
    /// third, etc. group checked in Settings doesn't land exactly on top of
    /// the one before it. The base program rect already sits close to the
    /// canvas's right edge, so vertical room governs when the stagger wraps
    /// back to the base offset (horizontal offset clamps flush against the
    /// edge once it runs out of room, same as any manual drag would) —
    /// `StageDisplayPane.clamped` (already applied to every rect) makes that
    /// clamping safe regardless. Deliberately NOT part of decode/
    /// `fillingMissing` — this only ever runs when the UI itself creates a
    /// brand-new pane.
    static func staggeredProgramRect(existingProgramPaneCount: Int) -> StageRect {
        let base = defaultRect(for: .program)
        let step = 0.03
        let maxSteps = max(1, Int(((1 - base.y - base.height) / step).rounded(.down)) + 1)
        let stepIndex = existingProgramPaneCount % maxSteps
        let offset = step * Double(stepIndex)
        var rect = base
        rect.x = base.x + offset
        rect.y = base.y + offset
        return clamped(rect)
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
                LayoutCanvas(panes: settings.panes, label: label(for:)) { paneID, rect in
                    updatePane(paneID) { $0.rect = rect }
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
            ForEach(StageDisplayPaneKind.allCases.filter { $0 != .program }, id: \.self) { kind in
                Toggle(kind.label, isOn: Binding(
                    get: { settings.pane(kind).enabled },
                    set: { v in updatePane(kind.rawValue) { $0.enabled = v } }
                ))
            }
            if !settings.programPanes.isEmpty {
                Divider()
                // D16: one row per group currently mirrored, added/removed
                // from the Settings panel's "Mirror on stage display"
                // checklist — this toggle only shows/hides an existing pane,
                // matching every other kind's toggle above.
                ForEach(settings.programPanes) { pane in
                    Toggle(label(for: pane), isOn: Binding(
                        get: { pane.enabled },
                        set: { v in updatePane(pane.id) { $0.enabled = v } }
                    ))
                }
            }
            Spacer()
            Text("Drag a box to move it; drag a corner to resize.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .toggleStyle(.checkbox)
    }

    /// Display label for one pane's box/checklist row — the group's name for
    /// a program pane (D16: there can be several, so "Program" alone would
    /// no longer distinguish them), the kind's label for everything else.
    private func label(for pane: StageDisplayPane) -> String {
        guard pane.kind == .program else { return pane.kind.label }
        guard let groupID = pane.programGroupID,
              let group = document.show.settings.outputGroups.first(where: { $0.id == groupID }) else {
            return "Program · (deleted)"
        }
        return "Program · \(group.name)"
    }

    private func updatePane(_ paneID: String, _ change: (inout StageDisplayPane) -> Void) {
        app.updateStageDisplay { s in
            guard let idx = s.panes.firstIndex(where: { $0.id == paneID }) else { return }
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
    let label: (StageDisplayPane) -> String
    let onRectChanged: (String, StageRect) -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.black
                ForEach(panes.filter(\.enabled)) { pane in
                    PaneBox(pane: pane, label: label(pane), canvasSize: geo.size) { newRect in
                        onRectChanged(pane.id, newRect)
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
    /// D16: the group's name for a program pane (there can be several),
    /// the kind's label for everything else — resolved by the caller since
    /// only it has access to the show's output groups.
    let label: String
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
            Text(label)
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
