import SwiftUI

/// Transport strip: large GO at left, standing-by cue line with the
/// editable notes box under it, and the transport cluster at the right.
struct GoMasthead: View {
    @Environment(AppModel.self) private var app
    @Environment(ShowDocumentController.self) private var document

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            goButton

            VStack(alignment: .leading, spacing: 6) {
                standingByLine
                notesBox
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .trailing, spacing: 8) {
                transportCluster
                panicButton
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.panelBackground)
    }

    // MARK: GO

    private var goButton: some View {
        Button {
            app.transport.go()
        } label: {
            Text("GO")
                .font(.system(size: 34, weight: .heavy))
                .frame(width: 96, height: 88)
        }
        .buttonStyle(.borderedProminent)
        // Red GO = the workspace is LIVE (Show mode).
        .tint(app.isShowMode ? Theme.panic : Theme.go)
        .disabled(app.transport.standingByCue == nil || app.transport.isPanicking)
        .help("Fire the standing-by cue (Space)")
    }

    // MARK: Standing-by + notes

    private var standingByLine: some View {
        HStack(spacing: 8) {
            if let cue = app.transport.standingByCue {
                Text(cue.number)
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                Text("·")
                    .foregroundStyle(.secondary)
                Text(cue.displayName)
                    .font(.title3)
                    .lineLimit(1)
            } else {
                Text("— end of cue list —")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Theme.insetBackground, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                // Red hairline = the workspace is LIVE, matching GO.
                .strokeBorder(
                    app.transport.standingByCue != nil
                        ? (app.isShowMode ? Theme.panic.opacity(0.8) : Theme.standbyBorder)
                        : .clear,
                    lineWidth: 1.5
                )
        )
    }

    /// Editable in place: edits go straight to the standing-by
    /// cue's notes. Space is safe here — the monitor passes keys through
    /// while any text view has focus.
    private var notesBox: some View {
        Group {
            if let cue = app.transport.standingByCue {
                if app.isShowMode {
                    // Locked: display-only, still scrollable for long notes.
                    ScrollView {
                        Text(document.cue(withID: cue.id)?.notes ?? "")
                            .font(.system(size: 14))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                    }
                } else {
                    TextEditor(text: Binding(
                        get: { document.cue(withID: cue.id)?.notes ?? "" },
                        set: { newValue in document.updateCue(cue.id) { $0.notes = newValue } }
                    ))
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .padding(4)
                }
            } else {
                Text("")
            }
        }
        .frame(height: 46)
        .background(Theme.insetBackground, in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: Transport

    private var transportCluster: some View {
        HStack(spacing: 8) {
            Button {
                app.transport.movePlayhead(by: -1)
            } label: {
                Label("Previous Cue", systemImage: "backward.frame.fill")
            }
            .help("Move the playhead to the previous cue")
            Button {
                app.transport.movePlayhead(by: 1)
            } label: {
                Label("Next Cue", systemImage: "forward.frame.fill")
            }
            .help("Move the playhead to the next cue")

            Divider().frame(height: 18)

            Button {
                app.togglePlayback()
            } label: {
                Label(
                    app.isAnythingPlaying ? "Pause All" : "Resume All",
                    systemImage: app.isAnythingPlaying ? "pause.fill" : "play.fill"
                )
            }
            .help(app.isAnythingPlaying ? "Pause everything" : "Resume everything")

            Button {
                app.transport.stopAll()
            } label: {
                Label("Stop All", systemImage: "stop.fill")
            }
            .help("Hard stop everything (no fade)")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private var panicButton: some View {
        Button {
            app.transport.panic()
        } label: {
            Text(app.transport.isPanicking ? "STOPPING!" : "STOP ALL")
                .font(.system(size: 14, weight: .heavy))
                .frame(width: 150, height: 30)
        }
        .buttonStyle(.borderedProminent)
        .tint(app.transport.isPanicking ? .red : Theme.go)
        .help("Fade everything out (Esc). Press twice for an immediate hard stop.")
    }
}

/// Transient operator warnings (broken media, missing devices) — visible
/// without ever demanding mid-show mouse interaction.
struct WarningBanner: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 4) {
            ForEach(app.warnings) { warning in
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(warning.message)
                        .lineLimit(2)
                    if let actionTitle = warning.actionTitle, let action = warning.action {
                        Button(actionTitle) { action() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(.black)
                    }
                    Spacer()
                    Button {
                        app.dismissWarning(warning.id)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                }
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.yellow.opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(.black)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, app.warnings.isEmpty ? 0 : 6)
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.2), value: app.warnings.map(\.id))
    }
}
