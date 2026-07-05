import SwiftUI

/// Timeline editor for group cues: each child is a bar on a time
/// ruler; dragging a bar sets its start offset within the group. Audio bars
/// render their waveform. Fire-all groups show the mode picker + explainer.
struct GroupTimelineTab: View {
    @Environment(ShowDocumentController.self) private var document
    @Environment(AppModel.self) private var app
    let cueID: UUID

    @State private var zoom: Double = 1.0

    var body: some View {
        if let cue = document.cue(withID: cueID), case .group(let group) = cue.body {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 16) {
                    Picker("Mode", selection: Binding(
                        get: { group.mode },
                        set: { mode in update { $0.mode = mode } }
                    )) {
                        Text("Start all together").tag(GroupMode.fireAll)
                        Text("Timeline").tag(GroupMode.timeline)
                        Text("Enter and play first cue").tag(GroupMode.enterAndPlayFirst)
                    }
                    .frame(width: 320)
                    .disabled(app.isShowMode)

                    if group.mode == .timeline {
                        Spacer()
                        Slider(value: $zoom, in: 1...8) {
                            Text("Zoom")
                        } minimumValueLabel: {
                            Image(systemName: "minus.magnifyingglass")
                        } maximumValueLabel: {
                            Image(systemName: "plus.magnifyingglass")
                        }
                        .frame(width: 200)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)

                switch group.mode {
                case .fireAll:
                    Text("All children start the moment the group fires. Switch to Timeline to stagger them by dragging bars.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                case .enterAndPlayFirst:
                    Text("GO on this group plays the first child and steps the playhead inside — each further GO advances to the next child, then exits past the group. Slide decks import this way.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                case .timeline:
                    TimelineEditor(groupID: cueID, group: group, zoom: zoom)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func update(_ change: (inout GroupBody) -> Void) {
        document.updateCue(cueID) { cue in
            if case .group(var body) = cue.body {
                change(&body)
                cue.body = .group(body)
            }
        }
    }
}

// MARK: - Timeline surface

private struct TimelineEditor: View {
    @Environment(ShowDocumentController.self) private var document
    @Environment(AppModel.self) private var app
    let groupID: UUID
    let group: GroupBody
    let zoom: Double

    private let rowHeight: CGFloat = 40
    private let labelHeight: CGFloat = 16

    private var children: [Cue] {
        document.show.children(of: groupID)
    }

    /// Timeline span: longest child end (offset + preWait + duration), padded,
    /// never shorter than 10 s so an empty group still shows a ruler.
    private var totalSeconds: TimeInterval {
        var longest: TimeInterval = 0
        for child in children {
            let duration = DurationCache.shared.effectiveDuration(
                of: child, in: document.show, showFolder: document.showFolder
            ) ?? 10
            longest = max(longest, group.offset(for: child.id) + child.preWait + duration)
        }
        return max(longest * 1.08, 10)
    }

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width * zoom, 100)
            let scale = width / totalSeconds   // px per second
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    TimeRuler(totalSeconds: totalSeconds, scale: scale)
                        .frame(width: width, height: 22)
                    ForEach(children) { child in
                        TimelineRow(
                            groupID: groupID,
                            child: child,
                            offset: group.offset(for: child.id),
                            scale: scale,
                            rowHeight: rowHeight,
                            locked: app.isShowMode
                        )
                        // .leading is load-bearing: the default center alignment
                        // would drift each bar right by half its free space,
                        // breaking the shared t=0 origin.
                        .frame(width: width, height: rowHeight + labelHeight, alignment: .leading)
                    }
                }
                .padding(.bottom, 8)
            }
            .background(Theme.insetBackground)
        }
        .padding(.horizontal, 12)
    }
}

/// Ruler with "nice" tick spacing for the current scale.
private struct TimeRuler: View {
    let totalSeconds: TimeInterval
    let scale: CGFloat

    private var tickInterval: TimeInterval {
        // Aim for a label roughly every 80 px.
        let target = 80 / scale
        for candidate: TimeInterval in [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300] where candidate >= target {
            return candidate
        }
        return 600
    }

    var body: some View {
        Canvas { context, size in
            let interval = tickInterval
            var t: TimeInterval = 0
            while t <= totalSeconds {
                let x = CGFloat(t) * scale
                var line = Path()
                line.move(to: CGPoint(x: x, y: size.height - 6))
                line.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(line, with: .color(.secondary.opacity(0.7)), lineWidth: 1)
                context.draw(
                    Text(Timecode.format(t, showFraction: interval < 1))
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.secondary),
                    at: CGPoint(x: x + 3, y: size.height - 14),
                    anchor: .leading
                )
                t += interval
            }
            var base = Path()
            base.move(to: CGPoint(x: 0, y: size.height - 0.5))
            base.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
            context.stroke(base, with: .color(.secondary.opacity(0.4)), lineWidth: 1)
        }
    }
}

/// One child cue as a draggable bar. The drag moves a local preview offset;
/// the model is written once on release (single undo-worthy mutation).
private struct TimelineRow: View {
    @Environment(ShowDocumentController.self) private var document
    let groupID: UUID
    let child: Cue
    let offset: TimeInterval
    let scale: CGFloat
    let rowHeight: CGFloat
    let locked: Bool

    @State private var dragOffset: TimeInterval?
    @State private var waveform: WaveformData?

    private var displayedOffset: TimeInterval { dragOffset ?? offset }

    private var duration: TimeInterval {
        DurationCache.shared.effectiveDuration(
            of: child, in: document.show, showFolder: document.showFolder
        ) ?? 5
    }

    var body: some View {
        let barX = CGFloat(displayedOffset) * scale
        let barWidth = max(CGFloat(duration) * scale, 26)

        VStack(alignment: .leading, spacing: 1) {
            // Floating label just above the bar.
            HStack(spacing: 4) {
                Image(systemName: typeSymbol(child.body))
                    .font(.system(size: 8))
                Text("\(child.number) · \(child.displayName)")
                    .font(.caption2)
                    .lineLimit(1)
                Text(Timecode.format(displayedOffset))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(dragOffset != nil ? Theme.standby : .secondary)
            }
            .padding(.leading, barX + 2)

            bar
                .frame(width: barWidth, height: rowHeight - 6)
                .offset(x: barX)
                .gesture(locked ? nil : dragGesture)
                .help(locked ? "Unlock Edit mode to move" : "Drag to set this cue's start offset in the group")
        }
        .task(id: mediaURL) {
            waveform = nil
            if let mediaURL, case .audio = child.body {
                waveform = try? await WaveformData.load(url: mediaURL, buckets: 400)
            }
        }
    }

    private var bar: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(barColor.opacity(0.35))
            if let waveform {
                WaveformShape(data: waveform)
                    .fill(.white.opacity(0.55))
                    .padding(.vertical, 2)
            }
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(barColor, lineWidth: dragOffset != nil ? 2 : 1)
        }
        .contentShape(Rectangle())
    }

    private var barColor: Color {
        tagColor(child.colorTag) ?? (isAudio ? Theme.standby : Theme.hold)
    }

    private var isAudio: Bool {
        if case .audio = child.body { return true }
        return false
    }

    private var mediaURL: URL? {
        switch child.body {
        case .audio(let body): return body.media.resolve(showFolder: document.showFolder)
        case .video(let body): return body.media.resolve(showFolder: document.showFolder)
        default: return nil
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let delta = TimeInterval(value.translation.width / scale)
                // Snap to 50 ms — fine enough for stage sync, coarse enough to land on round numbers.
                let raw = max(0, offset + delta)
                dragOffset = (raw * 20).rounded() / 20
            }
            .onEnded { _ in
                guard let final = dragOffset else { return }
                document.updateCue(groupID) { cue in
                    if case .group(var body) = cue.body {
                        body.childOffsets[child.id] = final
                        cue.body = .group(body)
                    }
                }
                dragOffset = nil
            }
    }
}
