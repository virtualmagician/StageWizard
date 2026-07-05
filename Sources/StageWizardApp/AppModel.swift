import AppKit
import AVFoundation
import Observation

/// Composition root: owns the document, transport, and shortcut manager and
/// wires them together. Created once at app launch.
@MainActor
@Observable
final class AppModel {
    let document: ShowDocumentController
    let transport: TransportController
    let shortcuts: ShortcutManager

    struct OperatorWarning: Identifiable {
        let id = UUID()
        let message: String
        let date = Date()
        var actionTitle: String?
        var action: (@MainActor () -> Void)?
    }

    /// Recent operator-facing warnings (broken media, missing devices…).
    private(set) var warnings: [OperatorWarning] = []

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

    /// Switch workspace mode. Stops all playback first (cues must re-arm
    /// against the new routing), opens/closes rehearsal previews, and — for
    /// user-initiated switches — records the mode in the show file.
    func setMode(_ newMode: WorkspaceMode, persist: Bool = true) {
        guard newMode != mode else { return }
        transport.stopAll()
        if mode == .rehearsal {
            OutputWindowManager.shared.closeAllPreviews()
        }
        mode = newMode
        if newMode == .rehearsal {
            openRehearsalPreviews()
        }
        if newMode != .edit {
            // Pre-show check: surface permission problems BEFORE the first GO.
            checkPermissionsForCurrentShow()
        }
        if persist, document.show.settings.workspaceMode != newMode {
            document.mutate { $0.settings.workspaceMode = newMode }
        }
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
        self.transport = TransportController(
            provider: provider,
            show: { document.show },
            showFolder: { document.showFolder }
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
        document.onRecentsChanged = { [weak self] in
            self?.refreshRecents()
        }
        refreshRecents()
        document.onDocumentReplaced = { [weak self] in
            guard let self else { return }
            self.transport.reset()
            self.checkPermissionsForCurrentShow()
            // Restore the saved workspace mode without re-dirtying the
            // freshly opened document.
            self.setMode(self.document.show.settings.workspaceMode, persist: false)
        }

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
        shortcuts.onCueHotkey = { [weak self] cueID in self?.transport.fire(cueID: cueID) }
        shortcuts.onAction = { [weak self] action in self?.perform(action) }
        shortcuts.install()
    }

    private func wireEngines(provider: EnginePlayerProvider) {
        provider.onWarning = { [weak self] message in
            self?.pushWarning(message)
        }
        provider.rehearsalActive = { [weak self] in
            self?.mode == .rehearsal
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

    private func perform(_ action: ShortcutAction) {
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
