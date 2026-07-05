import Foundation
import Observation

/// A single playback of a cue. Definitions (Cue) are immutable value types;
/// all runtime state lives here. Instance identity ≠ cue identity: firing the
/// same cue twice yields two independent instances.
@MainActor
@Observable
public final class CueInstance: Identifiable {
    public enum State: Equatable, Sendable {
        case pending
        case preWait
        case running
        /// Video holdLastFrame after its natural end: output stays live,
        /// instance stays in Active Cues until explicitly stopped.
        case holding
        case paused
        case fadingOut
        case completed
        case stopped
        case error(String)

        public var isTerminal: Bool {
            switch self {
            case .completed, .stopped, .error: return true
            default: return false
            }
        }
    }

    public let id = UUID()
    /// Immutable snapshot taken at fire time — mid-show edits don't affect
    /// already-running instances.
    public let cue: Cue
    public private(set) var state: State = .pending
    public private(set) var player: MediaPlayback?
    /// Child instances (group cues only).
    public private(set) var children: [CueInstance] = []

    /// Fires once per lifecycle when the cue's ACTION completes naturally —
    /// this is the auto-follow anchor. (holdLastFrame: fires when the video
    /// reaches its out-point, while the instance keeps holding.)
    var onActionCompleted: (@MainActor (CueInstance) -> Void)?
    /// Fires when the instance leaves the active set (terminal state).
    var onTerminated: (@MainActor (CueInstance) -> Void)?
    /// Fires when the action begins (after pre-wait) — the auto-continue anchor
    /// is NOT this; auto-continue anchors to fire time + preWait + postWait via
    /// the transport. This is for arming/UI.
    var onActionStarted: (@MainActor (CueInstance) -> Void)?

    private let environment: RuntimeEnvironment
    private var actionCompletedFired = false

    // Wait bookkeeping: pausable, cancellable pre-wait.
    private var preWaitRemaining: TimeInterval = 0
    private var preWaitStartedAt: ContinuousClock.Instant?
    private var preWaitTask: Task<Void, Never>?

    // Group child scheduling (timeline offsets), pausable as a set.
    private var childSchedules: [ChildSchedule] = []

    private struct ChildSchedule {
        let childCue: Cue
        var remaining: TimeInterval
        var startedAt: ContinuousClock.Instant?
        var task: Task<Void, Never>?
        var fired = false
    }

    /// Everything an instance needs from the outside world.
    @MainActor
    struct RuntimeEnvironment {
        let provider: CuePlayerProviding
        let showFolder: () -> URL?
        /// Live instances a fade/stop cue resolves its target against.
        let activeInstances: () -> [CueInstance]
        /// Group children lookup (document order).
        let childrenOf: (UUID) -> [Cue]
        let warn: (String) -> Void
    }

    init(cue: Cue, environment: RuntimeEnvironment, preArmedPlayer: MediaPlayback? = nil) {
        self.cue = cue
        self.environment = environment
        self.player = preArmedPlayer
    }

    // MARK: - Progress (UI)

    public var elapsed: TimeInterval? {
        guard let player else { return nil }
        return player.currentTime - mediaStartTime
    }

    public var duration: TimeInterval? {
        player?.duration
    }

    private var mediaStartTime: TimeInterval {
        switch cue.body {
        case .audio(let b): return b.startTime
        case .video(let b): return b.startTime
        default: return 0
        }
    }

    // MARK: - Lifecycle

    func begin() {
        guard state == .pending else { return }
        if cue.preWait > 0 {
            state = .preWait
            preWaitRemaining = cue.preWait
            armPreWaitTask()
        } else {
            executeAction()
        }
    }

    private func armPreWaitTask() {
        preWaitStartedAt = .now
        let remaining = preWaitRemaining
        preWaitTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
            self?.executeAction()
        }
    }

    private func executeAction() {
        guard state == .pending || state == .preWait else { return }
        state = .running
        onActionStarted?(self)

        // Disarmed cues honor waits/follows but skip their action.
        guard cue.armed else {
            completeAction()
            finish(.completed)
            return
        }

        switch cue.body {
        case .audio, .video, .camera, .image, .slide:
            runMediaAction()
        case .fade(let body):
            runFadeAction(body)
        case .stop(let body):
            runStopAction(body)
            completeAction()
            finish(.completed)
        case .group(let body):
            runGroupAction(body)
        case .broken:
            fail("Unsupported cue type")
        }
    }

    // MARK: - Media action

    private func runMediaAction() {
        if let player {
            attachAndStart(player)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let player = try await environment.provider.armPlayer(
                    for: cue, showFolder: environment.showFolder()
                )
                switch state {
                case .running:
                    self.player = player
                    attachAndStart(player)
                case .paused:
                    // Paused while arming: keep the armed player; resume()
                    // performs the deferred start.
                    self.player = player
                    player.onFinished = { [weak self] reason in
                        self?.playerFinished(reason)
                    }
                default:
                    player.stop()   // stopped/panicked while arming
                }
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    private var playerStarted = false

    private func attachAndStart(_ player: MediaPlayback) {
        player.onFinished = { [weak self] reason in
            self?.playerFinished(reason)
        }
        playerStarted = true
        player.start()
    }

    private func playerFinished(_ reason: PlaybackEndReason) {
        switch reason {
        case .natural:
            completeAction()
            if case .video(let body) = cue.body, body.endBehavior == .holdLastFrame,
               state == .running || state == .paused {
                state = .holding
            } else if !state.isTerminal {
                finish(.completed)
            }
        case .stopped:
            // Deliberately NO completeAction: a stopped cue must not fire its
            // auto-follow (panic/Stop All would launch the next cue on stage).
            if !state.isTerminal { finish(.stopped) }
        case .error(let message):
            fail(message)
        }
    }

    // MARK: - Fade action

    private func runFadeAction(_ body: FadeBody) {
        // A fade cue with no target is unconfigured — unlike a stop cue, nil
        // must NOT mean "everything" (fading the whole show to silence by
        // accident is a show-killer).
        guard let targetID = body.targetID else {
            environment.warn("Fade \(cue.number): no target assigned — skipped")
            completeAction()
            finish(.completed)
            return
        }
        let targets = resolveTargets(targetID)
        if targets.isEmpty {
            environment.warn("Fade \(cue.number): target not running — skipped")
        }
        let stops = body.stopTargetWhenDone
            && ((body.toVolumeDB.map { $0 <= silenceFloorDB } ?? false)
                || (body.toVolumeDB == nil && (body.toOpacity.map { $0 <= 0 } ?? false)))
        for target in targets {
            if stops {
                // One soft-stop path: handles groups (recurses into children),
                // pre-wait/arming instances (plain stop), and holding videos.
                if let toOpacity = body.toOpacity, toOpacity <= 0 {
                    target.player?.fadeOpacity(to: toOpacity, duration: body.duration)
                }
                target.fadeOutAndStop(duration: body.duration, curve: body.curve)
            } else {
                target.applyLevelFade(body)
            }
        }
        // The fade cue itself completes when its ramp is done.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(body.duration))
            guard let self, !self.state.isTerminal else { return }
            self.completeAction()
            self.finish(.completed)
        }
    }

    /// Non-stopping level/opacity fade; recurses into group children so fading
    /// a group actually fades what's audible.
    private func applyLevelFade(_ body: FadeBody) {
        if let toDB = body.toVolumeDB {
            player?.fadeVolume(toDB: toDB, duration: body.duration, curve: body.curve, thenStop: false)
        }
        if let toOpacity = body.toOpacity {
            player?.fadeOpacity(to: toOpacity, duration: body.duration)
        }
        for child in children where !child.state.isTerminal {
            child.applyLevelFade(body)
        }
    }

    // MARK: - Stop action

    private func runStopAction(_ body: StopBody) {
        let targets = resolveTargets(body.targetID)
        for target in targets where target.id != id {
            if body.fadeOutTime > 0 {
                target.fadeOutAndStop(duration: body.fadeOutTime, curve: body.curve)
            } else {
                target.stop()
            }
        }
    }

    private func resolveTargets(_ targetID: UUID?) -> [CueInstance] {
        let active = environment.activeInstances().filter { !$0.state.isTerminal }
        guard let targetID else { return active.filter { $0.id != id } }
        // Groups: targeting a group hits the group instance (which forwards to
        // children); targeting a cue hits every running instance of it.
        return active.filter { $0.cue.id == targetID }
    }

    // MARK: - Group action

    private func runGroupAction(_ body: GroupBody) {
        let childCues = environment.childrenOf(cue.id)
        guard !childCues.isEmpty else {
            completeAction()
            finish(.completed)
            return
        }
        for childCue in childCues {
            childSchedules.append(ChildSchedule(childCue: childCue, remaining: body.offset(for: childCue.id)))
        }
        for index in childSchedules.indices {
            armChildSchedule(at: index)
        }
    }

    private func armChildSchedule(at index: Int) {
        let schedule = childSchedules[index]
        guard !schedule.fired else { return }
        childSchedules[index].startedAt = .now
        let remaining = schedule.remaining
        childSchedules[index].task = Task { [weak self] in
            if remaining > 0 {
                try? await Task.sleep(for: .seconds(remaining))
            }
            guard !Task.isCancelled else { return }
            self?.fireChild(at: index)
        }
    }

    private func fireChild(at index: Int) {
        guard state == .running else { return }
        childSchedules[index].fired = true
        let child = CueInstance(cue: childSchedules[index].childCue, environment: environment)
        child.onTerminated = { [weak self] _ in self?.childDidTerminate() }
        children.append(child)
        onChildSpawned?(child)
        child.begin()
    }

    /// Transport hooks this to register children in the active-cues list.
    var onChildSpawned: (@MainActor (CueInstance) -> Void)?

    private func childDidTerminate() {
        guard state == .running || state == .paused || state == .fadingOut else { return }
        let allScheduled = childSchedules.allSatisfy { $0.fired }
        let allDone = children.allSatisfy { $0.state.isTerminal }
        guard allScheduled && allDone else { return }
        if state == .fadingOut {
            // Faded/stopped group: terminate without firing follows.
            finish(.stopped)
        } else {
            completeAction()
            finish(.completed)
        }
    }

    // MARK: - Transport verbs

    public func pause() {
        switch state {
        case .preWait:
            if let started = preWaitStartedAt {
                preWaitRemaining = max(0, preWaitRemaining - started.duration(to: .now).seconds)
            }
            preWaitTask?.cancel()
            preWaitTask = nil
            state = .paused
        case .running, .fadingOut:
            pauseChildSchedules()
            for child in children { child.pause() }
            player?.pause()
            state = .paused
        default:
            break
        }
    }

    public func resume() {
        guard state == .paused else { return }
        if player == nil && children.isEmpty && preWaitRemaining > 0 {
            state = .preWait
            armPreWaitTask()
            return
        }
        resumeChildSchedules()
        for child in children { child.resume() }
        if let player {
            if playerStarted {
                player.resume()
            } else {
                // Armed while paused — this is the deferred GO.
                playerStarted = true
                player.start()
            }
        }
        state = .running
    }

    private func pauseChildSchedules() {
        // Copy-modify-writeback to avoid an exclusivity conflict (the RHS must
        // not read the array element being mutated in place).
        for index in childSchedules.indices where !childSchedules[index].fired {
            var schedule = childSchedules[index]
            if let started = schedule.startedAt {
                schedule.remaining = max(0, schedule.remaining - started.duration(to: .now).seconds)
            }
            schedule.task?.cancel()
            schedule.task = nil
            schedule.startedAt = nil
            childSchedules[index] = schedule
        }
    }

    private func resumeChildSchedules() {
        for index in childSchedules.indices where !childSchedules[index].fired {
            armChildSchedule(at: index)
        }
    }

    /// Hard stop — cancels waits, stops the player and children. Idempotent.
    /// Never fires the auto-follow (stopping a cue must not launch the next),
    /// and terminates directly rather than relying on the player callback —
    /// a holding (holdLastFrame) player already fired its once-only onFinished
    /// at the out-point and will not call back again.
    public func stop() {
        guard !state.isTerminal else { return }
        cancelPendingWork()
        for child in children { child.stop() }
        player?.stop()
        finish(.stopped)
    }

    /// Fade to silence/black over `duration`, then stop. The one soft-stop path:
    /// stop cues, panic, and the Active Cues panel all use this.
    public func fadeOutAndStop(duration: TimeInterval, curve: FadeCurve = .dbLinear) {
        guard !state.isTerminal else { return }
        guard duration > 0 else { return stop() }
        switch state {
        case .preWait, .paused, .pending:
            // Nothing audible yet — just stop.
            stop()
        case .running, .holding, .fadingOut:
            cancelPendingWork()
            for child in children { child.fadeOutAndStop(duration: duration, curve: curve) }
            if let player {
                state = .fadingOut
                player.fadeOpacity(to: 0, duration: duration)
                player.fadeVolume(toDB: silenceFloorDB, duration: duration, curve: curve, thenStop: true)
                // Safety net: a holding player already fired its once-only
                // onFinished, and a preempted fade can skip thenStop — make
                // sure the instance always terminates after the ramp.
                fadeSettleTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(duration + 0.35))
                    guard !Task.isCancelled else { return }
                    self?.stop()
                }
            } else if children.isEmpty {
                stop()
            } else {
                state = .fadingOut
            }
        case .completed, .stopped, .error:
            break
        }
    }

    private var fadeSettleTask: Task<Void, Never>?

    // MARK: - Terminal handling

    private func cancelPendingWork() {
        preWaitTask?.cancel()
        preWaitTask = nil
        for index in childSchedules.indices {
            childSchedules[index].task?.cancel()
            childSchedules[index].task = nil
            childSchedules[index].fired = true
        }
    }

    private func completeAction() {
        guard !actionCompletedFired else { return }
        actionCompletedFired = true
        onActionCompleted?(self)
    }

    private func fail(_ message: String) {
        guard !state.isTerminal else { return }
        environment.warn("Cue \(cue.number) failed: \(message)")
        cancelPendingWork()
        // The show must go on: a failed cue still completes its action so
        // auto-follows fire and the sequence continues.
        completeAction()
        finish(.error(message))
    }

    private func finish(_ terminal: State) {
        guard !state.isTerminal else { return }
        fadeSettleTask?.cancel()
        fadeSettleTask = nil
        state = terminal
        onTerminated?(self)
    }
}

extension Duration {
    var seconds: TimeInterval {
        TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
