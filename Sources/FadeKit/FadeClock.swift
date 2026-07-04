import Foundation

/// Handle to a running fade; used to cancel/preempt.
public final class FadeHandle: Hashable, Sendable {
    let id = UUID()

    public static func == (lhs: FadeHandle, rhs: FadeHandle) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// One shared 100 Hz fade engine for every level ramp in the app: per-cue audio
/// fades, fade cues, and the panic master ramp. A DispatchSourceTimer with
/// .strict leeway holds ±1 ms — at ≤1 dB per 10 ms step, ramps are click-free.
///
/// Concurrency: @unchecked Sendable with all mutable state confined to `queue`.
/// `apply` closures run ON the queue and must touch only documented-thread-safe
/// setters (AVAudioPlayerNode.volume, mainMixerNode.outputVolume, AVPlayer.volume).
/// Completions hop to MainActor.
public final class FadeClock: @unchecked Sendable {
    public static let shared = FadeClock()

    public static let tickInterval: TimeInterval = 0.010

    private struct ActiveFade {
        let handle: FadeHandle
        let key: String
        let fromDB: Double
        let toDB: Double
        let duration: TimeInterval
        let curve: FadeCurve
        let startedAt: DispatchTime
        let apply: @Sendable (Double) -> Void
        let completion: @MainActor @Sendable (_ finished: Bool) -> Void
    }

    private let queue = DispatchQueue(label: "com.marcotempest.stagewizard.fadeclock", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var fades: [ActiveFade] = []

    /// Start a fade. `key` identifies the faded parameter (e.g. "cue-<uuid>.volume");
    /// starting a new fade on the same key cancels the in-flight one first
    /// (last-writer-wins, LiSP lesson). `apply` receives the current level in dB
    /// every tick, ending on exactly `toDB` (fades to the silence floor therefore
    /// end at exactly 0.0 amplitude — the no-click invariant).
    /// `completion(finished)` is false when the fade was preempted or cancelled.
    @discardableResult
    public func fade(
        key: String,
        fromDB: Double,
        toDB: Double,
        duration: TimeInterval,
        curve: FadeCurve,
        apply: @escaping @Sendable (Double) -> Void,
        completion: @escaping @MainActor @Sendable (_ finished: Bool) -> Void = { _ in }
    ) -> FadeHandle {
        let handle = FadeHandle()
        queue.async {
            self.cancelLocked(key: key)
            guard duration > Self.tickInterval else {
                apply(toDB)
                Task { @MainActor in completion(true) }
                return
            }
            apply(fromDB)
            self.fades.append(ActiveFade(
                handle: handle, key: key, fromDB: fromDB, toDB: toDB,
                duration: duration, curve: curve, startedAt: .now(),
                apply: apply, completion: completion
            ))
            self.startTimerIfNeeded()
        }
        return handle
    }

    /// Cancel a fade, leaving the level wherever the last tick put it.
    /// The fade's completion fires with finished=false.
    public func cancel(_ handle: FadeHandle) {
        queue.async {
            self.cancelLocked { $0.handle == handle }
        }
    }

    /// Cancel any fade on `key` (e.g. before a hard stop).
    public func cancel(key: String) {
        queue.async {
            self.cancelLocked(key: key)
        }
    }

    /// Cancel every fade whose key has the given prefix — panic uses this to
    /// clear all per-cue fades before running the master ramp.
    public func cancelAll(keyPrefix: String = "") {
        queue.async {
            self.cancelLocked { $0.key.hasPrefix(keyPrefix) }
        }
    }

    // MARK: - Queue-confined

    private func cancelLocked(key: String) {
        cancelLocked { $0.key == key }
    }

    private func cancelLocked(where predicate: (ActiveFade) -> Bool) {
        let cancelled = fades.filter(predicate)
        fades.removeAll(where: predicate)
        for fade in cancelled {
            let completion = fade.completion
            Task { @MainActor in completion(false) }
        }
        stopTimerIfIdle()
    }

    private func startTimerIfNeeded() {
        guard timer == nil, !fades.isEmpty else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Self.tickInterval, repeating: Self.tickInterval, leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func stopTimerIfIdle() {
        guard fades.isEmpty, let t = timer else { return }
        t.cancel()
        timer = nil
    }

    private func tick() {
        let now = DispatchTime.now()
        var finished: [ActiveFade] = []
        fades.removeAll { fade in
            let elapsed = Double(now.uptimeNanoseconds - fade.startedAt.uptimeNanoseconds) / 1_000_000_000
            let t = elapsed / fade.duration
            if t >= 1 {
                fade.apply(fade.toDB)
                finished.append(fade)
                return true
            }
            fade.apply(fade.curve.interpolateDB(from: fade.fromDB, to: fade.toDB, at: t))
            return false
        }
        for fade in finished {
            let completion = fade.completion
            Task { @MainActor in completion(true) }
        }
        stopTimerIfIdle()
    }
}
