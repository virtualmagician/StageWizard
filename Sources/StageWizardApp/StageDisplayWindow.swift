import AppKit
import QuartzCore
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
/// show timer, standing-by cue + notes, running cues, and (D13) a live
/// PROGRAM pane mirroring an output group. Reads transport state only; NEVER
/// a cue target itself, so its own window never touches `OutputWindowManager`
/// — but the program pane's content layer IS registered there (as an
/// EXTERNAL host, see `OutputWindowManager.registerExternalHost`) so video/
/// camera/text/slide players can mirror onto it exactly like any other
/// preview target.
@MainActor
final class StageDisplayController {
    /// One level below `OutputWindowManager`'s real output windows
    /// (`.screenSaver`) — deliberately so a genuine cue output assigned to
    /// the SAME physical display always wins the top of the window stack.
    /// The stage display must never be able to cover real show content.
    static let windowLevel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)

    /// Stable identity for the program pane's mirrored output target — a
    /// `.preview` target like `VirtualCameraManager.monitorTarget`, but
    /// hosted directly in this window instead of a separate floating one
    /// (see `OutputWindowManager.registerExternalHost`).
    static let programTargetID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    static let programTarget = OutputTarget.preview(id: programTargetID, title: "Stage Display")

    /// Set by AppModel right after both are constructed (avoids a
    /// self-before-fully-initialized ordering problem in AppModel.init).
    weak var appModel: AppModel?

    private var window: NSWindow?
    private var currentDisplayID: CGDirectDisplayID?
    /// The program pane's live content layer, registered with
    /// `OutputWindowManager` while non-nil. A sibling of the SwiftUI
    /// content's layer, inserted directly BELOW the panic-overlay layer so
    /// PANIC always covers live program content too.
    private var programHostLayer: CALayer?
    /// The always-present (usually invisible) panic-overlay layer, captured
    /// at window-creation time so the program layer can be inserted below it.
    private weak var panicLayer: CALayer?

    /// True while the program pane is actively registered as an external
    /// host — i.e. the window is open AND the program pane is enabled.
    /// `EngineBridge`'s `stageDisplayProgramGroupID` closure reads this (via
    /// AppModel) to decide whether a cue's group should ALSO mirror here.
    var isProgramPaneShowing: Bool { programHostLayer != nil }

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
            syncProgramPane(settings: settings, in: window)
            return
        }
        close()
        let (newWindow, panic) = Self.makeWindow(screen: matched.screen, appModel: appModel)
        window = newWindow
        panicLayer = panic
        currentDisplayID = matched.displayID
        syncProgramPane(settings: settings, in: newWindow)
    }

    private func close() {
        guard let window else { return }
        teardownProgramPane()
        window.orderOut(nil)
        window.close()
        self.window = nil
        self.panicLayer = nil
        currentDisplayID = nil
    }

    /// Register/reposition/retire the program pane's live content layer to
    /// match `settings.pane(.program)`. Safe to call every time settings
    /// change while the window is open — that's how live drag-edits from
    /// the layout editor reach it (`AppModel.updateStageDisplay` always
    /// calls back through `sync`).
    private func syncProgramPane(settings: StageDisplaySettings, in window: NSWindow) {
        let pane = settings.pane(.program)
        guard pane.enabled, let container = window.contentView, let containerLayer = container.layer else {
            teardownProgramPane()
            return
        }
        let frame = StageDisplayGeometry.appKitFrame(for: pane.rect, in: container.bounds.size)
        if let programHostLayer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            programHostLayer.frame = frame
            CATransaction.commit()
            return
        }
        let layer = CALayer()
        layer.frame = frame
        // Transparent by design — the SwiftUI pane behind it paints the
        // black background + dim "PROGRAM" placeholder; this layer only
        // ever gains content when a player mirrors onto it, so idle stays
        // see-through to that placeholder.
        if let panicLayer {
            containerLayer.insertSublayer(layer, below: panicLayer)
        } else {
            containerLayer.addSublayer(layer)
        }
        programHostLayer = layer
        OutputWindowManager.shared.registerExternalHost(layer, for: Self.programTarget)
    }

    private func teardownProgramPane() {
        guard let programHostLayer else { return }
        OutputWindowManager.shared.unregisterExternalHost(for: Self.programTarget)
        programHostLayer.removeFromSuperlayer()
        self.programHostLayer = nil
    }

    /// Builds the window: a PLAIN (non-flipped, standard AppKit y-up)
    /// container view hosting two SwiftUI layers — the ordinary panes
    /// (bottom) and an always-present panic overlay (top) — with the live
    /// program-pane layer inserted directly BETWEEN them once registered,
    /// so PANIC always visually wins regardless of what's playing into the
    /// program pane. Using a plain container (rather than handing the
    /// program layer straight to the NSHostingView's own layer) keeps our
    /// raw CALayer out of SwiftUI's internally-managed layer tree entirely.
    private static func makeWindow(screen: NSScreen, appModel: AppModel?) -> (window: NSWindow, panicLayer: CALayer?) {
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

        let container = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        container.wantsLayer = true

        var panicLayer: CALayer?
        if let appModel {
            let content = NSHostingView(
                rootView: StageDisplayContentView()
                    .environment(appModel)
                    .environment(appModel.document)
            )
            content.frame = container.bounds
            content.autoresizingMask = [.width, .height]
            container.addSubview(content)

            let panic = NSHostingView(rootView: StageDisplayPanicOverlay().environment(appModel))
            panic.frame = container.bounds
            panic.autoresizingMask = [.width, .height]
            container.addSubview(panic)
            panicLayer = panic.layer
        }
        window.contentView = container

        // init(contentRect:screen:) interprets the rect relative to
        // `screen`; normalize to global coordinates like OutputWindowManager.
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        return (window, panicLayer)
    }
}

/// Convert a normalized, Y-DOWN (top-left origin) `StageRect` — how every
/// stage-display pane is authored, see `StageDisplayPane` — into an AppKit
/// Y-UP (bottom-left origin) point-space frame within a container of the
/// given size. Pure function, factored out for direct unit testing.
enum StageDisplayGeometry {
    static func appKitFrame(for rect: StageRect, in containerSize: CGSize) -> CGRect {
        let width = rect.width * containerSize.width
        let height = rect.height * containerSize.height
        let x = rect.x * containerSize.width
        // The rect's TOP edge is `rect.y * height` down from the container's
        // top; AppKit measures UP from the bottom, so the frame's origin is
        // the container height minus the rect's BOTTOM edge (top + height).
        let y = containerSize.height - (rect.y * containerSize.height) - height
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

// MARK: - Content

/// The stage display's SwiftUI content — PANE-DRIVEN (D13): each enabled
/// pane is positioned at its own normalized rect instead of a fixed
/// top/hero/bottom layout. Reads transport/document state live via the
/// environment, reusing exactly the accessors ActiveCuesPanel /
/// StandingByHeader / TransportSidebar already read — no new runtime
/// queries. Black background, white/gray text, every pane's fonts sized
/// relative to ITS OWN rect so it reads at a glance regardless of how the
/// operator arranges the layout. PANIC is NOT handled here — it's a
/// separate always-on-top overlay (`StageDisplayPanicOverlay`) so it
/// visually wins over the live program pane too, which lives in a raw
/// CALayer outside this view's own tree.
struct StageDisplayContentView: View {
    @Environment(AppModel.self) private var app
    @Environment(ShowDocumentController.self) private var document

    private var settings: StageDisplaySettings { document.show.settings.stageDisplay }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.black
                ForEach(StageDisplayPaneKind.allCases, id: \.self) { kind in
                    let pane = settings.pane(kind)
                    if pane.enabled {
                        let size = CGSize(
                            width: geo.size.width * pane.rect.width,
                            height: geo.size.height * pane.rect.height
                        )
                        paneView(kind, size: size)
                            .frame(width: size.width, height: size.height)
                            .position(
                                x: geo.size.width * (pane.rect.x + pane.rect.width / 2),
                                y: geo.size.height * (pane.rect.y + pane.rect.height / 2)
                            )
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func paneView(_ kind: StageDisplayPaneKind, size: CGSize) -> some View {
        switch kind {
        case .clock: clockPane(size: size)
        case .showTimer: showTimerPane(size: size)
        case .standingBy: standingByPane(size: size)
        case .notes: notesPane(size: size)
        case .running: runningPane(size: size)
        case .program: programPane(size: size)
        }
    }

    // MARK: Clock

    private func clockPane(size: CGSize) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(StageDisplayFormat.wallClock(context.date))
                .font(.system(size: size.height * 0.7, weight: .semibold, design: .monospaced))
                .minimumScaleFactor(0.3)
                .lineLimit(1)
                .foregroundStyle(.white)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
    }

    // MARK: Show timer

    @ViewBuilder
    private func showTimerPane(size: CGSize) -> some View {
        if let startedAt = app.showModeEnteredAt {
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                VStack(alignment: .trailing, spacing: size.height * 0.06) {
                    Text("SHOW")
                        .font(.system(size: size.height * 0.22, weight: .semibold))
                        .foregroundStyle(.gray)
                    Text(StageDisplayFormat.elapsed(from: startedAt, to: context.date))
                        .font(.system(size: size.height * 0.6, weight: .semibold, design: .monospaced))
                        .minimumScaleFactor(0.3)
                        .lineLimit(1)
                        .foregroundStyle(.white)
                }
                .frame(width: size.width, height: size.height, alignment: .topTrailing)
            }
        }
    }

    // MARK: Standing by — the hero pane

    @ViewBuilder
    private func standingByPane(size: CGSize) -> some View {
        VStack(spacing: size.height * 0.04) {
            if let cue = app.transport.standingByCue {
                Text(cue.number)
                    .font(.system(size: size.height * 0.12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.gray)
                Text(cue.displayName)
                    .font(.system(size: size.height * 0.5, weight: .bold))
                    .minimumScaleFactor(0.15)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
            } else if app.transport.isPlayheadPastEnd {
                Text("END OF SHOW")
                    .font(.system(size: size.height * 0.22, weight: .bold))
                    .foregroundStyle(.gray)
            } else {
                Text("—")
                    .font(.system(size: size.height * 0.3, weight: .bold))
                    .foregroundStyle(.gray)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    // MARK: Notes — the standing-by cue's notes, its own pane

    @ViewBuilder
    private func notesPane(size: CGSize) -> some View {
        if let cue = app.transport.standingByCue {
            let notes = document.cue(withID: cue.id)?.notes ?? ""
            if !notes.isEmpty {
                Text(notes)
                    .font(.system(size: size.height * 0.3))
                    .minimumScaleFactor(0.4)
                    .lineLimit(4)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.gray)
                    .frame(width: size.width, height: size.height)
            }
        }
    }

    // MARK: Running cues

    @ViewBuilder
    private func runningPane(size: CGSize) -> some View {
        if !app.transport.registry.isEmpty {
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                VStack(alignment: .leading, spacing: size.height * 0.04) {
                    ForEach(app.transport.registry.instances) { instance in
                        StageDisplayRunningRow(
                            instance: instance,
                            rowFontSize: size.height * 0.14,
                            now: context.date
                        )
                    }
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
            }
        }
    }

    // MARK: Program — placeholder; the LIVE layer is hosted outside SwiftUI

    /// Always-black with a dim "PROGRAM" watermark. The actual mirrored cue
    /// content is a raw CALayer `StageDisplayController` positions directly
    /// over this same screen rect (see `syncProgramPane`) — transparent
    /// until a player attaches, so this watermark shows through whenever
    /// nothing is currently routed here.
    private func programPane(size: CGSize) -> some View {
        ZStack {
            Color.black
            Text("PROGRAM")
                .font(.system(size: size.height * 0.16, weight: .bold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(.white.opacity(0.15))
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }
}

/// Always-present, full-screen, on-top-of-everything panic indicator —
/// including the program pane's live CALayer, which is NOT part of this
/// view's own SwiftUI tree and would otherwise sit above it. Renders
/// nothing while not panicking (a transparent NSHostingView), so it never
/// steals visibility from the ordinary panes.
struct StageDisplayPanicOverlay: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        GeometryReader { geo in
            if app.transport.isPanicking {
                ZStack {
                    Theme.panic
                    Text("PANIC")
                        .font(.system(size: geo.size.height * 0.12, weight: .black))
                        .foregroundStyle(.white)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
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
