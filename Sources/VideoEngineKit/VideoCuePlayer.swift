import AVFoundation
import AppKit
import QuartzCore

/// Errors thrown while arming a video cue.
public enum VideoEngineError: Error, LocalizedError {
    case notPlayable(String)
    case emptyTimeRange
    case displayNotConnected(CGDirectDisplayID)
    case windowUnavailable
    case itemFailed(String)
    case looperFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notPlayable(let name): return "“\(name)” can't be played by AVFoundation."
        case .emptyTimeRange: return "The cue's trim range is empty."
        case .displayNotConnected(let id): return "Display \(id) is not connected."
        case .windowUnavailable: return "Couldn't create an output window."
        case .itemFailed(let why): return "The media failed to load: \(why)"
        case .looperFailed(let why): return "Loop setup failed: \(why)"
        }
    }
}

/// Lock-guarded live level (dB) shared with FadeClock's off-main `apply`
/// closures — the only cross-thread mutable state in the player.
private final class VolumeLevelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var db: Double

    init(_ db: Double) { self.db = db }

    var value: Double {
        get { lock.withLock { db } }
        set { lock.withLock { db = newValue } }
    }
}

/// One armed/running video cue playback: AVQueuePlayer + AVPlayerLayer inside
/// an OutputWindowManager window. Created fully ARMED (asset loaded, layer
/// attached at opacity 0, item ready, zero-tolerance seek to the in-point,
/// prerolled) so `start()` is GO-instant.
///
/// Concurrency: everything is MainActor-confined. The only sanctioned off-main
/// mutation is the documented-thread-safe `AVPlayer.volume` setter driven by
/// FadeClock's apply closures; opacity ramps run as CABasicAnimations on the
/// render server (immune to main-thread hiccups).
@MainActor
public final class VideoCuePlayer: MediaPlayback {

    // AVFoundation graph — MainActor-confined except `player.volume` (above).
    let player: AVQueuePlayer
    /// One layer per target display — a group can mirror onto several.
    let playerLayers: [AVPlayerLayer]
    private let originalItem: AVPlayerItem
    private let looper: AVPlayerLooper?

    /// Where this cue renders (real displays and/or rehearsal previews).
    public let targets: [OutputTarget]
    /// Real displays only — the app's unplug sweep checks these.
    public var displayIDs: [CGDirectDisplayID] { targets.compactMap(\.displayID) }
    private var fillModeSetting: FillMode
    private var geometrySetting: VideoGeometry
    private let endBehavior: VideoEndBehavior
    private let fadeInDuration: TimeInterval
    private let fadeOutDuration: TimeInterval
    private let authoredVolumeDB: Double
    /// Trim points in media time, clamped to the real asset duration.
    private let passStart: TimeInterval
    private let passEnd: TimeInterval
    private let playCount: Int
    private let infiniteLoop: Bool
    private let wantsLooping: Bool

    private let volumeBox: VolumeLevelBox
    private var loopObservation: NSKeyValueObservation?
    private var endObserver: (any NSObjectProtocol)?
    private var fadeOutTask: Task<Void, Never>?

    private var started = false
    private var pausedFlag = false
    private var stopped = false
    private var loopingDisabled = false
    private var finishedNaturally = false
    private var reportedEnd = false
    private var outputTornDown = false

    public var onFinished: (@MainActor (PlaybackEndReason) -> Void)?

    private static let opacityAnimationKey = "stagewizard.opacityFade"

    // MARK: - Arm

    /// Arm pipeline (GO-instant start): load asset properties → player item
    /// (+ forwardPlaybackEndTime) → AVQueuePlayer (always, so AVPlayerLooper
    /// can attach) → audio device + volume at arm → AVPlayerLayer at opacity 0
    /// in the display's output window → wait .readyToPlay → zero-tolerance
    /// seek to the in-point → preroll.
    /// Single-display convenience (tests, legacy call sites).
    public static func arm(
        body: VideoBody,
        fileURL: URL,
        displayID: CGDirectDisplayID,
        windowFrameOverride: CGRect? = nil
    ) async throws -> VideoCuePlayer {
        try await arm(body: body, fileURL: fileURL, targets: [.display(displayID)], windowFrameOverride: windowFrameOverride)
    }

    /// Multi-display convenience.
    public static func arm(
        body: VideoBody,
        fileURL: URL,
        displayIDs: [CGDirectDisplayID],
        windowFrameOverride: CGRect? = nil
    ) async throws -> VideoCuePlayer {
        try await arm(body: body, fileURL: fileURL, targets: displayIDs.map { .display($0) }, windowFrameOverride: windowFrameOverride)
    }

    public static func arm(
        body: VideoBody,
        fileURL: URL,
        targets: [OutputTarget],
        windowFrameOverride: CGRect? = nil
    ) async throws -> VideoCuePlayer {
        let asset = AVURLAsset(url: fileURL)
        let (duration, _, isPlayable) = try await asset.load(.duration, .tracks, .isPlayable)
        guard isPlayable else {
            throw VideoEngineError.notPlayable(fileURL.lastPathComponent)
        }
        let instance = try VideoCuePlayer(
            body: body,
            asset: asset,
            assetDuration: duration.seconds,
            targets: targets,
            windowFrameOverride: windowFrameOverride
        )
        do {
            try await instance.completeArm()
        } catch {
            instance.stop() // releases the window lease; nothing listens yet
            throw error
        }
        return instance
    }

    private init(
        body: VideoBody,
        asset: AVURLAsset,
        assetDuration: TimeInterval,
        targets: [OutputTarget],
        windowFrameOverride: CGRect?
    ) throws {
        let start = min(max(0, body.startTime), assetDuration)
        // Out-point clamped to the real track duration (loopers with a range
        // past the end stall) — nil endTime = play to file end.
        let end = min(body.endTime ?? assetDuration, assetDuration)
        guard end > start else { throw VideoEngineError.emptyTimeRange }

        self.targets = targets
        self.fillModeSetting = body.fillMode
        self.geometrySetting = body.geometry
        self.endBehavior = body.endBehavior
        self.fadeInDuration = max(0, body.fadeInDuration)
        self.fadeOutDuration = max(0, body.fadeOutDuration)
        self.authoredVolumeDB = body.volumeDB
        self.passStart = start
        self.passEnd = end
        self.playCount = max(1, body.playCount)
        self.infiniteLoop = body.infiniteLoop
        self.wantsLooping = body.infiniteLoop || body.playCount > 1
        self.volumeBox = VolumeLevelBox(body.volumeDB)

        let startCM = CMTime(seconds: start, preferredTimescale: 600)
        let endCM = CMTime(seconds: end, preferredTimescale: 600)

        let item = AVPlayerItem(asset: asset)
        let player = AVQueuePlayer(items: [item])
        player.automaticallyWaitsToMinimizeStalling = false
        // Embedded-audio routing is set at arm and NEVER changed mid-play.
        player.audioOutputDeviceUniqueID = body.audioDeviceUID
        player.volume = Float(FadeCurve.amplitude(fromDB: body.volumeDB))

        if wantsLooping {
            // AVPlayerLooper owns the queue: hand it an empty player and the
            // template item; it enqueues trimmed copies itself.
            player.removeAllItems()
            let looper = AVPlayerLooper(
                player: player,
                templateItem: item,
                timeRange: CMTimeRange(start: startCM, end: endCM)
            )
            if looper.status == .failed {
                throw VideoEngineError.looperFailed(looper.error?.localizedDescription ?? "unknown")
            }
            self.looper = looper
        } else {
            if body.endTime != nil {
                // Ends playback at the out-point and posts
                // didPlayToEndTimeNotification exactly like a natural end.
                item.forwardPlaybackEndTime = endCM
            }
            // Hold the frame at end until we decide — never auto-blank a
            // visible layer (flash), even for .stopAndUnload.
            player.actionAtItemEnd = .pause
            self.looper = nil
        }

        self.player = player
        self.originalItem = item

        let gravity = body.geometry.gravity(fillMode: body.fillMode)
        var layers: [AVPlayerLayer] = []
        var leased: [OutputTarget] = []
        do {
            for target in targets {
                let host = try OutputWindowManager.shared.hostLayer(for: target, frameOverride: windowFrameOverride)
                leased.append(target)
                let layer = AVPlayerLayer(player: player)
                layer.videoGravity = gravity
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.frame = host.bounds
                layer.opacity = 0
                layer.zPosition = CGFloat(body.layer)
                host.addSublayer(layer)
                CATransaction.commit()
                layers.append(layer)
            }
        } catch {
            // Don't leak window leases acquired before the failure.
            for layer in layers { layer.removeFromSuperlayer() }
            for target in leased { OutputWindowManager.shared.releaseLayer(for: target) }
            throw error
        }
        self.playerLayers = layers
        if body.geometry.mode == .custom {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for layer in layers {
                body.geometry.apply(to: layer, fillMode: body.fillMode)
            }
            CATransaction.commit()
        }

        installEndObserver()
        if wantsLooping && !infiniteLoop {
            installLoopCountObserver()
        }
    }

    /// Wait for readiness, zero-tolerance seek to the in-point, preroll.
    private func completeArm() async throws {
        // The looper enqueues its item copies at init; guard against it being
        // momentarily async rather than hard-failing the arm.
        var polls = 0
        while player.currentItem == nil, polls < 200 {
            try await Task.sleep(for: .milliseconds(10))
            polls += 1
        }
        guard let current = player.currentItem else {
            throw VideoEngineError.looperFailed("looper produced no player item")
        }

        try await Self.waitUntilReadyToPlay(current)

        let startCM = CMTime(seconds: passStart, preferredTimescale: 600)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // Completion arrives on an arbitrary queue; it only resumes the
            // Sendable continuation.
            player.seek(to: startCM, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                continuation.resume()
            }
        }

        // Preroll so GO is decode-warm. A false result is non-fatal (some
        // configurations refuse preroll); playback still starts, just colder.
        _ = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            player.preroll(atRate: 1) { finished in
                continuation.resume(returning: finished)
            }
        }
    }

    private static func waitUntilReadyToPlay(_ item: AVPlayerItem) async throws {
        switch item.status {
        case .readyToPlay: return
        case .failed: throw VideoEngineError.itemFailed(item.error?.localizedDescription ?? "unknown")
        default: break
        }

        /// Continuations must resume exactly once; KVO may race .initial/.new.
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            func first() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                if done { return false }
                done = true
                return true
            }
        }
        let once = Once()
        var observation: NSKeyValueObservation?
        defer {
            observation?.invalidate()
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // KVO fires on an arbitrary queue. The handler reads only the
            // item's status/error snapshot and resumes the Sendable
            // continuation; the item itself stays MainActor-owned.
            observation = item.observe(\.status, options: [.initial, .new]) { observed, _ in
                switch observed.status {
                case .readyToPlay:
                    if once.first() { continuation.resume() }
                case .failed:
                    if once.first() {
                        continuation.resume(throwing: VideoEngineError.itemFailed(
                            observed.error?.localizedDescription ?? "unknown"))
                    }
                default:
                    break
                }
            }
        }
    }

    // MARK: - MediaPlayback

    /// Trimmed single-pass duration.
    public var duration: TimeInterval? { passEnd - passStart }

    /// Position within the media file (media time, not wall clock).
    public var currentTime: TimeInterval { player.currentTime().seconds }

    public var isPaused: Bool { pausedFlag }

    public var currentVolumeDB: Double { volumeBox.value }

    /// GO. Everything slow already happened at arm.
    public func start() {
        guard !started, !stopped else { return }
        started = true
        if fadeInDuration > 0 {
            // Ramp from silence: land at exactly amplitude 0 before the first
            // sample, then let FadeClock walk up to the authored level.
            volumeBox.value = silenceFloorDB
            player.volume = 0
        }
        player.playImmediately(atRate: 1)
        if fadeInDuration > 0 {
            animateOpacity(to: 1, duration: fadeInDuration)
            rampVolume(fromDB: silenceFloorDB, toDB: authoredVolumeDB,
                       duration: fadeInDuration, curve: .dbLinear, thenStop: false)
        } else {
            animateOpacity(to: 1, duration: 0)
        }
        scheduleAuthoredFadeOutIfNeeded()
    }

    public func pause() {
        guard started, !stopped, !pausedFlag else { return }
        pausedFlag = true
        fadeOutTask?.cancel()
        fadeOutTask = nil
        player.pause()
    }

    public func resume() {
        guard started, !stopped, pausedFlag else { return }
        pausedFlag = false
        player.playImmediately(atRate: 1)
        scheduleAuthoredFadeOutIfNeeded() // re-anchor to the new remaining time
    }

    /// Hard stop: cancel fades, land at exactly amplitude 0, release the
    /// layer/window/items in one transaction. Idempotent; reports .stopped
    /// unless a natural end was already reported.
    public func stop() {
        guard !stopped else { return }
        stopped = true
        fadeOutTask?.cancel()
        fadeOutTask = nil
        FadeClock.shared.cancel(key: volumeFadeKey)
        loopObservation?.invalidate()
        loopObservation = nil
        removeEndObserver()
        // No-click invariant: exactly amplitude 0 BEFORE halting playback.
        player.volume = 0
        volumeBox.value = silenceFloorDB
        teardownOutput()
        reportFinished(.stopped)
    }

    public func setVolume(dB: Double) {
        guard !stopped else { return }
        FadeClock.shared.cancel(key: volumeFadeKey)
        volumeBox.value = dB
        player.volume = Float(FadeCurve.amplitude(fromDB: dB))
    }

    public func fadeVolume(toDB: Double, duration: TimeInterval, curve: FadeCurve, thenStop: Bool) {
        guard !stopped else { return }
        rampVolume(fromDB: volumeBox.value, toDB: toDB, duration: duration, curve: curve, thenStop: thenStop)
    }

    /// Ramp the output layer's opacity via CABasicAnimation — executed by the
    /// render server, immune to main-thread hiccups.
    public func fadeOpacity(to opacity: Double, duration: TimeInterval) {
        guard !stopped else { return }
        animateOpacity(to: Float(min(max(opacity, 0), 1)), duration: max(0, duration))
    }

    /// Leave an infinite/counted loop after the current pass completes.
    public func exitLoop() {
        guard wantsLooping, !loopingDisabled, !stopped, !finishedNaturally else { return }
        exitTargetPasses = endedPasses + 1   // the pass playing now is the last
        endLooping()
    }

    /// Live geometry update (inspector edits, preview-window resizes) —
    /// re-applies gravity + per-layer transform to every output layer.
    public func applyGeometry(_ geometry: VideoGeometry, fillMode: FillMode) {
        guard !stopped else { return }
        geometrySetting = geometry
        fillModeSetting = fillMode
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in playerLayers {
            geometry.apply(to: layer, fillMode: fillMode)
        }
        CATransaction.commit()
    }

    /// Live render-order change from the inspector (1 = back … 10 = front).
    public func applyRenderLayer(_ value: Int) {
        guard !stopped else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in playerLayers {
            layer.zPosition = CGFloat(value)
        }
        CATransaction.commit()
    }

    // MARK: - Preview

    /// Second AVPlayerLayer on the SAME player for the operator UI —
    /// AVFoundation renders one decode into both layers (never a second
    /// decode, never AVPlayerView).
    public func makePreviewLayer() -> AVPlayerLayer {
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        return layer
    }

    // MARK: - Loop bookkeeping

    private var loopingActive: Bool {
        wantsLooping && looper != nil && !loopingDisabled
    }

    private func installLoopCountObserver() {
        guard let looper else { return }
        loopObservation = looper.observe(\.loopCount, options: [.new]) { [weak self] _, change in
            guard let completedPasses = change.newValue else { return }
            // KVO arrives on an arbitrary queue → hop to the MainActor.
            Task { @MainActor in
                self?.handleLoopCountChanged(completedPasses)
            }
        }
    }

    private func handleLoopCountChanged(_ completedPasses: Int) {
        guard !infiniteLoop, !loopingDisabled, !stopped, !finishedNaturally else { return }
        // loopCount == playCount - 1 → the final pass is playing now.
        if completedPasses >= playCount - 1 {
            endLooping()
        }
    }

    private func endLooping() {
        loopingDisabled = true
        looper?.disableLooping()
        // Hold the final frame at end instead of advancing to a blank queue.
        player.actionAtItemEnd = .pause
        scheduleAuthoredFadeOutIfNeeded() // anchor the authored fade-out to the final pass
    }

    // MARK: - End detection

    private func installEndObserver() {
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: nil,
            queue: nil
        ) { [weak self] note in
            // Arbitrary queue. Only a Sendable identity token crosses to the
            // MainActor; the AVPlayerItem itself stays MainActor-owned.
            let identity = (note.object as AnyObject?).map(ObjectIdentifier.init)
            Task { @MainActor in
                self?.handleItemDidPlayToEnd(identity)
            }
        }
    }

    private func removeEndObserver() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
    }

    /// Completed passes, counted from end notifications on the MainActor.
    /// For looping cues the finish decision is made from THIS counter, never
    /// from `loopingActive`: the loopCount KVO (which disables looping at the
    /// final boundary) and that same boundary's end notification arrive as two
    /// unordered MainActor hops, so a flag check can finish one pass early.
    private var endedPasses = 0
    private var exitTargetPasses: Int?

    private func handleItemDidPlayToEnd(_ identity: ObjectIdentifier?) {
        guard !stopped, !finishedNaturally else { return }
        // Scope to the relevant item: the observer sees every player in the
        // process, and looper passes end with the same notification.
        guard let identity, ownedItemIdentities().contains(identity) else { return }

        if wantsLooping, looper != nil {
            endedPasses += 1
            if let target = exitTargetPasses {
                if endedPasses >= target { finishNaturally() }
            } else if !infiniteLoop, endedPasses >= playCount {
                finishNaturally()
            }
            return
        }
        finishNaturally()
    }

    private func ownedItemIdentities() -> Set<ObjectIdentifier> {
        var identities: Set<ObjectIdentifier> = [ObjectIdentifier(originalItem)]
        if let current = player.currentItem {
            identities.insert(ObjectIdentifier(current))
        }
        for item in player.items() {
            identities.insert(ObjectIdentifier(item))
        }
        if let looper {
            for item in looper.loopingPlayerItems {
                identities.insert(ObjectIdentifier(item))
            }
        }
        return identities
    }

    private func finishNaturally() {
        finishedNaturally = true
        fadeOutTask?.cancel()
        fadeOutTask = nil
        FadeClock.shared.cancel(key: volumeFadeKey)
        switch endBehavior {
        case .holdLastFrame:
            // Last frame persists (actionAtItemEnd == .pause); the layer and
            // window stay up. Resources are released by the eventual stop().
            reportFinished(.natural)
        case .stopAndUnload:
            loopObservation?.invalidate()
            loopObservation = nil
            removeEndObserver()
            teardownOutput()
            reportFinished(.natural)
        }
    }

    private func reportFinished(_ reason: PlaybackEndReason) {
        guard !reportedEnd else { return }
        reportedEnd = true
        onFinished?(reason)
    }

    /// Remove the layer and unload the player in ONE CATransaction — never
    /// blank a visible layer first (flash). Idempotent.
    private func teardownOutput() {
        guard !outputTornDown else { return }
        outputTornDown = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in playerLayers {
            layer.removeAllAnimations()
            layer.removeFromSuperlayer()
        }
        looper?.disableLooping()
        player.pause()
        player.removeAllItems() // AVQueuePlayer's replaceCurrentItem(nil)
        CATransaction.commit()
        for target in targets { OutputWindowManager.shared.releaseLayer(for: target) }
    }

    // MARK: - Fades

    private var volumeFadeKey: String {
        "videocue-\(UInt(bitPattern: ObjectIdentifier(self).hashValue)).volume"
    }

    private func rampVolume(fromDB: Double, toDB: Double, duration: TimeInterval, curve: FadeCurve, thenStop: Bool) {
        // Confinement invariant: `player` crosses onto FadeClock's queue only
        // for the documented-thread-safe AVPlayer.volume setter (AVQueuePlayer
        // is Sendable in this SDK, so no unsafe annotation is needed).
        let player = self.player
        let box = volumeBox
        FadeClock.shared.fade(
            key: volumeFadeKey,
            fromDB: fromDB,
            toDB: toDB,
            duration: duration,
            curve: curve,
            apply: { db in
                box.value = db
                player.volume = Float(FadeCurve.amplitude(fromDB: db))
            },
            completion: { [weak self] finished in
                // Settled at exactly amplitude 0 BEFORE any stop (no-click).
                guard finished, thenStop, toDB <= silenceFloorDB else { return }
                self?.stop()
            }
        )
    }

    private func animateOpacity(to target: Float, duration: TimeInterval) {
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            // Core Animation completion → hop to the MainActor explicitly.
            Task { @MainActor in
                self?.opacityAnimationSettled()
            }
        }
        if duration > 0 {
            for layer in playerLayers {
                let fromValue = (layer.presentation() ?? layer).opacity
                let animation = CABasicAnimation(keyPath: "opacity")
                animation.fromValue = fromValue
                animation.toValue = target
                animation.duration = duration
                animation.timingFunction = CAMediaTimingFunction(name: .linear)
                layer.opacity = target // model value: the layer lands here even if the animation is dropped
                layer.add(animation, forKey: Self.opacityAnimationKey)
            }
        } else {
            CATransaction.setDisableActions(true)
            for layer in playerLayers {
                layer.removeAnimation(forKey: Self.opacityAnimationKey)
                layer.opacity = target
            }
        }
        CATransaction.commit()
    }

    /// Bookkeeping hook for settled opacity ramps (kept for symmetry with
    /// FadeClock completions; fade cue sequencing lands in M4).
    private func opacityAnimationSettled() {}

    // MARK: - Authored fade-out

    /// Timer anchored to the remaining time in the FINAL pass: fades BOTH
    /// opacity and embedded audio over `fadeOutDuration` so they land at the
    /// out-point. Re-armed on resume and on leaving a loop; cancelled on
    /// pause/stop.
    private func scheduleAuthoredFadeOutIfNeeded() {
        fadeOutTask?.cancel()
        fadeOutTask = nil
        guard fadeOutDuration > 0, started, !stopped, !finishedNaturally, !pausedFlag, !loopingActive else { return }
        let remaining = passEnd - player.currentTime().seconds
        guard remaining > 0.01 else { return }
        let delay = max(0, remaining - fadeOutDuration)
        let rampDuration = min(fadeOutDuration, remaining)
        fadeOutTask = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled, let self,
                  !self.stopped, !self.pausedFlag, !self.finishedNaturally else { return }
            self.animateOpacity(to: 0, duration: rampDuration)
            self.rampVolume(fromDB: self.volumeBox.value, toDB: silenceFloorDB,
                            duration: rampDuration, curve: .dbLinear, thenStop: false)
        }
    }
}
