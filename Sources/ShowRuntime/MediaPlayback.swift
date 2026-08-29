import Foundation

/// Why a playback finished — all stop paths funnel through one reporting point.
public enum PlaybackEndReason: Sendable {
    /// Reached the out-point (or final loop pass) on its own.
    case natural
    /// Explicitly stopped (user, stop cue, panic).
    case stopped
    case error(String)
}

/// Uniform interface the cue engine drives; implemented by AudioCuePlayer
/// (AVAudioEngine) and VideoCuePlayer (AVQueuePlayer). Instances are created
/// ARMED (media loaded, seeked to the in-point, prerolled) so `start()` is
/// GO-instant. One instance = one playback; never reused after stop.
@MainActor
public protocol MediaPlayback: AnyObject {
    /// Effective duration of a single pass between trim points, if known.
    /// WALL-CLOCK seconds — for AudioCuePlayer/VideoCuePlayer (adjustable
    /// playback rate via AudioBody/VideoBody.rate) this is the media-time
    /// pass length ÷ rate, not the raw media duration.
    var duration: TimeInterval? { get }
    /// Position within the trimmed pass, anchored at the cue body's
    /// `startTime` exactly like `duration` is anchored at 0 — i.e.
    /// `currentTime - startTime` is a WALL-CLOCK elapsed value comparable to
    /// `duration` (see CueInstance.elapsed/duration, which do exactly that
    /// subtraction). Players with a fixed 1x rate already satisfy this
    /// trivially; AudioCuePlayer/VideoCuePlayer divide by rate to keep it true.
    var currentTime: TimeInterval { get }
    var isPaused: Bool { get }
    /// Current live level, dB. Fades read this as their starting point.
    var currentVolumeDB: Double { get }

    /// Fires exactly once when playback ends for any reason. For video cues
    /// with holdLastFrame this fires at the out-point even though the last
    /// frame stays visible; the instance then waits for `stop()`.
    var onFinished: (@MainActor (PlaybackEndReason) -> Void)? { get set }

    /// GO. Must be instant (no I/O, no seeks) — everything slow happened at arm.
    func start()
    func pause()
    func resume()
    /// Hard stop: cancel fades, silence, release resources. Idempotent.
    func stop()
    /// Set the live level immediately (fade cues ramp via repeated calls
    /// through FadeClock, ending exactly at the target).
    func setVolume(dB: Double)
    /// Ramp to a level through the shared FadeClock. If the target is the
    /// silence floor and `thenStop`, the instance stops after settling at 0.
    func fadeVolume(toDB: Double, duration: TimeInterval, curve: FadeCurve, thenStop: Bool)
    /// Video: ramp layer opacity (0…1). Audio: no-op.
    func fadeOpacity(to opacity: Double, duration: TimeInterval)
    /// Leave an infinite/counted loop after the current pass completes.
    func exitLoop()

    /// D17: attach an ADDITIONAL live-mirror output while this instance is
    /// already running (or paused) — a mirror checkbox just ticked, the
    /// stage display just opened, or a program pane just re-enabled. Builds
    /// a new content layer/container hosted at `target` matching the cue's
    /// CURRENT geometry/fill-mode/render-layer/opacity so a mid-fade attach
    /// looks right immediately, with no restart. Visual-only — never touches
    /// the fade/no-click contract. Idempotent: attaching an already-attached
    /// target (or one of the targets armed at fire time) is a no-op. Audio
    /// and other non-visual players never override the default no-op below.
    func attachTarget(_ target: OutputTarget)
    /// D17: detach a target `attachTarget` added — mirror checkbox
    /// unticked, stage display closed, program pane disabled. Targets armed
    /// at fire time are NOT reachable here; those release only via `stop()`.
    /// Idempotent.
    func detachTarget(_ target: OutputTarget)
}

extension MediaPlayback {
    public func fadeOpacity(to opacity: Double, duration: TimeInterval) {}
    public func attachTarget(_ target: OutputTarget) {}
    public func detachTarget(_ target: OutputTarget) {}
}
