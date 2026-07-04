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
    var duration: TimeInterval? { get }
    /// Current position within the media file (media time, not wall clock).
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
}

extension MediaPlayback {
    public func fadeOpacity(to opacity: Double, duration: TimeInterval) {}
}
