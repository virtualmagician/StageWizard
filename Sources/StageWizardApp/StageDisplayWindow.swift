import AppKit
import SwiftUI

// MARK: - Window

/// Borderless, non-activating window for the stage display — same
/// never-steals-focus contract as `OutputWindowManager`'s `OutputWindow`
/// (this type is intentionally separate: the stage display is never leased
/// through `OutputWindowManager`, it's never a cue target).
private final class StageDisplayNSWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns the fullscreen performer-facing "confidence monitor" window — clock,
/// show timer, standing-by cue + notes, running cues. Reads transport state
/// only; NEVER a cue target, so it never touches `OutputWindowManager`.
@MainActor
final class StageDisplayController {
    /// One level below `OutputWindowManager`'s real output windows
    /// (`.screenSaver`) — deliberately so a genuine cue output assigned to
    /// the SAME physical display always wins the top of the window stack.
    /// The stage display must never be able to cover real show content.
    static let windowLevel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)

    /// Set by AppModel right after both are constructed (avoids a
    /// self-before-fully-initialized ordering problem in AppModel.init).
    weak var appModel: AppModel?

    private var window: NSWindow?
    private var currentDisplayID: CGDirectDisplayID?

    /// Pure decision: should the stage display window be open right now?
    /// Factored out of `sync` so it's directly testable without creating
    /// any window — edit mode is never active, and a chosen-but-offline
    /// display is never active even with everything else enabled.
    static func isActive(mode: WorkspaceMode, settings: StageDisplaySettings, displayConnected: Bool) -> Bool {
        (mode == .show || mode == .rehearsal) && settings.enabled && displayConnected
    }

    /// Reconcile the window with the current settings and activity state.
    /// `active` must already fold in mode + `settings.enabled` + display
    /// connectivity (see `isActive`) — callers compute it once (AppModel's
    /// `syncStageDisplay`) and pass it straight through.
    func sync(settings: StageDisplaySettings, active: Bool) {
        guard active, let fingerprint = settings.display,
              let matched = DisplayManager.shared.match(fingerprint) else {
            close()
            return
        }
        if let window, currentDisplayID == matched.displayID {
            // Same display: re-assert the frame so a mode/resolution change
            // (reconfiguration storm) doesn't leave it mis-sized.
            window.setFrame(matched.screen.frame, display: true)
            return
        }
        close()
        window = Self.makeWindow(screen: matched.screen, appModel: appModel)
        currentDisplayID = matched.displayID
    }

    private func close() {
        guard let window else { return }
        window.orderOut(nil)
        window.close()
        self.window = nil
        currentDisplayID = nil
    }

    private static func makeWindow(screen: NSScreen, appModel: AppModel?) -> NSWindow {
        let window = StageDisplayNSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.level = windowLevel
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isOpaque = true
        window.backgroundColor = .black
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.isReleasedWhenClosed = false

        if let appModel {
            let hosting = NSHostingView(
                rootView: StageDisplayContentView()
                    .environment(appModel)
                    .environment(appModel.document)
            )
            hosting.frame = CGRect(origin: .zero, size: screen.frame.size)
            hosting.autoresizingMask = [.width, .height]
            window.contentView = hosting
        }

        // init(contentRect:screen:) interprets the rect relative to
        // `screen`; normalize to global coordinates like OutputWindowManager.
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        return window
    }
}

// MARK: - Content

/// The stage display's SwiftUI content. Reads transport/document state live
/// via the environment, reusing exactly the accessors ActiveCuesPanel /
/// StandingByHeader / TransportSidebar already read — no new runtime
/// queries. Black background, white/gray text, everything sized relative
/// to the display so it reads at a glance from across a stage.
struct StageDisplayContentView: View {
    @Environment(AppModel.self) private var app
    @Environment(ShowDocumentController.self) private var document

    private var settings: StageDisplaySettings { document.show.settings.stageDisplay }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                VStack(spacing: 0) {
                    if settings.showsClock || settings.showsShowTimer {
                        topRow(geo)
                            .padding(.bottom, geo.size.height * 0.02)
                    }
                    Spacer(minLength: 0)
                    heroSection(geo)
                    Spacer(minLength: 0)
                    bottomArea(geo)
                }
                .padding(geo.size.width * 0.035)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
    }

    // MARK: Top row — wall clock (left) + show timer (right)

    @ViewBuilder
    private func topRow(_ geo: GeometryProxy) -> some View {
        HStack(alignment: .top) {
            if settings.showsClock {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(StageDisplayFormat.wallClock(context.date))
                        .font(.system(size: geo.size.height * 0.05, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                }
            }
            Spacer()
            if settings.showsShowTimer, let startedAt = app.showModeEnteredAt {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("SHOW")
                            .font(.system(size: geo.size.height * 0.016, weight: .semibold))
                            .foregroundStyle(.gray)
                        Text(StageDisplayFormat.elapsed(from: startedAt, to: context.date))
                            .font(.system(size: geo.size.height * 0.05, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white)
                    }
                }
            }
        }
    }

    // MARK: Hero — standing-by cue (the largest thing on screen)

    @ViewBuilder
    private func heroSection(_ geo: GeometryProxy) -> some View {
        VStack(spacing: geo.size.height * 0.02) {
            if let cue = app.transport.standingByCue {
                Text(cue.number)
                    .font(.system(size: geo.size.height * 0.035, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.gray)
                Text(cue.displayName)
                    .font(.system(size: geo.size.height * 0.16, weight: .bold))
                    .minimumScaleFactor(0.15)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                if settings.showsNotes {
                    let notes = document.cue(withID: cue.id)?.notes ?? ""
                    if !notes.isEmpty {
                        Text(notes)
                            .font(.system(size: geo.size.height * 0.024))
                            .foregroundStyle(.gray)
                            .lineLimit(4)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, geo.size.width * 0.08)
                    }
                }
            } else if app.transport.isPlayheadPastEnd {
                Text("END OF SHOW")
                    .font(.system(size: geo.size.height * 0.07, weight: .bold))
                    .foregroundStyle(.gray)
            } else {
                Text("—")
                    .font(.system(size: geo.size.height * 0.1, weight: .bold))
                    .foregroundStyle(.gray)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Bottom — running cues, or PANIC taking over the same area

    @ViewBuilder
    private func bottomArea(_ geo: GeometryProxy) -> some View {
        if app.transport.isPanicking {
            Text("PANIC")
                .font(.system(size: geo.size.height * 0.06, weight: .black))
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity)
        } else if settings.showsRunning, !app.transport.registry.isEmpty {
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                VStack(alignment: .leading, spacing: geo.size.height * 0.012) {
                    ForEach(app.transport.registry.instances) { instance in
                        StageDisplayRunningRow(
                            instance: instance,
                            rowFontSize: geo.size.height * 0.02,
                            now: context.date
                        )
                    }
                }
            }
        }
    }
}

/// One running-cue row: number, name, remaining time, thin progress bar.
/// A dedicated `View` (not a helper function) so the stored `now` property
/// forces SwiftUI to re-read `instance.duration`/`elapsed` every 10 Hz tick
/// — mirrors ActiveCuesPanel's `ActiveCueRow`, same reasoning documented there.
private struct StageDisplayRunningRow: View {
    let instance: CueInstance
    let rowFontSize: CGFloat
    /// Timeline tick — unused directly, but its change forces re-render.
    let now: Date

    var body: some View {
        let duration = instance.duration
        let elapsed = instance.elapsed
        let infinite = StageDisplayFormat.isInfiniteLoop(instance.cue)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(instance.cue.number)
                    .font(.system(size: rowFontSize, weight: .bold, design: .monospaced))
                Text(instance.cue.displayName)
                    .font(.system(size: rowFontSize))
                    .lineLimit(1)
                Spacer()
                Text(StageDisplayFormat.remaining(duration: duration, elapsed: elapsed, infiniteLoop: infinite))
                    .font(.system(size: rowFontSize, design: .monospaced))
            }
            .foregroundStyle(.white)
            GeometryReader { barGeo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.white.opacity(0.15))
                    if let duration, duration > 0, !infinite {
                        let fraction = min(max((elapsed ?? 0) / duration, 0), 1)
                        Rectangle().fill(Color.white).frame(width: barGeo.size.width * fraction)
                    }
                }
            }
            .frame(height: max(2, rowFontSize * 0.2))
            .clipShape(Capsule())
        }
    }
}

// MARK: - Pure formatting / decision helpers (unit-tested directly)

enum StageDisplayFormat {
    /// "HH:MM:SS" 24-hour wall clock — always zero-padded base-10, never
    /// locale-dependent; a stage clock must read the same for every operator.
    static func wallClock(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    /// Elapsed "HH:MM:SS" between two dates — the show timer readout.
    static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }

    /// A running cue's remaining-time readout: "∞" for indefinite/looping
    /// playback (no knowable end), else "M:SS" counting down to zero.
    static func remaining(duration: TimeInterval?, elapsed: TimeInterval?, infiniteLoop: Bool) -> String {
        guard !infiniteLoop, let duration else { return "∞" }
        let remainingSeconds = max(0, Int((duration - (elapsed ?? 0)).rounded(.up)))
        return String(format: "%d:%02d", remainingSeconds / 60, remainingSeconds % 60)
    }

    /// Audio/video cues set to loop forever have no knowable end even though
    /// `CueInstance.duration` reports a single pass's length — camera/text/
    /// still cues already report `duration == nil` and are caught by
    /// `remaining`'s own nil check, so only audio/video need checking here.
    static func isInfiniteLoop(_ cue: Cue) -> Bool {
        switch cue.body {
        case .audio(let body): return body.infiniteLoop
        case .video(let body): return body.infiniteLoop
        default: return false
        }
    }
}
