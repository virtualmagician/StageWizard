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
    /// D24: pure geometry for a "clean" multiview grid — replaces the old
    /// blind-overlap defaults/"Reset Layout" behavior after Marco flagged
    /// (from screenshots) that resetting produced a messy overlapping
    /// arrangement instead of something usable. Three fixed bands on the
    /// 16:9 canvas:
    ///
    /// - TOP STRIP (y 0.02, h 0.12): clock (left) — standing-by (center,
    ///   flexible) — show timer (right). An absent clock/timer lets
    ///   standing-by widen to fill the space it would have occupied.
    /// - CENTER REGION (y 0.16...0.66): every program pane, tiled
    ///   edge-to-edge in a grid sized for the count (1 / 1×2 / 2×2 / 2×3 for
    ///   1 / 2 / 3-4 / 5-6 panes), h==w per tile (the program h==w lock),
    ///   the whole grid block centered horizontally. Capped at 6 shown —
    ///   see `multiviewCenterCellRect`'s doc for what happens beyond that.
    /// - BOTTOM STRIP (y 0.70, h 0.28): notes | running | gesture, in that
    ///   order, ENABLED ones only, splitting the width evenly.
    ///
    /// Lays out ONLY the panes described by `enabledKinds` (never
    /// `.program` — program panes are described separately by
    /// `programGroupIDs`, one entry per currently-mirrored group) and
    /// `programGroupIDs`. Callers (`StageDisplayLayoutEditor.resetLayout`,
    /// the authoritative use) are responsible for leaving every OTHER
    /// (disabled) pane's rect untouched — this function has no notion of
    /// "disabled", it only ever produces rects for what it's told is
    /// enabled. Every returned rect is already `clamped` — safe to write
    /// straight onto a `StageDisplayPane.rect` with no second clamp pass.
    static func multiviewLayout(enabledKinds: [StageDisplayPaneKind], programGroupIDs: [UUID]) -> [StageDisplayPane] {
        let enabled = Set(enabledKinds)
        var result: [StageDisplayPane] = []

        // Top strip.
        let topY = 0.02, topHeight = 0.12
        let hasClock = enabled.contains(.clock)
        let hasTimer = enabled.contains(.showTimer)
        if hasClock {
            result.append(laidOutPane(.clock, StageRect(x: 0.02, y: topY, width: 0.20, height: topHeight)))
        }
        if hasTimer {
            result.append(laidOutPane(.showTimer, StageRect(x: 0.78, y: topY, width: 0.20, height: topHeight)))
        }
        if enabled.contains(.standingBy) {
            let left = hasClock ? 0.24 : 0.02
            let right = hasTimer ? 0.74 : 0.98
            result.append(laidOutPane(.standingBy, StageRect(x: left, y: topY, width: max(0, right - left), height: topHeight)))
        }

        // Center region: one program tile per mirrored group.
        for (index, groupID) in programGroupIDs.enumerated() {
            let rect = multiviewCenterCellRect(index: index, ofCount: programGroupIDs.count)
            result.append(StageDisplayPane(kind: .program, enabled: true, rect: rect, programGroupID: groupID))
        }

        // Bottom strip: notes | running | gesture, enabled-only, even split.
        let bottomKinds: [StageDisplayPaneKind] = [.notes, .running, .gesture].filter(enabled.contains)
        if !bottomKinds.isEmpty {
            let y = 0.70, height = 0.28, gutter = 0.015, margin = 0.02
            let available = 1 - margin * 2
            let cellWidth = (available - gutter * Double(bottomKinds.count - 1)) / Double(bottomKinds.count)
            for (index, kind) in bottomKinds.enumerated() {
                let x = margin + Double(index) * (cellWidth + gutter)
                result.append(laidOutPane(kind, StageRect(x: x, y: y, width: cellWidth, height: height)))
            }
        }

        return result
    }

    private static func laidOutPane(_ kind: StageDisplayPaneKind, _ rect: StageRect) -> StageDisplayPane {
        StageDisplayPane(kind: kind, enabled: true, rect: rect)
    }

    /// D24: the geometry of ONE cell in the multiview center-region program
    /// grid sized for `count` total tiles — factored out of
    /// `multiviewLayout` so `SettingsPanelView.setGroupMirrored` can give a
    /// newly-mirrored group's pane the slot it would occupy in a freshly
    /// reset layout (a closer first guess than the old diagonal stagger)
    /// WITHOUT moving any already-placed program pane — moving panes the
    /// operator already positioned as a side effect of checking a box would
    /// be more surprising than helpful; "Reset Layout" (this file's actual
    /// fix) is the authoritative way to get the full clean grid.
    ///
    /// Grid shape by count: 1 → 1×1, 2 → 1×2, 3-4 → 2×2, 5-6 → 2×3, capped
    /// at 6 cells. `index` beyond the 6th cell (a 7th+ mirrored group) stacks
    /// at the last cell, offset a little further per extra pane — same idea
    /// as the old stagger, just as a fallback for the rare overflow case
    /// rather than the common one.
    static func multiviewCenterCellRect(index: Int, ofCount count: Int) -> StageRect {
        guard count > 0 else { return defaultRect(for: .program) }
        let shownCount = min(count, 6)
        let (rows, cols) = centerGridDimensions(forCount: shownCount)

        let regionY = 0.16, regionHeight = 0.50
        let margin = 0.02, gutter = 0.015
        let availableWidth = 1 - margin * 2
        let cellFromWidth = (availableWidth - gutter * Double(cols - 1)) / Double(cols)
        let cellFromHeight = (regionHeight - gutter * Double(rows - 1)) / Double(rows)
        let cell = min(cellFromWidth, cellFromHeight)

        let blockWidth = Double(cols) * cell + gutter * Double(cols - 1)
        let blockHeight = Double(rows) * cell + gutter * Double(rows - 1)
        let blockX = (1 - blockWidth) / 2
        let blockY = regionY + (regionHeight - blockHeight) / 2

        let shownIndex = min(index, shownCount - 1)
        let row = shownIndex / cols
        let col = shownIndex % cols
        let baseX = blockX + Double(col) * (cell + gutter)
        let baseY = blockY + Double(row) * (cell + gutter)

        // Overflow beyond the 6 shown cells: stack at the last cell, offset
        // a little further per extra pane so each is at least individually
        // reachable in the editor rather than perfectly hidden underneath
        // one another.
        let overflowSteps = max(0, index - (shownCount - 1))
        let step = 0.03
        let rect = StageRect(
            x: baseX + step * Double(overflowSteps),
            y: baseY + step * Double(overflowSteps),
            width: cell, height: cell
        )
        return clamped(rect, lockToSquare: true)
    }

    private static func centerGridDimensions(forCount count: Int) -> (rows: Int, cols: Int) {
        switch count {
        case ...1: return (1, 1)
        case 2: return (1, 2)
        case 3, 4: return (2, 2)
        default: return (2, 3)   // 5...6
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
            let isProgram = s.panes[idx].kind == .program
            let clampedRect = StageDisplayPane.clamped(s.panes[idx].rect, lockToSquare: isProgram)
            s.panes[idx].rect = clampedRect
        }
    }

    /// D24: rebuilds a clean, non-overlapping multiview grid from the
    /// CURRENTLY enabled panes + mirrored program groups
    /// (`StageDisplayPane.multiviewLayout`) — replaces the old behavior of
    /// resetting every pane (enabled or not) to its lone `defaultRect`,
    /// which is exactly what produced the messy overlapping arrangement
    /// Marco flagged from screenshots (multiple default rects were never
    /// designed to coexist as a set — they were per-kind starting points
    /// for a single pane each, not a coordinated layout). A DISABLED pane's
    /// rect is left exactly where it was — only enabled panes are re-laid.
    private func resetLayout() {
        app.updateStageDisplay { s in
            let enabledKinds = StageDisplayPaneKind.allCases
                .filter { $0 != .program }
                .filter { s.pane($0).enabled }
            let programGroupIDs = s.programPanes.filter(\.enabled).compactMap(\.programGroupID)
            let laidOut = StageDisplayPane.multiviewLayout(enabledKinds: enabledKinds, programGroupIDs: programGroupIDs)
            for pane in laidOut {
                guard let idx = s.panes.firstIndex(where: { $0.id == pane.id }) else { continue }
                s.panes[idx].rect = pane.rect
            }
        }
    }
}

/// The 16:9 canvas: black background, one `PaneBox` per ENABLED pane, plus
/// (D20) momentary alignment guide lines while any box is being dragged.
private struct LayoutCanvas: View {
    let panes: [StageDisplayPane]
    let label: (StageDisplayPane) -> String
    let onRectChanged: (String, StageRect) -> Void

    /// D20: raised by whichever `PaneBox` is currently mid-drag, consumed by
    /// `SnapGuideLines` below it — lives HERE (not inside a single `PaneBox`)
    /// because the guide lines must be drawn ABOVE every box, spanning the
    /// whole canvas, not clipped to the dragging box's own small frame.
    @State private var activeGuides: [LayoutSnapping.Guide] = []

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.black
                ForEach(panes.filter(\.enabled)) { pane in
                    PaneBox(
                        pane: pane,
                        label: label(pane),
                        canvasSize: geo.size,
                        others: Self.canvasFrames(for: panes, excluding: pane.id, canvasSize: geo.size),
                        onChange: { newRect in onRectChanged(pane.id, newRect) },
                        onGuidesChanged: { guides in activeGuides = guides }
                    )
                }
                SnapGuideLines(guides: activeGuides, canvasSize: geo.size)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
    }

    /// Every OTHER enabled pane's frame, in canvas-space points — the
    /// snap targets for the pane identified by `id`.
    private static func canvasFrames(for panes: [StageDisplayPane], excluding id: String, canvasSize: CGSize) -> [CGRect] {
        panes.filter { $0.enabled && $0.id != id }.map { PaneBox.canvasFrame(for: $0.rect, canvasSize: canvasSize) }
    }
}

/// D20: momentary accent hairlines drawn across the whole canvas while a
/// drag/resize snap is engaged — purely visual feedback, never hit-tested.
private struct SnapGuideLines: View {
    let guides: [LayoutSnapping.Guide]
    let canvasSize: CGSize

    var body: some View {
        ForEach(Array(guides.enumerated()), id: \.offset) { _, guide in
            switch guide {
            case .vertical(let x):
                Rectangle()
                    .fill(Theme.accent)
                    .frame(width: 1, height: canvasSize.height)
                    .position(x: x, y: canvasSize.height / 2)
            case .horizontal(let y):
                Rectangle()
                    .fill(Theme.accent)
                    .frame(width: canvasSize.width, height: 1)
                    .position(x: canvasSize.width / 2, y: y)
            }
        }
        .allowsHitTesting(false)
    }
}

/// D20: pure snap-resolution for the layout editor's drag/resize gestures.
/// Operates entirely in CANVAS-SPACE POINTS — the same coordinate space
/// `PaneBox.frame`/`LayoutCanvas`'s `GeometryReader` use, NOT the normalized
/// 0...1 `StageRect` space the model stores — because `tolerance` is a fixed
/// point distance (~6pt) that would be meaningless normalized.
///
/// Snaps `rect` to whichever of the canvas edges, the canvas center lines, or
/// `others`' edges/centers is CLOSEST on each axis independently, translating
/// `rect` along that axis by the found offset. Passing a pane's own full
/// canvas frame implements a MOVE snap (every edge moves together, since
/// translating preserves width/height). Passing a single dragged corner as a
/// ZERO-SIZE point rect implements a RESIZE-edge snap: only that corner
/// "moves" (minX == midX == maxX for a point, so exactly one coordinate is
/// checked), and the caller reconstructs the final box from the snapped
/// point plus the resize's fixed anchor corner — see `PaneBox.resizeDrag`.
/// Pure and directly testable — no view/gesture state involved.
enum LayoutSnapping {
    /// One momentary alignment guide line, in canvas-space points.
    enum Guide: Hashable {
        case vertical(CGFloat)     // an x position — draw a full-height line there
        case horizontal(CGFloat)   // a y position — draw a full-width line there
    }

    static func snap(rect: CGRect, others: [CGRect], canvas: CGSize, tolerance: CGFloat) -> (rect: CGRect, guides: [Guide]) {
        var xCandidates: [CGFloat] = [0, canvas.width / 2, canvas.width]
        var yCandidates: [CGFloat] = [0, canvas.height / 2, canvas.height]
        for other in others {
            xCandidates.append(contentsOf: [other.minX, other.midX, other.maxX])
            yCandidates.append(contentsOf: [other.minY, other.midY, other.maxY])
        }

        var result = rect
        var guides: [Guide] = []

        if let (offset, line) = closestSnap(edges: [rect.minX, rect.midX, rect.maxX], candidates: xCandidates, tolerance: tolerance) {
            result.origin.x += offset
            guides.append(.vertical(line))
        }
        if let (offset, line) = closestSnap(edges: [rect.minY, rect.midY, rect.maxY], candidates: yCandidates, tolerance: tolerance) {
            result.origin.y += offset
            guides.append(.horizontal(line))
        }
        return (result, guides)
    }

    /// The smallest-magnitude offset that brings ANY of `edges` to exactly
    /// ANY `candidate` within `tolerance`; nil if none is close enough.
    private static func closestSnap(edges: [CGFloat], candidates: [CGFloat], tolerance: CGFloat) -> (offset: CGFloat, line: CGFloat)? {
        var best: (offset: CGFloat, distance: CGFloat, line: CGFloat)?
        for edge in edges {
            for candidate in candidates {
                let distance = abs(candidate - edge)
                guard distance <= tolerance else { continue }
                if best == nil || distance < best!.distance {
                    best = (candidate - edge, distance, candidate)
                }
            }
        }
        return best.map { (offset: $0.offset, line: $0.line) }
    }
}

/// One draggable, corner-resizable box, positioned from `pane.rect`
/// (normalized, Y-DOWN — SwiftUI's own coordinate system already matches
/// this convention directly, no flip needed here unlike the AppKit program
/// layer). Dragging the body moves it; dragging a corner handle resizes
/// from that corner — except for a PROGRAM pane (D20), which locks to 16:9
/// (normalized height == width on this 16:9 canvas — see
/// `StageDisplayPane.clamped(_:lockToSquare:)`): width drives height, and
/// the corner diagonally opposite the one being dragged never moves. Every
/// drag also snaps to canvas edges/center lines and other enabled panes'
/// edges/centers (D20, `LayoutSnapping`) before reporting through `onChange`,
/// pre-clamped via `StageDisplayPane.clamped` — the same clamp/minimum-size
/// rule enforced on decode.
private struct PaneBox: View {
    let pane: StageDisplayPane
    /// D16: the group's name for a program pane (there can be several),
    /// the kind's label for everything else — resolved by the caller since
    /// only it has access to the show's output groups.
    let label: String
    let canvasSize: CGSize
    /// D20: every OTHER enabled pane's frame, in canvas-space points — snap
    /// targets for both the move and resize gestures below.
    let others: [CGRect]
    let onChange: (StageRect) -> Void
    /// D20: fired with the alignment guides currently engaged (empty when
    /// none) — the caller (`LayoutCanvas`) draws them above every box.
    let onGuidesChanged: ([LayoutSnapping.Guide]) -> Void

    @State private var dragStartRect: StageRect?
    @State private var isInteracting = false

    private let handleSize: CGFloat = 10
    private static let snapTolerance: CGFloat = 6

    private var isProgram: Bool { pane.kind == .program }

    private var frame: CGRect { Self.canvasFrame(for: pane.rect, canvasSize: canvasSize) }

    /// Canvas-space (points) frame for a normalized rect — shared with
    /// `LayoutCanvas` (to compute `others`), so `fileprivate`.
    fileprivate static func canvasFrame(for rect: StageRect, canvasSize: CGSize) -> CGRect {
        CGRect(
            x: rect.x * canvasSize.width,
            y: rect.y * canvasSize.height,
            width: rect.width * canvasSize.width,
            height: rect.height * canvasSize.height
        )
    }

    private func normalizedRect(fromCanvas canvasRect: CGRect) -> StageRect {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return pane.rect }
        return StageRect(
            x: canvasRect.minX / canvasSize.width,
            y: canvasRect.minY / canvasSize.height,
            width: canvasRect.width / canvasSize.width,
            height: canvasRect.height / canvasSize.height
        )
    }

    var body: some View {
        let boxFrame = frame
        ZStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(Theme.accent.opacity(isInteracting ? 0.26 : 0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(Theme.accent.opacity(isInteracting ? 1 : 0.7), lineWidth: isInteracting ? 2 : 1)
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
                if dragStartRect == nil { dragStartRect = start; isInteracting = true }
                var rect = start
                rect.x = start.x + Double(value.translation.width / canvasSize.width)
                rect.y = start.y + Double(value.translation.height / canvasSize.height)
                let candidate = StageDisplayPane.clamped(rect, lockToSquare: isProgram)
                let canvasCandidate = Self.canvasFrame(for: candidate, canvasSize: canvasSize)
                let snapped = LayoutSnapping.snap(
                    rect: canvasCandidate, others: others, canvas: canvasSize, tolerance: Self.snapTolerance
                )
                onGuidesChanged(snapped.guides)
                onChange(StageDisplayPane.clamped(normalizedRect(fromCanvas: snapped.rect), lockToSquare: isProgram))
            }
            .onEnded { _ in
                dragStartRect = nil
                isInteracting = false
                onGuidesChanged([])
            }
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

        /// The corner diagonally opposite this one — the fixed anchor a
        /// resize drag from THIS corner never moves.
        var opposite: Corner {
            switch self {
            case .topLeading: .bottomTrailing
            case .topTrailing: .bottomLeading
            case .bottomLeading: .topTrailing
            case .bottomTrailing: .topLeading
            }
        }
    }

    /// Rebuilds a canvas-space rect from a fixed `anchor` point (the corner
    /// OPPOSITE `draggedCorner`) plus a size — the inverse of
    /// `draggedCorner.point(in:)`/`draggedCorner.opposite.point(in:)`.
    private static func boxFrame(anchor: CGPoint, draggedCorner: Corner, width: CGFloat, height: CGFloat) -> CGRect {
        switch draggedCorner {
        case .topLeading: CGRect(x: anchor.x - width, y: anchor.y - height, width: width, height: height)
        case .topTrailing: CGRect(x: anchor.x, y: anchor.y - height, width: width, height: height)
        case .bottomLeading: CGRect(x: anchor.x - width, y: anchor.y, width: width, height: height)
        case .bottomTrailing: CGRect(x: anchor.x, y: anchor.y, width: width, height: height)
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
                if dragStartRect == nil { dragStartRect = start; isInteracting = true }
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

                // D20: `clamped(_:lockToSquare:)` derives height from width
                // for a PROGRAM pane — width authoritative, so a corner drag
                // adjusts both coherently; every other kind is untouched.
                let candidate = StageDisplayPane.clamped(rect, lockToSquare: isProgram)
                let canvasCandidate = Self.canvasFrame(for: candidate, canvasSize: canvasSize)
                let anchor = corner.opposite.point(in: canvasCandidate)

                // Resize-edge snap: snap only the dragged CORNER POINT (as a
                // zero-size probe rect) so the opposite anchor corner never
                // moves — see `LayoutSnapping`'s doc comment.
                let draggedPoint = corner.point(in: canvasCandidate)
                let snapped = LayoutSnapping.snap(
                    rect: CGRect(origin: draggedPoint, size: .zero),
                    others: others, canvas: canvasSize, tolerance: Self.snapTolerance
                )
                onGuidesChanged(snapped.guides)

                let width = abs(snapped.rect.origin.x - anchor.x)
                let height = isProgram ? width : abs(snapped.rect.origin.y - anchor.y)
                let snappedCanvasRect = Self.boxFrame(anchor: anchor, draggedCorner: corner, width: width, height: height)

                onChange(StageDisplayPane.clamped(normalizedRect(fromCanvas: snappedCanvasRect), lockToSquare: isProgram))
            }
            .onEnded { _ in
                dragStartRect = nil
                isInteracting = false
                onGuidesChanged([])
            }
    }
}
