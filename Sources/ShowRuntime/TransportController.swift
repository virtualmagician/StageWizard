import Foundation
import Observation

/// The show brain: playhead, GO, follows, panic. All @MainActor — a single
/// actor eliminates races between GO, panic, follows, and hot-plug events.
@MainActor
@Observable
public final class TransportController {
    public let registry = ActiveCuesRegistry()

    /// Standing-by cue (top-level id). GO fires this.
    public private(set) var playheadID: UUID?
    /// True once the playhead has run off the end of the list — GO must then
    /// do NOTHING (never wrap around and restart the show).
    private var playheadPastEnd = false
    /// True while a soft panic ramp is in flight (UI shows PANIC state).
    public private(set) var isPanicking = false

    /// Gates the 1 Hz wall-clock scheduler. AppModel sets this true only in
    /// .show and .rehearsal modes — Edit mode never fires wall-clock cues.
    public var wallClockEnabled = false {
        didSet {
            guard wallClockEnabled != oldValue else { return }
            if wallClockEnabled {
                startWallClockTask()
            } else {
                stopWallClockTask()
            }
        }
    }

    /// Injectable "seconds since local midnight" clock — overridden in tests
    /// to drive the scheduler deterministically without real sleeps.
    public var now: () -> TimeInterval = { TransportController.secondsSinceLocalMidnight(Date()) }

    private var wallClockTask: Task<Void, Never>?
    /// Seconds-since-midnight as of the previous tick; nil until the first
    /// tick establishes a baseline (so cues due earlier the same day don't
    /// all fire the moment wall-clock scheduling is enabled).
    private var lastWallClockTick: TimeInterval?
    /// Cues that have already fired today, so a cue fires at most once per
    /// day even though the tick that covers its target keeps recurring.
    private var wallClockFiredToday: Set<UUID> = []

    public var onOperatorWarning: (@MainActor (String) -> Void)?
    /// Playback-activity signal (document autosave pauses while true).
    public var onPlaybackActivityChanged: (@MainActor (Bool) -> Void)?

    private let provider: CuePlayerProviding
    private let show: () -> ShowFile
    private let showFolder: () -> URL?

    private var lastGoAt: ContinuousClock.Instant?
    private var lastPanicAt: ContinuousClock.Instant?
    private var panicSettleTask: Task<Void, Never>?

    /// Pending auto-continue timers, keyed by source instance id. Pausable.
    private var pendingFollows: [UUID: PendingFollow] = [:]

    private struct PendingFollow {
        let nextCueID: UUID
        var remaining: TimeInterval
        var startedAt: ContinuousClock.Instant?
        var task: Task<Void, Never>?
    }

    public init(
        provider: CuePlayerProviding,
        show: @escaping () -> ShowFile,
        showFolder: @escaping () -> URL?
    ) {
        self.provider = provider
        self.show = show
        self.showFolder = showFolder
    }

    private var settings: ShowSettings { show().settings }

    // MARK: - Playhead / GO sequence

    /// The GO-able positions of the show, top to bottom. Enter-and-play-first
    /// groups contribute their CHILDREN (the header is an entry point, not a
    /// stop): GO walks through a slide deck cue by cue, then exits.
    public var goSequence: [Cue] {
        let currentShow = show()
        var sequence: [Cue] = []
        for cue in currentShow.topLevelCues {
            if case .group(let body) = cue.body, body.mode == .enterAndPlayFirst {
                sequence.append(contentsOf: currentShow.children(of: cue.id))
            } else {
                sequence.append(cue)
            }
        }
        return sequence
    }

    public var standingByCue: Cue? {
        guard !playheadPastEnd else { return nil }
        let sequence = goSequence
        if let playheadID { return sequence.first { $0.id == playheadID } }
        return sequence.first
    }

    /// True once GO has run off the end of the show (see `playheadPastEnd`) —
    /// distinguishes "past the last cue" from "nothing to stand by" (e.g. an
    /// empty show) for UI that needs to tell them apart, like the stage display.
    public var isPlayheadPastEnd: Bool { playheadPastEnd }

    public func setPlayhead(_ cueID: UUID?) {
        guard let cueID else {
            playheadID = nil
            return
        }
        guard let cue = show().cue(withID: cueID) else { return }
        // Selecting an enter-group header stands its first child by.
        if case .group(let body) = cue.body, body.mode == .enterAndPlayFirst {
            if let first = show().children(of: cue.id).first {
                playheadID = first.id
                playheadPastEnd = false
            }
            return
        }
        // Otherwise the playhead stands on any GO-able position.
        if goSequence.contains(where: { $0.id == cueID }) {
            playheadID = cueID
            playheadPastEnd = false
        }
    }

    public func movePlayhead(by delta: Int) {
        let sequence = goSequence
        guard !sequence.isEmpty else { return }
        if playheadPastEnd {
            // Stepping back from past-the-end re-arms the last cue.
            if delta < 0 {
                playheadPastEnd = false
                playheadID = sequence.last?.id
            }
            return
        }
        let current = standingByCue.flatMap { cue in sequence.firstIndex { $0.id == cue.id } } ?? 0
        let next = min(max(current + delta, 0), sequence.count - 1)
        playheadID = sequence[next].id
    }

    /// Called when a different show is opened/created: silence everything and
    /// forget stale playhead/panic state from the previous document.
    public func reset() {
        stopAll()
        panicSettleTask?.cancel()
        panicSettleTask = nil
        isPanicking = false
        playheadID = nil
        playheadPastEnd = false
        lastGoAt = nil
        lastPanicAt = nil
        lastWallClockTick = nil
        wallClockFiredToday.removeAll()
    }

    // MARK: - GO

    public func go() {
        guard !isPanicking else { return }
        let now = ContinuousClock.Instant.now
        if settings.doubleGOProtection > 0, let last = lastGoAt,
           last.duration(to: now).seconds < settings.doubleGOProtection {
            return
        }
        guard let standing = standingByCue else { return }
        guard let cue = resolveGOTarget(standing) else { return }
        lastGoAt = now
        fire(cue)
        advancePlayheadPastChain(from: cue)
    }

    /// Fire a specific cue directly (per-cue hotkeys, double-click).
    /// After an undo/redo the playhead's cue may no longer exist — or may
    /// still exist but have left the GO sequence (moved into a fire-all/
    /// timeline group, or its group's mode changed). Either way standingByCue
    /// would return nil and GO would go silently dead: clear the playhead so
    /// GO stands by the first cue again.
    public func revalidatePlayhead() {
        if let id = playheadID, !goSequence.contains(where: { $0.id == id }) {
            playheadID = nil
            playheadPastEnd = false
        }
    }

    public func fire(cueID: UUID) {
        guard !isPanicking, let raw = show().cue(withID: cueID),
              let cue = resolveGOTarget(raw) else { return }
        fire(cue)
    }

    /// Enter-and-play-first group headers resolve to their first child.
    private func resolveGOTarget(_ cue: Cue) -> Cue? {
        if case .group(let body) = cue.body, body.mode == .enterAndPlayFirst {
            let children = show().children(of: cue.id)
            if children.isEmpty {
                onOperatorWarning?("Group \(cue.number) is empty — nothing to play.")
                return nil
            }
            return children[0]
        }
        return cue
    }

    private func fire(_ cue: Cue) {
        let instance = makeInstance(for: cue)
        registry.add(instance)
        notifyActivity()

        // Auto-continue: anchored to fire time + preWait + postWait, independent
        // of the cue's duration. Armed regardless of how the action goes.
        if case .autoContinue(let postWait) = cue.follow, let next = nextCue(after: cue) {
            schedulePendingFollow(
                sourceInstance: instance.id,
                nextCueID: next.id,
                delay: cue.preWait + postWait
            )
        } else if case .autoContinueAtMarker(let markerID) = cue.follow, let next = nextCue(after: cue),
                  let delay = markerDelay(for: cue, markerID: markerID) {
            // A marker id that no longer resolves (deleted) is a silent
            // no-op — no follow is armed at all, same "no surprise fire"
            // spirit as a fade cue with no target.
            schedulePendingFollow(
                sourceInstance: instance.id,
                nextCueID: next.id,
                delay: delay
            )
        }
        instance.begin()
    }

    /// Wall-clock delay from cue fire to the moment playback reaches
    /// `markerID`, folding in preWait, the in-point trim, and rate. Audio/
    /// video only; nil if the body doesn't carry that marker (e.g. deleted).
    private func markerDelay(for cue: Cue, markerID: UUID) -> TimeInterval? {
        let markers: [CueMarker]
        let startTime: TimeInterval
        let endTime: TimeInterval?
        let rate: Double
        switch cue.body {
        case .audio(let body):
            markers = body.markers
            startTime = body.startTime
            endTime = body.endTime
            rate = body.rate
        case .video(let body):
            markers = body.markers
            startTime = body.startTime
            endTime = body.endTime
            rate = body.rate
        default:
            return nil
        }
        guard let marker = markers.first(where: { $0.id == markerID }) else { return nil }
        // A marker beyond the trimmed OUT point would arm a follow after the
        // cue has already ended — mirror the deleted-marker rule above:
        // silent no-arm, no clamping.
        if let endTime, marker.time > endTime { return nil }
        let mediaOffset = max(0, marker.time - startTime) / rate
        return cue.preWait + mediaOffset
    }

    private func makeInstance(for cue: Cue) -> CueInstance {
        let environment = CueInstance.RuntimeEnvironment(
            provider: provider,
            showFolder: showFolder,
            activeInstances: { [weak self] in self?.registry.instances ?? [] },
            childrenOf: { [weak self] id in self?.show().children(of: id) ?? [] },
            warn: { [weak self] message in self?.onOperatorWarning?(message) }
        )
        let instance = CueInstance(cue: cue, environment: environment)
        instance.onChildSpawned = { [weak self] child in
            self?.adoptChild(child)
        }
        instance.onActionCompleted = { [weak self] instance in
            self?.actionCompleted(for: instance)
        }
        instance.onActionStarted = { [weak self] instance in
            self?.actionStarted(for: instance)
        }
        instance.onTerminated = { [weak self] instance in
            self?.instanceTerminated(instance)
        }
        return instance
    }

    /// Slide semantics: starting a slide crossfades out other slides running
    /// on the SAME output (the new one is layered above, so it reads as a
    /// crossfade). Different outputs are untouched.
    private func actionStarted(for instance: CueInstance) {
        guard case .slide(let body) = instance.cue.body, body.replacesPreviousSlide else { return }
        let fade = max(body.fadeInDuration, 0.15)
        for other in registry.instances where other.id != instance.id && !other.state.isTerminal {
            if case .slide(let otherBody) = other.cue.body, otherBody.outputGroupID == body.outputGroupID {
                other.fadeOutAndStop(duration: fade)
            }
        }
    }

    private func adoptChild(_ child: CueInstance) {
        registry.add(child)
        child.onActionCompleted = { [weak self] instance in
            self?.actionCompleted(for: instance)
        }
        child.onActionStarted = { [weak self] instance in
            self?.actionStarted(for: instance)
        }
        // Nested groups: grandchildren must be adopted too or they are
        // invisible to the panel and untargetable by fade/stop cues.
        child.onChildSpawned = { [weak self] grandchild in
            self?.adoptChild(grandchild)
        }
        let existing = child.onTerminated
        child.onTerminated = { [weak self] instance in
            existing?(instance)
            self?.instanceTerminated(instance)
        }
    }

    private func actionCompleted(for instance: CueInstance) {
        // Auto-follow: next cue fires when this cue's action completes.
        guard case .autoFollow = instance.cue.follow else { return }
        // fireAll/timeline children don't chain (offsets sequence them), but
        // enter-and-play-first children DO — they're GO-sequence members.
        if let parentID = instance.cue.parentID {
            guard let parent = show().cue(withID: parentID),
                  case .group(let body) = parent.body,
                  body.mode == .enterAndPlayFirst else { return }
        }
        if let next = nextCue(after: instance.cue) {
            fire(next)
        }
    }

    private func instanceTerminated(_ instance: CueInstance) {
        // Holding instances stay visible; terminal ones leave the panel.
        registry.remove(instance)
        notifyActivity()
    }

    /// Next cue in the same scope: siblings for group children, the GO
    /// sequence at top level. Enter-group children chain within their deck.
    private func nextCue(after cue: Cue) -> Cue? {
        let siblings = cue.parentID.map { show().children(of: $0) } ?? show().topLevelCues
        guard let index = siblings.firstIndex(where: { $0.id == cue.id }) else { return nil }
        return siblings.indices.contains(index + 1) ? siblings[index + 1] : nil
    }

    /// After GO, the playhead skips the auto-fired chain and stands on the
    /// next GO-able position (standard cue-list convention). The sequence
    /// walks INTO enter-and-play-first groups and out their far side.
    private func advancePlayheadPastChain(from cue: Cue) {
        let sequence = goSequence
        guard var index = sequence.firstIndex(where: { $0.id == cue.id }) else { return }
        while index < sequence.count, sequence[index].follow != FollowAction.none {
            index += 1
        }
        if index + 1 < sequence.count {
            playheadID = sequence[index + 1].id
        } else {
            playheadID = nil
            playheadPastEnd = true   // end of show: GO goes dead, no wraparound
        }
    }

    // MARK: - Pending follows (auto-continue timers)

    private func schedulePendingFollow(sourceInstance: UUID, nextCueID: UUID, delay: TimeInterval) {
        var pending = PendingFollow(nextCueID: nextCueID, remaining: delay)
        pending.startedAt = .now
        pending.task = makeFollowTask(sourceInstance: sourceInstance, delay: delay)
        pendingFollows[sourceInstance] = pending
    }

    private func makeFollowTask(sourceInstance: UUID, delay: TimeInterval) -> Task<Void, Never> {
        Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled, let self else { return }
            guard let pending = self.pendingFollows.removeValue(forKey: sourceInstance) else { return }
            guard let next = self.show().cue(withID: pending.nextCueID) else { return }
            self.fire(next)
        }
    }

    private func pausePendingFollows() {
        // Copy-modify-writeback: in-place `dict[key]?.x = f(dict[key])` is an
        // exclusivity violation (fatal access conflict).
        for key in pendingFollows.keys {
            guard var pending = pendingFollows[key] else { continue }
            if let started = pending.startedAt {
                pending.remaining = max(0, pending.remaining - started.duration(to: .now).seconds)
            }
            pending.task?.cancel()
            pending.task = nil
            pending.startedAt = nil
            pendingFollows[key] = pending
        }
    }

    private func resumePendingFollows() {
        for key in pendingFollows.keys {
            guard var pending = pendingFollows[key], pending.task == nil else { continue }
            pending.startedAt = .now
            pending.task = makeFollowTask(sourceInstance: key, delay: pending.remaining)
            pendingFollows[key] = pending
        }
    }

    private func cancelPendingFollows() {
        for pending in pendingFollows.values {
            pending.task?.cancel()
        }
        pendingFollows.removeAll()
    }

    // MARK: - Wall-clock triggers

    private func startWallClockTask() {
        wallClockTask?.cancel()
        lastWallClockTick = nil   // re-baseline: no firing on the very first tick
        wallClockTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.wallClockTick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func stopWallClockTask() {
        wallClockTask?.cancel()
        wallClockTask = nil
    }

    /// One scheduler tick: fires every armed, wall-clock-tagged cue whose
    /// target time landed in (previousTick, nowTick] since the last tick —
    /// at most once per cue per day. Not private so tests can call it
    /// directly instead of waiting on the real 1 Hz Task loop.
    func wallClockTick() {
        let nowTick = now()
        defer { lastWallClockTick = nowTick }
        // First tick after enabling: establish a baseline only. Without this
        // every cue whose time already passed earlier today would fire the
        // instant wall-clock scheduling turns on.
        guard let previousTick = lastWallClockTick else { return }

        // Sleep/wake (or any large forward jump): the window since the last
        // tick is stale, not a live 1-second slice — firing every cue whose
        // target fell inside it would barrage cues that were legitimately
        // skipped while the Mac was asleep. Re-baseline only (the defer
        // above already advances lastWallClockTick); don't clear firedToday.
        if nowTick - previousTick > 5 {
            return
        }

        // Midnight rolled over since the last tick: every cue gets a fresh
        // day — but only when the backwards jump is small enough to actually
        // be a rollover (previousTick close to end-of-day, nowTick close to
        // start-of-day). A larger backwards jump is a clock step (NTP
        // correction, manual time change), not a genuine midnight wrap:
        // re-baseline only and keep today's already-fired cues fired.
        if nowTick < previousTick {
            let wrapDistance = (86400 - previousTick) + nowTick
            guard wrapDistance <= 5 else { return }
            wallClockFiredToday.removeAll()
        }
        guard !isPanicking else { return }

        let due = Self.dueCues(
            between: previousTick,
            and: nowTick,
            in: show().cues,
            already: wallClockFiredToday
        )
        for cue in due {
            wallClockFiredToday.insert(cue.id)
            fire(cueID: cue.id)
        }
    }

    /// Pure core of the tick: which armed cues have a `wallClock` target in
    /// (previousTick, nowTick] and haven't already fired today. Handles the
    /// midnight wrap (nowTick < previousTick) by treating the window as the
    /// union of (previousTick, 86400] and [0, nowTick].
    static func dueCues(
        between previousTick: TimeInterval,
        and nowTick: TimeInterval,
        in cues: [Cue],
        already fired: Set<UUID>
    ) -> [Cue] {
        cues.filter { cue in
            guard cue.armed, let target = cue.wallClock, !fired.contains(cue.id) else { return false }
            if previousTick <= nowTick {
                return target > previousTick && target <= nowTick
            } else {
                return target > previousTick || target <= nowTick
            }
        }
    }

    /// Real-world "seconds since local midnight" — the default `now` clock.
    static func secondsSinceLocalMidnight(_ date: Date) -> TimeInterval {
        date.timeIntervalSince(Calendar.current.startOfDay(for: date))
    }

    // MARK: - Transport verbs

    public func pauseAll() {
        pausePendingFollows()
        // Group instances cascade to their children; direct calls on children
        // are harmless (pause/resume are state-guarded and idempotent).
        for instance in registry.instances {
            instance.pause()
        }
    }

    public func resumeAll() {
        guard !isPanicking else { return }
        resumePendingFollows()
        for instance in registry.instances {
            instance.resume()
        }
    }

    public func stopAll() {
        cancelPendingFollows()
        for instance in registry.instances {
            instance.stop()
        }
        notifyActivity()
    }

    /// Soft panic: fade EVERYTHING to silence/black over panicDuration and
    /// cancel all pending sequencing. A second panic within the ramp window
    /// hard-stops instantly. Esc is hardwired to this.
    public func panic() {
        let now = ContinuousClock.Instant.now
        let window = max(settings.panicDuration, 0.5)
        if let last = lastPanicAt, last.duration(to: now).seconds < window {
            hardPanic()
            return
        }
        lastPanicAt = now
        cancelPendingFollows()
        panicSettleTask?.cancel()   // a stale settle sweep must not cut a new ramp

        let duration = settings.panicDuration
        guard duration > 0 else {
            hardPanic()
            return
        }
        isPanicking = true
        for instance in registry.instances {
            instance.fadeOutAndStop(duration: duration, curve: .dbLinear)
        }
        panicSettleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration + 0.25))
            guard !Task.isCancelled else { return }
            self?.finishPanic()
        }
    }

    private func hardPanic() {
        panicSettleTask?.cancel()
        cancelPendingFollows()
        for instance in registry.instances {
            instance.stop()
        }
        finishPanic()
    }

    private func finishPanic() {
        // Anything that survived the ramp (e.g. armed mid-panic) gets cut.
        for instance in registry.instances {
            instance.stop()
        }
        isPanicking = false
        panicSettleTask = nil
        notifyActivity()
    }

    private func notifyActivity() {
        onPlaybackActivityChanged?(!registry.isEmpty)
    }
}
