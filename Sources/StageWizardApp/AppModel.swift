import AppKit
import AVFoundation
import CoreGraphics
import Observation

/// Composition root: owns the document, transport, and shortcut manager and
/// wires them together. Created once at app launch.
@MainActor
@Observable
final class AppModel {
    let document: ShowDocumentController
    let transport: TransportController
    let shortcuts: ShortcutManager
    /// D29: fire-and-forget UDP sender for `.oscSend` cues — the OUTBOUND
    /// counterpart to `oscServer` (which only ever listens/replies). Created
    /// (like `document`) before `transport`, whose init closure captures it.
    let oscSender: OSCSender
    /// D31: fire-and-forget HTTP sender for `.httpRequest` cues — the second
    /// outbound cue type. Created before `transport`, same as `oscSender`.
    let httpRequestSender: HTTPRequestSender
    /// Single funnel every remote-control surface routes through.
    let triggerRouter = TriggerRouter()
    /// CoreMIDI listener — MIDI is TriggerRouter's first client.
    let midiController = MIDIController()
    /// UDP OSC listener — TriggerRouter's second remote-control client.
    let oscServer = OSCServer()
    /// D28: BLE fallback tunnel for the StageWand hardware remote — carries
    /// the exact same OSC contract as `oscServer` when a wand's Wi-Fi link
    /// drops. Lifecycle rides `oscEnabled` (see `applyOSCSettings`), not a
    /// setting of its own.
    let bleWandLink = BLEWandLink()
    /// Web remote HTTP server (phone GO page) — TriggerRouter's third
    /// remote-control client.
    let webRemoteServer = WebRemoteServer()
    /// Performer-facing confidence-monitor window (D9). Reads transport
    /// state only — never a cue target, so it isn't wired through
    /// TriggerRouter or the provider like the surfaces above.
    let stageDisplayController = StageDisplayController()

    struct OperatorWarning: Identifiable {
        let id = UUID()
        let message: String
        let date = Date()
        var actionTitle: String?
        var action: (@MainActor () -> Void)?
    }

    /// Recent operator-facing warnings (broken media, missing devices…).
    private(set) var warnings: [OperatorWarning] = []

    /// D15: live gesture-GO readout for the stage display's gesture pane —
    /// nil when no running camera cue currently has gesture GO enabled.
    private(set) var gestureReadout: GestureReadout?
    /// Which camera cue's readout `gestureReadout` currently reflects —
    /// guards against a stopping cue clearing a DIFFERENT cue's readout
    /// that has since taken over (see `EnginePlayerProvider.onGestureReadout`).
    private var gestureReadoutCueID: UUID?

    /// Recently opened shows (File → Open Recent), mirrored from
    /// NSDocumentController so the SwiftUI menu can observe changes.
    private(set) var recentShows: [URL] = []

    func refreshRecents() {
        recentShows = NSDocumentController.shared.recentDocumentURLs
    }

    /// Workspace mode, persisted in the show file. Show and
    /// Rehearsal both lock editing; Rehearsal additionally routes video/camera
    /// output into floating preview windows (one per output group) instead of
    /// the real displays. Transport, panic, shortcuts, and the Active Cues
    /// panel are never blocked.
    private(set) var mode: WorkspaceMode = .edit

    /// Every editing surface gates on this (Show AND Rehearsal lock).
    /// True only in SHOW mode — the workspace lock. Rehearsal stays fully
    /// editable: its whole point is adjusting the show against previews.
    var isShowMode: Bool { mode == .show }

    /// When the workspace last entered Show mode; nil outside Show mode.
    /// Drives the masthead's elapsed-time readout.
    private(set) var showModeEnteredAt: Date?

    /// Restart the show timer from now — for an intermission or a restart
    /// mid-run. No-op outside Show mode.
    func resetShowTimer() {
        guard mode == .show else { return }
        showModeEnteredAt = Date()
    }

    /// Switch workspace mode. Stops all playback first (cues must re-arm
    /// against the new routing), opens/closes rehearsal previews, and — for
    /// user-initiated switches — records the mode in the show file.
    func setMode(_ newMode: WorkspaceMode, persist: Bool = true) {
        guard newMode != mode else { return }
        transport.stopAll()
        if mode == .rehearsal {
            // D14: floating-window groups play into their preview window in
            // EVERY mode, so their window must survive the switch instead of
            // flashing closed and reopening at the next arm.
            var keeping = Set(document.show.settings.outputGroups.filter(\.floatingWindow).map(\.id))
            if virtualCamera.isFeeding { keeping.insert(VirtualCameraManager.monitorPreviewID) }
            OutputWindowManager.shared.closeAllPreviews(keeping: keeping)
        }
        mode = newMode
        showModeEnteredAt = newMode == .show ? Date() : nil
        transport.wallClockEnabled = (newMode == .show || newMode == .rehearsal)
        if newMode == .rehearsal {
            openRehearsalPreviews()
        }
        if newMode != .edit {
            // Pre-show check: surface permission problems BEFORE the first GO.
            checkPermissionsForCurrentShow()
        }
        if newMode == .show {
            runPreflightWarning()
        }
        if persist, document.show.settings.workspaceMode != newMode {
            // Persisted so reopening the show restores the mode, but a mode
            // flip is not a user edit worth an undo step — and undoing past
            // it must never revert the live workspace mode (see
            // ShowDocumentController.restore).
            document.mutateWithoutUndo { $0.settings.workspaceMode = newMode }
        }
        syncStageDisplay()
        // D18 (FIX 1): the stage display now NEVER presents fullscreen over
        // the operator's own screen — `StageDisplayController.presentationStyle`
        // falls back to floating instead. Warn (once, on entry) when that
        // fallback engaged, so the operator knows why the stage display
        // isn't fullscreen. Preflight already caught this before the
        // switch, but the operator may not have run it.
        if newMode == .show, stageDisplayCoversOperatorScreen {
            pushWarning("Stage display targets the operator screen — opened as a floating window instead.")
        }
    }

    /// Preflight on entering Show mode — a quiet banner, not a blocking sheet;
    /// the operator opens Settings → General → Preflight for the full list.
    private func runPreflightWarning() {
        let issues = Preflight.run(
            show: document.show,
            showFolder: document.showFolder,
            cameraAuthorized: AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
            virtualCamFeeding: virtualCamera.isFeeding,
            connectedDevices: AudioDeviceManager.shared.outputDevices,
            stageDisplayCoversOperatorScreen: stageDisplayCoversOperatorScreen,
            midiDestinations: midiController.destinations
        )
        guard let firstError = issues.first(where: { $0.severity == .error }) else { return }
        let more = issues.count > 1 ? " (+\(issues.count - 1) more — Settings → General → Preflight)" : ""
        pushWarning("Preflight: \(firstError.message)\(more)")
    }

    /// One floating preview per assigned video output — so the operator can
    /// arrange them before anything plays. (Legacy direct-display cues get a
    /// shared preview lazily if one ever arms.)
    private func openRehearsalPreviews() {
        for group in document.show.settings.outputGroups {
            OutputWindowManager.shared.openPreview(id: group.id, title: group.name)
        }
    }

    /// Held while cues play: blocks display/system sleep and App Nap mid-show.
    @ObservationIgnored private var activityToken: NSObjectProtocol?

    init() {
        let document = ShowDocumentController()
        self.document = document
        let provider = EnginePlayerProvider()
        provider.settings = { document.show.settings }
        let oscSender = OSCSender()
        self.oscSender = oscSender
        let httpRequestSender = HTTPRequestSender()
        self.httpRequestSender = httpRequestSender
        self.transport = TransportController(
            provider: provider,
            show: { document.show },
            showFolder: { document.showFolder },
            oscSend: { body in oscSender.send(body) },
            midiSend: { [midiController] body in midiController.send(body) },
            httpRequest: { body in httpRequestSender.send(body) }
        )
        self.shortcuts = ShortcutManager()
        wire()
        wireEngines(provider: provider)
        checkPermissionsForCurrentShow()
    }

    private func wire() {
        transport.onPlaybackActivityChanged = { [weak self] active in
            self?.document.isPlaybackActive = active
            self?.updateSleepPrevention(active)
        }
        transport.onOperatorWarning = { [weak self] message in
            self?.pushWarning(message)
        }
        oscSender.onWarning = { [weak self] message in
            self?.pushWarning(message)
        }
        midiController.onWarning = { [weak self] message in
            self?.pushWarning(message)
        }
        httpRequestSender.onWarning = { [weak self] message in
            self?.pushWarning(message)
        }
        document.onRecentsChanged = { [weak self] in
            self?.refreshRecents()
        }
        refreshRecents()
        document.onUndoRestore = { [weak self] in
            guard let self else { return }
            self.transport.revalidatePlayhead()
            // Undo snapshots include ShowSettings — resync every live mirror
            // of it (remote-control listeners, stage display, running camera
            // effects) so an undone settings change doesn't leave a server
            // listening (or an effect applied) while the UI shows otherwise.
            self.syncMIDIEnabled()
            self.syncOSCEnabled()
            self.syncWebRemoteEnabled()
            self.syncStageDisplay()
            for instance in self.transport.registry.instances {
                if case .camera = instance.cue.body {
                    self.pushEffects(cueID: instance.cue.id)
                }
            }
        }
        document.onDocumentReplaced = { [weak self] in
            guard let self else { return }
            self.transport.reset()
            self.checkPermissionsForCurrentShow()
            // Restore the saved workspace mode without re-dirtying the
            // freshly opened document.
            self.setMode(self.document.show.settings.workspaceMode, persist: false)
            self.syncVirtualCameraFeed()
            self.syncMIDIEnabled()
            self.syncOSCEnabled()
            self.syncWebRemoteEnabled()
            self.syncStageDisplay()
        }

        stageDisplayController.appModel = self

        shortcuts.bindingsProvider = { [weak self] in
            self?.document.show.settings.keyBindings ?? [:]
        }
        shortcuts.hotkeysProvider = { [weak self] in
            guard let cues = self?.document.show.cues else { return [:] }
            var map: [KeyBinding: UUID] = [:]
            for cue in cues {
                if let hotkey = cue.hotkey { map[hotkey] = cue.id }
            }
            return map
        }
        shortcuts.onPanic = { [weak self] in self?.transport.panic() }
        // D17: hardwired ⌘⎋ — the only way to exit Show mode when the stage
        // display is covering the operator's own screen. Rehearsal/Edit: no-op.
        shortcuts.onExitShowMode = { [weak self] in
            guard let self, self.mode == .show else { return }
            self.setMode(.edit)
        }
        shortcuts.onCueHotkey = { [weak self] cueID in self?.transport.fire(cueID: cueID) }
        shortcuts.onAction = { [weak self] action in self?.perform(action) }
        shortcuts.install()

        triggerRouter.appModel = self
        midiController.bindingsProvider = { [weak self] in
            self?.document.show.settings.midiBindings ?? []
        }
        midiController.onAction = { [weak self] action in
            self?.triggerRouter.route(action)
        }

        oscServer.onCommand = { [weak self] command in
            self?.handleOSCCommand(command)
        }
        // D21: a brand-new (or pruned-and-returning) subscriber gets the
        // FULL current status feed immediately, on its connection alone —
        // always a fresh `old: nil` diff, independent of `lastOSCSnapshot`
        // (which tracks what was last BROADCAST to everyone, not what any
        // one subscriber has actually received).
        oscServer.fullRefreshProvider = { [weak self] in
            guard let self else { return [] }
            return OSCStatusFeedback.changedMessages(old: nil, new: self.currentOSCSnapshot())
        }

        // D28: the BLE tunnel's inbound notifies reassemble into the same
        // `OSCMessage` shape a UDP datagram parses to — resolve each via the
        // SAME pure routing table (`OSCServer.command(for:)`) and dispatch
        // through the SAME handler as the UDP path, so a BLE-connected wand
        // is indistinguishable from a UDP one once past the wire. Unresolved
        // addresses (including `/stagewand/ping`) are silently dropped here,
        // exactly like an unrecognized UDP datagram.
        bleWandLink.onInboundMessages = { [weak self] messages in
            guard let self else { return }
            for message in messages {
                guard let command = OSCServer.command(for: message.address) else { continue }
                self.handleOSCCommand(command)
            }
        }
        // Connection IS the subscription for BLE (no 5 s expiry) — on
        // connect + notify-subscribe, BLEWandLink sends this exact burst to
        // that one wand alone, mirroring `oscServer.fullRefreshProvider`.
        bleWandLink.fullRefreshProvider = { [weak self] in
            guard let self else { return [] }
            return OSCStatusFeedback.changedMessages(old: nil, new: self.currentOSCSnapshot())
        }

        webRemoteServer.onCommand = { [weak self] command in
            guard let self else { return }
            switch command {
            case .go: self.triggerRouter.route(.go)
            case .stopAll: self.triggerRouter.route(.stopAll)
            case .panic: self.triggerRouter.routePanic()
            case .next: self.triggerRouter.route(.nextCue)
            case .prev: self.triggerRouter.route(.previousCue)
            }
        }
        webRemoteServer.statusProvider = { [weak self] in
            guard let self else {
                return WebRemoteStatus(standingByNumber: nil, standingByName: nil, notes: nil, runningCount: 0, showMode: false, panicking: false)
            }
            let core = self.currentRemoteStatusCore()
            return WebRemoteStatus(
                standingByNumber: core.standingByNumber,
                standingByName: core.standingByName,
                notes: core.notes,
                runningCount: core.runningCount,
                showMode: core.showMode,
                panicking: core.panicking
            )
        }
    }

    /// D21 (+D28): the ONE inbound-command dispatch every OSC-shaped
    /// remote-control transport shares — UDP (`oscServer.onCommand`) and
    /// the BLE StageWand tunnel (`bleWandLink.onInboundMessages`, resolved
    /// through the same `OSCServer.command(for:)` table) both funnel here,
    /// so a wand talking over BLE behaves identically to one talking over
    /// UDP. Everything still routes through TriggerRouter — this is not a
    /// second path around it, just the shared bit of glue above it.
    private func handleOSCCommand(_ command: OSCCommand) {
        switch command {
        case .action(let action): triggerRouter.route(action)
        case .panic: triggerRouter.routePanic()
        case .fireCue(let number): triggerRouter.route(cueNumber: number)
        case .selectCue(let number): triggerRouter.route(selectCueNumber: number)
        }
    }

    // MARK: - D21: shared remote-status source (web remote + OSC feedback
    // read the EXACT same state at the exact same call site, so they can't
    // drift against each other)

    /// The P1 status fields every remote-control status surface shares —
    /// factored out of `webRemoteServer.statusProvider` so OSC feedback
    /// (`currentOSCSnapshot`) reuses it verbatim rather than recomputing its
    /// own (potentially divergent) copy.
    private struct RemoteStatusCore {
        var standingByNumber: String?
        var standingByName: String?
        var notes: String?
        var runningCount: Int
        var showMode: Bool
        var panicking: Bool
    }

    private func currentRemoteStatusCore() -> RemoteStatusCore {
        let cue = transport.standingByCue
        return RemoteStatusCore(
            standingByNumber: cue?.number,
            standingByName: cue?.displayName,
            notes: cue.flatMap { document.cue(withID: $0.id)?.notes },
            runningCount: transport.registry.instances.count,
            showMode: isShowMode,
            panicking: transport.isPanicking
        )
    }

    /// The full OSC status snapshot — `currentRemoteStatusCore()` plus the
    /// GO-sequence window (index/total/prev/next) and the D22 capped cue
    /// list, both of which only OSC needs.
    private func currentOSCSnapshot() -> OSCStatusFeedback.Snapshot {
        let core = currentRemoteStatusCore()
        let goSequence = transport.goSequence
        let window = OSCStatusFeedback.windowInfo(goSequence: goSequence, standingByID: transport.standingByCue?.id)
        return OSCStatusFeedback.Snapshot(
            standingByNumber: core.standingByNumber ?? "",
            standingByName: core.standingByName ?? "",
            notes: core.notes ?? "",
            runningCount: core.runningCount,
            panic: core.panicking,
            showMode: core.showMode,
            windowIndex: window.index,
            windowTotal: window.total,
            prevNum: window.prevNum,
            prevName: window.prevName,
            nextNum: window.nextNum,
            nextName: window.nextName,
            cuelist: OSCStatusFeedback.cuelistEntries(goSequence: goSequence)
        )
    }

    // MARK: - D21 (+D22): OSC status feedback tick (10 Hz while OSC is enabled)

    /// Feedback-tick state — never persisted, never observed by SwiftUI
    /// (hence `@ObservationIgnored`, mirroring `activityToken` above).
    @ObservationIgnored private var oscFeedbackTask: Task<Void, Never>?
    @ObservationIgnored private var lastOSCSnapshot: OSCStatusFeedback.Snapshot?
    @ObservationIgnored private var oscFeedbackTickCount = 0

    private static let oscFeedbackTickInterval: Duration = .milliseconds(100)   // 10 Hz
    /// Elapsed rides the same tick but only every 5th one (10 Hz / 5 = 2 Hz)
    /// — it always changes, so it can't ride the diffed snapshot above.
    private static let oscElapsedTickDivisor = 5
    /// D22 liveness heartbeat divisor (10 Hz / 20 = every ~2s) lives on
    /// `OSCStatusFeedback.heartbeatTickDivisor` — see `oscFeedbackTick`.

    /// Start the 10 Hz feedback loop — called from `applyOSCSettings`
    /// alongside `oscServer.start(port:)`, never on its own.
    private func startOSCFeedback() {
        guard oscFeedbackTask == nil else { return }
        lastOSCSnapshot = nil
        oscFeedbackTickCount = 0
        oscFeedbackTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.oscFeedbackTick()
                try? await Task.sleep(for: Self.oscFeedbackTickInterval)
            }
        }
    }

    /// Stop the feedback loop and forget the last-sent snapshot — called
    /// alongside `oscServer.stop()` so a later restart always re-sends a
    /// full picture rather than diffing against stale state.
    private func stopOSCFeedback() {
        oscFeedbackTask?.cancel()
        oscFeedbackTask = nil
        lastOSCSnapshot = nil
        oscFeedbackTickCount = 0
    }

    /// One tick: diff the current snapshot against the last-broadcast one
    /// and send whatever changed; every 20th tick (D22, ~2s at 10 Hz) also
    /// sends a liveness heartbeat — a re-send of `/stagewizard/status/running`
    /// regardless of change, so a quiet-but-alive host stays distinguishable
    /// from a dead one — UNLESS this same tick's diff already sent a genuine
    /// running-count change (no double-send; see
    /// `OSCStatusFeedback.shouldSendHeartbeat`). Separately, every 5th tick
    /// also sends `/stagewizard/status/elapsed` for the most-recently-started
    /// RUNNING instance. "Most-recently-started" = the LAST element of
    /// `registry.instances` whose state is `.running` — instances are
    /// appended in fire order and never reordered (`ActiveCuesRegistry.add`),
    /// so the last `.running` entry is the most recently started one still
    /// actually playing (as opposed to pre-waiting, holding, paused, or
    /// fading). No `.running` instance this tick (even if `runningCount` is
    /// nonzero — e.g. everything active is mid-preWait) simply skips the
    /// elapsed message for that tick.
    private func oscFeedbackTick() {
        let snapshot = currentOSCSnapshot()
        let changed = OSCStatusFeedback.changedMessages(old: lastOSCSnapshot, new: snapshot)
        lastOSCSnapshot = snapshot
        if !changed.isEmpty {
            broadcastOSCFeedback(changed)
        }

        oscFeedbackTickCount += 1

        let runningAlreadySent = changed.contains { $0.address == "/stagewizard/status/running" }
        if OSCStatusFeedback.shouldSendHeartbeat(tickCount: oscFeedbackTickCount, runningAlreadySentThisTick: runningAlreadySent) {
            broadcastOSCFeedback([OSCStatusFeedback.runningMessage(snapshot.runningCount)])
        }

        guard oscFeedbackTickCount % Self.oscElapsedTickDivisor == 0 else { return }
        guard let running = transport.registry.instances.last(where: { $0.state == .running }) else { return }
        broadcastOSCFeedback([OSCStatusFeedback.elapsedMessage(elapsed: running.elapsed ?? 0, duration: running.duration)])
    }

    /// D28: the one place outbound OSC feedback actually goes out — fans
    /// every message to both live sinks (UDP `oscServer` + the BLE
    /// `bleWandLink` StageWand tunnel) via the pure `OSCFeedbackFanout`
    /// seam, so `oscFeedbackTick`'s three send sites (diffed change,
    /// heartbeat, elapsed) never have to know how many transports exist.
    private func broadcastOSCFeedback(_ messages: [OSCMessage]) {
        OSCFeedbackFanout.broadcast(messages, to: [oscServer.broadcast, bleWandLink.broadcast])
    }

    private func wireEngines(provider: EnginePlayerProvider) {
        provider.onWarning = { [weak self] message in
            self?.pushWarning(message)
        }
        provider.rehearsalActive = { [weak self] in
            self?.mode == .rehearsal
        }
        provider.virtualCameraFeeding = { [weak self] in
            self?.virtualCamera.isFeeding ?? false
        }
        // D13, generalized D16: the stage display's PROGRAM panes mirror any
        // number of output groups' live cues — empty whenever the window
        // isn't currently showing any of them (window closed, or every pane
        // disabled/deleted), same "extra target" shape as virtualCameraFeeding
        // above.
        provider.stageDisplayProgramGroupIDs = { [weak self] in
            self?.stageDisplayController.mirroredProgramGroupIDs ?? []
        }
        // D11 (experimental) gesture GO: fire GO exactly as a bound key
        // would, but never while editing — a magician rehearsing gestures
        // in Show/Rehearsal wants this; someone editing the show does not.
        provider.onGesture = { [weak self] in
            guard let self, self.mode != .edit else { return }
            self.triggerRouter.route(.go)
        }
        // D15: the stage display's gesture pane mirrors whichever camera
        // cue most recently reported a readout; a nil clear only wins if it
        // came from the cue currently on display (see the type's own doc).
        provider.onGestureReadout = { [weak self] cueID, readout in
            guard let self else { return }
            if let readout {
                self.gestureReadout = readout
                self.gestureReadoutCueID = cueID
            } else if self.gestureReadoutCueID == cueID {
                self.gestureReadout = nil
                self.gestureReadoutCueID = nil
            }
        }
        virtualCamera.onWarning = { [weak self] message in
            self?.pushWarning(message)
        }
        virtualCamera.onBecameActive = { [weak self] in
            self?.syncVirtualCameraFeed()
        }
        // Preview resizes invalidate stage-relative transforms — re-push.
        OutputWindowManager.shared.onPreviewResized = { [weak self] in
            self?.reapplyAllGeometry()
        }
        // Device/config change killed everything on that engine — tell the operator.
        AudioEngineManager.shared.onEngineRebuilt = { [weak self] uid in
            self?.pushWarning("Audio device changed (\(uid ?? "system default")) — affected cues were stopped.")
        }
        // Display unplugged: its output window is already closed; stop the
        // orphaned instances so the registry/panel stay truthful.
        DisplayManager.shared.onDisplaysChanged = { [weak self] displays in
            guard let self else { return }
            let liveIDs = Set(displays.map(\.displayID))
            for instance in self.transport.registry.instances {
                let targets: [CGDirectDisplayID] =
                    (instance.player as? VideoCuePlayer)?.displayIDs
                    ?? (instance.player as? CameraCuePlayer)?.displayIDs
                    ?? (instance.player as? StillCuePlayer)?.displayIDs
                    ?? []
                guard !targets.isEmpty else { continue }
                let survivors = targets.filter(liveIDs.contains)
                if survivors.isEmpty {
                    // Every display of this cue is gone — stop it.
                    instance.stop()
                    self.pushWarning("Cue \(instance.cue.number): display disconnected — output stopped.")
                } else if survivors.count < targets.count {
                    // Partial loss: the dead display's window is already
                    // closed; the show continues on the remaining screens.
                    self.pushWarning("Cue \(instance.cue.number): one of its displays disconnected — continuing on the rest.")
                }
            }
            // The stage display's chosen screen may have just vanished (or
            // reconfigured) — close it or re-assert its frame.
            self.syncStageDisplay()
        }
    }

    // MARK: - Permissions

    /// Verify every permission the current show needs — on launch, on show
    /// open, and when entering Show/Rehearsal mode. Camera consent is
    /// requested proactively so the prompt never lands on a live GO.
    func checkPermissionsForCurrentShow() {
        let usesCamera = document.show.cues.contains { cue in
            if case .camera = cue.body { return true }
            return false
        }
        guard usesCamera else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            Task { [weak self] in
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                if !granted {
                    self?.pushCameraDeniedWarning()
                }
            }
        default:
            pushCameraDeniedWarning()
        }
    }

    private func pushCameraDeniedWarning() {
        pushWarning(
            "This show uses camera cues, but camera access is denied — those cues will fail.",
            actionTitle: "Open Camera Settings"
        ) {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - Live geometry

    /// Push a cue's current geometry to any running instances of it — the
    /// inspector calls this after every geometry edit so positioning is live.
    func pushGeometry(cueID: UUID) {
        guard let cue = document.cue(withID: cueID) else { return }
        let settings: (VideoGeometry, FillMode, Int)? = switch cue.body {
        case .video(let body): (body.geometry, body.fillMode, body.layer)
        case .camera(let body): (body.geometry, body.fillMode, body.layer)
        case .image(let body): (body.geometry, body.fillMode, body.layer)
        case .slide(let body): (body.geometry, body.fillMode, body.layer)
        case .text(let body): (body.geometry, .stretch, body.layer)
        default: nil
        }
        guard let (geometry, fillMode, renderLayer) = settings else { return }
        for instance in transport.registry.instances where instance.cue.id == cueID {
            (instance.player as? VideoCuePlayer)?.applyGeometry(geometry, fillMode: fillMode)
            (instance.player as? CameraCuePlayer)?.applyGeometry(geometry, fillMode: fillMode)
            (instance.player as? StillCuePlayer)?.applyGeometry(geometry, fillMode: fillMode)
            (instance.player as? VideoCuePlayer)?.applyRenderLayer(renderLayer)
            (instance.player as? CameraCuePlayer)?.applyRenderLayer(renderLayer)
            (instance.player as? StillCuePlayer)?.applyRenderLayer(renderLayer)
            (instance.player as? TextCuePlayer)?.applyGeometry(geometry, fillMode: fillMode)
            (instance.player as? TextCuePlayer)?.applyRenderLayer(renderLayer)
        }
    }

    /// The virtual webcam ("StageWizard Camera") — activation + frame feed.
    let virtualCamera = VirtualCameraManager()

    /// Start/stop the virtual-webcam feed AND remember the choice in the
    /// show file — reopening the show restores it (extension permitting).
    func setVirtualCameraFeed(_ enabled: Bool) {
        document.mutate { $0.settings.virtualCameraFeed = enabled }
        applyVirtualCameraFeed(enabled)
    }

    /// Reconcile the running feed with what the current show wants.
    func syncVirtualCameraFeed() {
        applyVirtualCameraFeed(document.show.settings.virtualCameraFeed)
    }

    private func applyVirtualCameraFeed(_ wanted: Bool) {
        if wanted {
            guard virtualCamera.status == .active, !virtualCamera.isFeeding else { return }
            Task { await virtualCamera.startFeeding() }
        } else if virtualCamera.isFeeding {
            virtualCamera.stopFeeding()
        }
    }

    /// Start/stop the CoreMIDI listener AND remember the choice in the show
    /// file — reopening the show restores it. Active in every workspace mode
    /// while enabled, same as hotkeys.
    func setMIDIEnabled(_ enabled: Bool) {
        document.mutate { $0.settings.midiEnabled = enabled }
        applyMIDIEnabled(enabled)
    }

    /// Reconcile the running listener with what the current show wants —
    /// called on document replace (new/open).
    func syncMIDIEnabled() {
        applyMIDIEnabled(document.show.settings.midiEnabled)
    }

    private func applyMIDIEnabled(_ wanted: Bool) {
        if wanted {
            midiController.start()
        } else {
            midiController.stop()
        }
    }

    /// Start/stop the OSC UDP listener AND remember the choice in the show
    /// file — reopening the show restores it. Active in every workspace mode
    /// while enabled, same as MIDI/hotkeys.
    func setOSCEnabled(_ enabled: Bool) {
        document.mutate { $0.settings.oscEnabled = enabled }
        applyOSCSettings()
    }

    /// Persist a new port and rebind the listener to it (if currently
    /// enabled) — the Remote settings tab calls this when the port field is
    /// committed. A port change is a full restart; there is no live rebind.
    func setOSCPort(_ port: UInt16) {
        document.mutate { $0.settings.oscPort = port }
        applyOSCSettings()
    }

    /// Reconcile the running listener with what the current show wants —
    /// called on document replace (new/open).
    func syncOSCEnabled() {
        applyOSCSettings()
    }

    /// Always stop first: the only way to rebind to a new port, and a clean
    /// no-op when the listener isn't running. D21: the feedback tick's
    /// lifecycle is tied 1:1 to the listener's — it has nothing to send
    /// without a live listener, and a port rebind should never leave a
    /// stale tick broadcasting into a dead server. D28: `bleWandLink` rides
    /// the exact same lifecycle — it has no port of its own, so a plain
    /// port edit also bounces the BLE scan/connections; a brief reconnect
    /// blip on a rare admin action is an acceptable trade for one lifecycle
    /// instead of two.
    private func applyOSCSettings() {
        oscServer.stop()
        bleWandLink.stop()
        stopOSCFeedback()
        guard document.show.settings.oscEnabled else { return }
        oscServer.start(port: document.show.settings.oscPort)
        bleWandLink.start()
        startOSCFeedback()
    }

    /// Start/stop the web remote HTTP server AND remember the choice in the
    /// show file — reopening the show restores it. Active in every
    /// workspace mode while enabled, same as MIDI/OSC/hotkeys.
    func setWebRemoteEnabled(_ enabled: Bool) {
        document.mutate { $0.settings.webRemoteEnabled = enabled }
        applyWebRemoteSettings()
    }

    /// Persist a new port and rebind the server to it (if currently
    /// enabled) — the Remote settings tab calls this when the port field is
    /// committed. A port change is a full restart; there is no live rebind.
    func setWebRemotePort(_ port: UInt16) {
        document.mutate { $0.settings.webRemotePort = port }
        applyWebRemoteSettings()
    }

    /// Reconcile the running server with what the current show wants —
    /// called on document replace (new/open).
    func syncWebRemoteEnabled() {
        applyWebRemoteSettings()
    }

    /// Always stop first: the only way to rebind to a new port, and a clean
    /// no-op when the server isn't running.
    private func applyWebRemoteSettings() {
        webRemoteServer.stop()
        guard document.show.settings.webRemoteEnabled else { return }
        webRemoteServer.start(port: document.show.settings.webRemotePort)
    }

    /// Update the stage-display settings AND resync the window immediately —
    /// the Video Outputs tab calls this for every field (enable, chosen
    /// display, visible sections) instead of `document.mutate` directly.
    func updateStageDisplay(_ change: (inout StageDisplaySettings) -> Void) {
        document.mutate { change(&$0.settings.stageDisplay) }
        syncStageDisplay()
    }

    /// Reconcile the stage-display window with what the current show + mode
    /// + connected displays want. Called on mode changes, document replace,
    /// settings edits, and display hot-plug/reconfiguration.
    func syncStageDisplay() {
        let settings = document.show.settings.stageDisplay
        let displayConnected = settings.display.flatMap { DisplayManager.shared.match($0) } != nil
        let active = StageDisplayController.isActive(mode: mode, settings: settings, displayConnected: displayConnected)
        // `sync` registers/retires every program pane's external host layer
        // (`syncProgramPanes`) synchronously before returning — the mirror
        // diff below MUST run after that, never before, so a group that just
        // entered the mirrored set already has somewhere for `attachTarget`
        // to lease.
        stageDisplayController.sync(
            settings: settings, outputGroups: document.show.settings.outputGroups, active: active, mode: mode,
            operatorScreenDisplayID: operatorScreenDisplayID
        )
        syncMirrorAttachments()
    }

    // MARK: - D17: live mirror attach/detach

    /// The mirrored-group set as of the last `syncMirrorAttachments` call —
    /// diffed against the fresh set every time so only what actually
    /// changed (a checkbox, a window open/close, a hot-plug, a mode switch)
    /// triggers an attach/detach, never a no-op resync (e.g. a pane
    /// rect-only drag).
    private var previousMirroredGroupIDs: Set<UUID> = []

    /// One (running instance, output group) pair eligible for a live
    /// mirror-attach decision — a plain value so `mirrorAttachDiff` stays
    /// pure and directly testable with no player/registry involved.
    struct MirrorCandidate: Hashable {
        let instanceID: UUID
        let groupID: UUID
    }

    /// Pure: which candidates gain/lose their mirror attachment when the
    /// stage display's mirrored-group set moves from `previous` to
    /// `current`. A group ENTERING the set attaches every candidate
    /// currently on it; a group LEAVING detaches them. A group present in
    /// both sets (or absent from both — an unrelated group's checkbox, a
    /// pane rect-only edit) produces nothing, so an unrelated resync is
    /// naturally a no-op. Factored out of `syncMirrorAttachments` so the
    /// attach/detach DECISION is directly testable with no player, window,
    /// or transport involved.
    static func mirrorAttachDiff(
        previousGroupIDs: Set<UUID>,
        currentGroupIDs: Set<UUID>,
        candidates: [MirrorCandidate]
    ) -> (attach: [MirrorCandidate], detach: [MirrorCandidate]) {
        guard previousGroupIDs != currentGroupIDs else { return ([], []) }
        let entered = currentGroupIDs.subtracting(previousGroupIDs)
        let left = previousGroupIDs.subtracting(currentGroupIDs)
        return (
            candidates.filter { entered.contains($0.groupID) },
            candidates.filter { left.contains($0.groupID) }
        )
    }

    /// Diff the stage display's CURRENT mirrored-group set against the
    /// previous snapshot and attach/detach every RUNNING (or paused, or
    /// fading, or holding — anything with a live player that hasn't
    /// terminated) instance whose cue's output group entered/left it. This
    /// is what makes checking a mirror box, opening the stage display, or a
    /// display hot-plug show already-playing content immediately instead of
    /// only at the next arm (D17).
    private func syncMirrorAttachments() {
        let current = stageDisplayController.mirroredProgramGroupIDs
        defer { previousMirroredGroupIDs = current }

        var instancesByID: [UUID: CueInstance] = [:]
        var candidates: [MirrorCandidate] = []
        for instance in transport.registry.instances {
            guard instance.player != nil, !instance.state.isTerminal,
                  let groupID = instance.cue.body.outputGroupID else { continue }
            instancesByID[instance.id] = instance
            candidates.append(MirrorCandidate(instanceID: instance.id, groupID: groupID))
        }

        let diff = Self.mirrorAttachDiff(
            previousGroupIDs: previousMirroredGroupIDs, currentGroupIDs: current, candidates: candidates
        )
        for candidate in diff.attach {
            instancesByID[candidate.instanceID]?.player?.attachTarget(StageDisplayController.programTarget(for: candidate.groupID))
        }
        for candidate in diff.detach {
            instancesByID[candidate.instanceID]?.player?.detachTarget(StageDisplayController.programTarget(for: candidate.groupID))
        }
    }

    /// D17, updated D18 (FIX 1): true when Show mode would present the stage
    /// display FLOATING instead of fullscreen because of the operator's own
    /// screen — either the matched display IS that screen, or it can't be
    /// resolved at all yet. Used by both the Show-mode-entry warning
    /// (`setMode`) and Preflight; reuses `StageDisplayController.presentationStyle`
    /// so this stays the exact same decision `sync` itself makes, never a
    /// second, driftable copy of it. The only place mode/display/window
    /// state gets resolved into the bool each of those consumes, so
    /// `Preflight.run` itself stays pure.
    var stageDisplayCoversOperatorScreen: Bool {
        let settings = document.show.settings.stageDisplay
        guard settings.enabled, let fingerprint = settings.display,
              let matched = DisplayManager.shared.match(fingerprint) else { return false }
        let matchedIsOperatorScreen = StageDisplayController.fullscreenCoversOperatorScreen(
            matchedDisplayID: matched.displayID, operatorScreenDisplayID: operatorScreenDisplayID
        )
        return StageDisplayController.presentationStyle(
            mode: .show,
            matchedScreenIsOperatorScreen: matchedIsOperatorScreen,
            operatorScreenKnown: operatorScreenDisplayID != nil
        ) == .floating
    }

    /// The physical display hosting the operator's own (real, key-able)
    /// window — every StageWizard-owned output/preview/stage-display window
    /// refuses `canBecomeMain`, so `NSApp.mainWindow` always resolves to the
    /// operator's real window when one exists. D18: `mainWindow` is nil at
    /// launch until SwiftUI actually presents the scene's window (this is
    /// exactly the gap that let the stage display go fullscreen over the
    /// operator's own not-yet-existing window) — fall back to the first
    /// visible, titled, non-panel app window so a later resync (see
    /// `StageWizardApp`'s `onAppear`) still finds it even if it's momentarily
    /// not `mainWindow`. Still nil (operator screen "unknown") when neither
    /// exists — `presentationStyle`'s safe default handles that.
    private var operatorScreenDisplayID: CGDirectDisplayID? {
        let operatorWindow = NSApp.mainWindow ?? NSApp.windows.first { window in
            window.isVisible && window.styleMask.contains(.titled) && !(window is NSPanel)
        }
        guard let screen = operatorWindow?.screen else { return nil }
        return DisplayManager.connectedDisplay(for: screen)?.displayID
    }

    /// Push a camera cue's effects to any running instances — segmentation
    /// and magic dust toggle live, no session restart.
    func pushEffects(cueID: UUID) {
        guard let cue = document.cue(withID: cueID), case .camera(let body) = cue.body else { return }
        let emitterURL = body.effects.dustEmitter?.resolve(showFolder: document.showFolder)
        for instance in transport.registry.instances where instance.cue.id == cueID {
            (instance.player as? CameraCuePlayer)?.applyEffects(body.effects, dustEmitterURL: emitterURL)
        }
    }

    /// Push a text cue's content to any running instances — the Text tab
    /// calls this after every edit so the stage updates as you type.
    func pushText(cueID: UUID) {
        guard let cue = document.cue(withID: cueID), case .text(let body) = cue.body else { return }
        for instance in transport.registry.instances where instance.cue.id == cueID {
            (instance.player as? TextCuePlayer)?.applyText(body)
        }
    }

    private func reapplyAllGeometry() {
        for instance in transport.registry.instances {
            pushGeometry(cueID: instance.cue.id)
        }
    }

    private func updateSleepPrevention(_ active: Bool) {
        if active, activityToken == nil {
            activityToken = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled, .userInitiated],
                reason: "Show playback running"
            )
        } else if !active, let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
    }

    /// Single dispatch point for transport verbs. Internal (not private) so
    /// TriggerRouter — the funnel every remote (MIDI/OSC/web/gesture) routes
    /// through — can reach it; no extra guards belong here or in the router,
    /// this switch IS the semantics.
    func perform(_ action: ShortcutAction) {
        switch action {
        case .go: transport.go()
        case .stopAll: transport.stopAll()
        case .togglePlayback, .pauseAll, .resumeAll:   // legacy bindings toggle too
            togglePlayback()
        case .previousCue: transport.movePlayhead(by: -1)
        case .nextCue: transport.movePlayhead(by: 1)
        case .load: break
        }
    }

    /// One key for pause/resume: anything audible → pause all; else resume all.
    func togglePlayback() {
        let anyRunning = transport.registry.instances.contains { instance in
            switch instance.state {
            case .running, .preWait, .fadingOut, .holding: return true
            default: return false
            }
        }
        if anyRunning {
            transport.pauseAll()
        } else {
            transport.resumeAll()
        }
    }

    /// Masthead toggle button state.
    var isAnythingPlaying: Bool {
        transport.registry.instances.contains { instance in
            switch instance.state {
            case .running, .preWait, .fadingOut, .holding: return true
            default: return false
            }
        }
    }

    func pushWarning(_ message: String, actionTitle: String? = nil, action: (@MainActor () -> Void)? = nil) {
        let warning = OperatorWarning(message: message, actionTitle: actionTitle, action: action)
        warnings.append(warning)
        // Self-dismiss so mid-show banners never need mouse attention.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            self?.warnings.removeAll { $0.id == warning.id }
        }
    }

    func dismissWarning(_ id: UUID) {
        warnings.removeAll { $0.id == id }
    }

    // MARK: - Selection ⇄ playhead sync (the selected cue stands by)

    func selectionChanged() {
        if document.selection.count == 1, let id = document.selection.first {
            transport.setPlayhead(id)
        }
    }

    func playheadChanged() {
        if let id = transport.playheadID {
            document.selection = [id]
        }
    }
}
