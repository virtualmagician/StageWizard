import AVFoundation
import Foundation

/// Plays one audio cue on a pooled AVAudioPlayerNode with sample-accurate trim,
/// gapless loops, edge fades, and FadeClock-driven live fades.
///
/// Lifecycle: `arm(body:fileURL:)` does everything slow (file open, engine
/// resolution, node checkout, first segments scheduled) so `start()` is just
/// `node.play()`. One instance = one playback; never reused after stop.
///
/// Loop design: each non-final pass is scheduled with a `.dataRendered`
/// completion that schedules the next pass, keeping ≥1 pass queued ahead of
/// the render head (gapless). The final pass of a finite playCount carries a
/// `.dataPlayedBack` completion → onFinished(.natural). `exitLoop()` stops the
/// re-scheduling and appends a tiny silent marker buffer whose .dataPlayedBack
/// fires when everything queued before it has played out — because there is no
/// API to unschedule a single segment, exit lets the already-queued pass play
/// (≤ one pass of extra latency).
@MainActor
public final class AudioCuePlayer: MediaPlayback, AudioEngineClient {

    // MARK: - Configuration (fixed at arm)

    /// Only touched on the main actor (scheduling reads).
    private let file: AVAudioFile
    /// Confinement invariant: everything on this node happens on the main
    /// actor EXCEPT `volume` writes from the FadeClock queue —
    /// AVAudioPlayerNode.volume is a documented-thread-safe mixing parameter
    /// (the only sanctioned off-main mutation in the app).
    nonisolated(unsafe) let node: AVAudioPlayerNode
    private let deviceEngine: DeviceEngine
    private let startFrame: AVAudioFramePosition
    private let frameCount: AVAudioFrameCount
    private let fileSampleRate: Double
    /// nil = infinite loop.
    private let totalPasses: Int?
    private let cueVolumeDB: Double
    private let fadeInDuration: TimeInterval
    private let fadeOutDuration: TimeInterval

    /// Set when the cue's saved output device wasn't connected at arm time and
    /// playback fell back to the system default output.
    public private(set) var routingWarning: AudioRoutingWarning?

    // MARK: - State

    private var started = false
    private var finished = false
    private var exitRequested = false
    private var scheduledPasses = 0
    /// Frozen elapsed-playback seconds while paused / after finish
    /// (node.lastRenderTime is nil or stale in both states).
    private var frozenElapsedPlayed: TimeInterval = 0
    private var fadeOutTask: Task<Void, Never>?

    public private(set) var isPaused = false
    public var onFinished: (@MainActor (PlaybackEndReason) -> Void)?

    /// FadeClock key — one fadeable parameter per player, last-writer-wins.
    private lazy var fadeKey = "audiocue-\(UInt(bitPattern: ObjectIdentifier(self).hashValue)).volume"

    // MARK: - Arm

    /// Load, trim, route, check out a node, and schedule the first pass(es).
    /// After this returns, `start()` is GO-instant.
    public static func arm(body: AudioBody, fileURL: URL) async throws -> AudioCuePlayer {
        // AVAudioFile open only reads the header — cheap enough for arm time
        // on the main actor (AVAudioFile is not Sendable, so it stays here).
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: fileURL)
        } catch {
            throw AudioEngineError.unreadableAudioFile("\(fileURL.lastPathComponent): \(error.localizedDescription)")
        }
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0, file.length > 0 else {
            throw AudioEngineError.unreadableAudioFile("\(fileURL.lastPathComponent) contains no audio")
        }

        // Sample-accurate trim: seconds → frames in the file's processing rate.
        let inFrame = min(max(0, AVAudioFramePosition((body.startTime * sampleRate).rounded())), file.length)
        let outFrame: AVAudioFramePosition
        if let endTime = body.endTime {
            outFrame = min(max(inFrame, AVAudioFramePosition((endTime * sampleRate).rounded())), file.length)
        } else {
            outFrame = file.length
        }
        guard outFrame > inFrame else { throw AudioEngineError.emptyTrimRange }

        let (deviceEngine, warning) = try AudioEngineManager.shared.resolveEngine(
            forDeviceUID: body.outputDeviceUID,
            deviceName: body.outputDeviceName
        )
        let node = try deviceEngine.checkoutNode()

        let player = AudioCuePlayer(
            file: file,
            node: node,
            deviceEngine: deviceEngine,
            startFrame: inFrame,
            frameCount: AVAudioFrameCount(outFrame - inFrame),
            body: body,
            routingWarning: warning
        )
        deviceEngine.register(player)
        player.scheduleInitialPasses()
        return player
    }

    private init(
        file: AVAudioFile,
        node: AVAudioPlayerNode,
        deviceEngine: DeviceEngine,
        startFrame: AVAudioFramePosition,
        frameCount: AVAudioFrameCount,
        body: AudioBody,
        routingWarning: AudioRoutingWarning?
    ) {
        self.file = file
        self.node = node
        self.deviceEngine = deviceEngine
        self.startFrame = startFrame
        self.frameCount = frameCount
        self.fileSampleRate = file.processingFormat.sampleRate
        self.totalPasses = body.infiniteLoop ? nil : max(1, body.playCount)
        self.cueVolumeDB = body.volumeDB
        self.fadeInDuration = max(0, body.fadeInDuration)
        self.fadeOutDuration = max(0, body.fadeOutDuration)
        self.routingWarning = routingWarning
        self.frozenElapsedPlayed = 0
        // Authored fade-in arms at silence; otherwise arm at cue volume.
        node.volume = self.fadeInDuration > 0 ? 0 : Float(FadeCurve.amplitude(fromDB: body.volumeDB))
    }

    // MARK: - MediaPlayback: introspection

    /// Duration of a single pass between the trim points.
    public var duration: TimeInterval? {
        passDuration
    }

    /// Media time within the file: trim offset + position inside the current
    /// loop pass (elapsed playback folded by the pass length).
    public var currentTime: TimeInterval {
        mediaTime(forElapsed: elapsedPlayedSeconds)
    }

    /// Live level in dB, derived from the node's (thread-safe) volume so it
    /// tracks in-flight FadeClock ramps. Exactly silenceFloorDB at amplitude 0.
    public var currentVolumeDB: Double {
        FadeCurve.dB(fromAmplitude: Double(node.volume))
    }

    private var passDuration: TimeInterval {
        Double(frameCount) / fileSampleRate
    }

    private var trimStartSeconds: TimeInterval {
        Double(startFrame) / fileSampleRate
    }

    /// Total seconds this playback will run, if knowable: finite playCount →
    /// passes × passDuration; infinite loop → nil until exitLoop freezes it.
    private var plannedPlaybackSeconds: TimeInterval? {
        if let totalPasses { return Double(totalPasses) * passDuration }
        return exitRequested ? Double(scheduledPasses) * passDuration : nil
    }

    /// Seconds of audio actually rendered since start() (excludes pauses).
    /// playerTime counts only while playing and survives pause/resume; it goes
    /// nil/stale while paused or stopped, so those states use the frozen value.
    private var elapsedPlayedSeconds: TimeInterval {
        guard started else { return 0 }
        if isPaused || finished { return frozenElapsedPlayed }
        guard let nodeTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: nodeTime),
              playerTime.isSampleTimeValid, playerTime.sampleRate > 0 else {
            return frozenElapsedPlayed
        }
        return max(0, Double(playerTime.sampleTime) / playerTime.sampleRate)
    }

    private func mediaTime(forElapsed elapsed: TimeInterval) -> TimeInterval {
        guard passDuration > 0 else { return trimStartSeconds }
        if let planned = plannedPlaybackSeconds, elapsed >= planned {
            return trimStartSeconds + passDuration // clamp at the out point
        }
        return trimStartSeconds + elapsed.truncatingRemainder(dividingBy: passDuration)
    }

    // MARK: - MediaPlayback: transport

    /// GO. Everything slow happened at arm; this is just node.play().
    public func start() {
        guard !finished, !started else { return }
        started = true
        node.play()
        if fadeInDuration > 0 {
            // Amplitude-shaped curve: dB-linear from the -120 dB floor stays
            // inaudible until the very end, which reads as a late fade-in.
            runFade(toDB: cueVolumeDB, duration: fadeInDuration, curve: .sCurve, thenStop: false)
        }
        armFadeOutTimerIfNeeded()
    }

    public func pause() {
        guard !finished, started, !isPaused else { return }
        // Capture position BEFORE node.pause(): lastRenderTime goes stale.
        frozenElapsedPlayed = elapsedPlayedSeconds
        isPaused = true
        node.pause()
        fadeOutTask?.cancel()
        fadeOutTask = nil
    }

    public func resume() {
        guard !finished, started, isPaused else { return }
        isPaused = false
        node.play()
        armFadeOutTimerIfNeeded()
    }

    /// Hard stop. Idempotent; cancels this player's fades, silences, returns
    /// the node to the pool, and fires onFinished(.stopped) exactly once
    /// (unless a natural finish already fired).
    public func stop() {
        finish(.stopped)
    }

    /// DeviceEngine configuration change wiped all scheduled audio.
    public func audioEngineDidInvalidate() {
        finish(.error("Audio output device configuration changed"))
    }

    // MARK: - MediaPlayback: levels

    public func setVolume(dB: Double) {
        guard !finished else { return }
        FadeClock.shared.cancel(key: fadeKey) // last-writer-wins
        node.volume = Float(FadeCurve.amplitude(fromDB: dB))
    }

    public func fadeVolume(toDB: Double, duration: TimeInterval, curve: FadeCurve, thenStop: Bool) {
        guard !finished else { return }
        runFade(toDB: toDB, duration: duration, curve: curve, thenStop: thenStop)
    }

    private func runFade(toDB: Double, duration: TimeInterval, curve: FadeCurve, thenStop: Bool) {
        FadeClock.shared.fade(
            key: fadeKey,
            fromDB: currentVolumeDB,
            toDB: toDB,
            duration: duration,
            curve: curve,
            apply: { db in
                // Runs on the FadeClock queue. node.volume is the documented-
                // thread-safe mixing parameter — the sanctioned off-main write.
                // FadeClock's final tick applies exactly toDB, so a fade to the
                // silence floor lands on exactly amplitude 0.0 BEFORE the
                // completion below can stop the node (no-click invariant).
                self.node.volume = Float(FadeCurve.amplitude(fromDB: db))
            },
            completion: { [weak self] didFinish in
                guard didFinish, thenStop else { return }
                self?.stop()
            }
        )
    }

    // MARK: - Loop scheduling

    private func scheduleInitialPasses() {
        scheduleNextPassIfNeeded()
        // Keep one pass queued ahead of the playing one (gapless loops).
        scheduleNextPassIfNeeded()
    }

    private func scheduleNextPassIfNeeded() {
        guard !finished, !exitRequested else { return }
        if let totalPasses, scheduledPasses >= totalPasses { return }
        scheduledPasses += 1
        let isFinalPass = totalPasses == scheduledPasses

        if isFinalPass {
            // .dataPlayedBack = the final pass has fully played out of the
            // hardware → natural end.
            node.scheduleSegment(
                file, startingFrame: startFrame, frameCount: frameCount, at: nil,
                completionCallbackType: .dataPlayedBack
            ) { @Sendable [weak self] _ in
                // Arbitrary AVFoundation queue → hop. Also fires early when
                // node.stop() flushes the queue; finish() is guarded for that.
                Task { @MainActor in
                    self?.finish(.natural)
                }
            }
        } else {
            // .dataRendered fires when this pass's last buffer has been read —
            // the trigger to top the queue back up to one-pass-ahead.
            node.scheduleSegment(
                file, startingFrame: startFrame, frameCount: frameCount, at: nil,
                completionCallbackType: .dataRendered
            ) { @Sendable [weak self] _ in
                Task { @MainActor in
                    self?.passDidRender()
                }
            }
        }
    }

    private func passDidRender() {
        guard !finished, !exitRequested else { return }
        scheduleNextPassIfNeeded()
    }

    /// Leave the loop after the queued audio plays out (current pass plus the
    /// one pass kept queued ahead — there is no API to unschedule a segment).
    public func exitLoop() {
        guard !finished, !exitRequested else { return }
        if let totalPasses, scheduledPasses >= totalPasses {
            return // final pass already scheduled; natural end already armed
        }
        exitRequested = true
        scheduleEndMarker()
        armFadeOutTimerIfNeeded() // planned end is now known → edge fade-out
    }

    /// Appends ~3 ms of silence whose .dataPlayedBack completion means "every
    /// queued pass before me has played out" → natural finish for loop exits.
    private func scheduleEndMarker() {
        let format = node.outputFormat(forBus: 0)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128) else {
            finish(.error("Could not allocate the loop-exit marker buffer"))
            return
        }
        buffer.frameLength = 128
        if let channels = buffer.floatChannelData {
            for channel in 0..<Int(format.channelCount) {
                channels[channel].update(repeating: 0, count: Int(buffer.frameLength))
            }
        }
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { @Sendable [weak self] _ in
            Task { @MainActor in
                self?.finish(.natural)
            }
        }
    }

    // MARK: - Authored edge fade-out

    /// When remaining time in the final pass reaches fadeOutDuration, ramp to
    /// silence so playback ends already at amplitude 0. Armed on start and
    /// resume (and on exitLoop, when the end becomes known); cancelled on
    /// pause/stop. Remaining time is computed from live playback position.
    private func armFadeOutTimerIfNeeded() {
        fadeOutTask?.cancel()
        fadeOutTask = nil
        guard fadeOutDuration > 0, started, !finished, !isPaused,
              let planned = plannedPlaybackSeconds else { return }
        let delay = planned - fadeOutDuration - elapsedPlayedSeconds
        fadeOutTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled, let self, self.started, !self.finished, !self.isPaused else { return }
            let remaining = max(0, (self.plannedPlaybackSeconds ?? 0) - self.elapsedPlayedSeconds)
            self.runFade(
                toDB: silenceFloorDB,
                duration: min(self.fadeOutDuration, remaining),
                curve: .dbLinear,
                thenStop: false // natural end fires from the scheduler at volume 0
            )
        }
    }

    // MARK: - The one finish funnel

    private func finish(_ reason: PlaybackEndReason) {
        guard !finished else { return }
        frozenElapsedPlayed = elapsedPlayedSeconds // freeze currentTime first
        finished = true
        fadeOutTask?.cancel()
        fadeOutTask = nil
        FadeClock.shared.cancel(key: fadeKey)
        node.stop() // flushes remaining segments; their completions see `finished`
        deviceEngine.checkin(node: node, client: self)
        onFinished?(reason)
    }
}
