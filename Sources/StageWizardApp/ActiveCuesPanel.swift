import SwiftUI

/// Side panel showing every running/paused/holding cue instance with progress
/// and per-instance transport. Progress redraws on a 10 Hz timeline — no
/// per-frame player observation.
struct ActiveCuesPanel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("In Progress")
                    .font(.headline)
                Spacer()
                if !app.transport.registry.isEmpty {
                    Text("\(app.transport.registry.instances.count)")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Theme.accent.opacity(0.35), in: Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if app.transport.registry.isEmpty {
                Spacer()
                Text("Nothing in progress")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                TimelineView(.periodic(from: .now, by: 0.1)) { context in
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(app.transport.registry.instances) { instance in
                                // `now` makes each tick change the row's inputs —
                                // without it SwiftUI skips re-rendering and the
                                // progress bar freezes until a state change.
                                ActiveCueRow(instance: instance, now: context.date)
                            }
                        }
                        .padding(8)
                    }
                }
            }
        }
        .background(.background.secondary)
    }
}

private struct ActiveCueRow: View {
    @Environment(AppModel.self) private var app
    let instance: CueInstance
    /// Timeline tick — unused directly, but its change forces re-render.
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(tagColor(instance.cue.colorTag) ?? .secondary)
                    .frame(width: 8, height: 8)
                Text(instance.cue.number)
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                Text(instance.cue.displayName)
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
                stateBadge
            }

            if let duration = instance.duration, duration > 0 {
                ProgressView(value: min(max(instance.elapsed ?? 0, 0), duration), total: duration)
                    .tint(progressTint)
                HStack {
                    Text(Timecode.format(instance.elapsed ?? 0))
                    Spacer()
                    Text("-" + Timecode.format(max(0, duration - (instance.elapsed ?? 0))))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                if instance.state == .paused {
                    button("play.fill", "Resume") { instance.resume() }
                } else {
                    button("pause.fill", "Pause") { instance.pause() }
                }
                button("stop.fill", "Stop now (hard)") { instance.stop() }
                button("waveform.path.ecg", "Fade out and stop") {
                    instance.fadeOutAndStop(duration: app.document.show.settings.panicDuration)
                }
                Spacer()
            }
        }
        .padding(8)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 8))
    }

    private func button(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.caption)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(help)
    }

    @ViewBuilder
    private var stateBadge: some View {
        switch instance.state {
        case .preWait:
            Label("wait", systemImage: "clock").font(.caption2)
        case .running:
            Label("playing", systemImage: "play.fill").font(.caption2).foregroundStyle(Theme.accent)
        case .holding:
            Label("hold", systemImage: "pause.rectangle").font(.caption2).foregroundStyle(.blue)
        case .paused:
            Label("paused", systemImage: "pause.fill").font(.caption2).foregroundStyle(.yellow)
        case .fadingOut:
            Label("fading", systemImage: "waveform.path.ecg").font(.caption2).foregroundStyle(.orange)
        case .error:
            Label("error", systemImage: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.red)
        default:
            EmptyView()
        }
    }

    private var progressTint: Color {
        switch instance.state {
        case .paused: return .yellow
        case .fadingOut: return .orange
        default: return Theme.accent
        }
    }

    private var rowBackground: Color {
        switch instance.state {
        case .paused: return .yellow.opacity(0.12)
        case .fadingOut: return .orange.opacity(0.12)
        case .error: return .red.opacity(0.15)
        default: return Theme.accent.opacity(0.10)
        }
    }
}
