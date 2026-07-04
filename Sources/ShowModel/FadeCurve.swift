import Foundation

/// Fade curve shapes. `gain(at:)` maps normalized progress t ∈ [0,1] to a
/// normalized gain multiplier applied between the fade's start and target.
public enum FadeCurve: String, Codable, Hashable, Sendable, CaseIterable {
    /// Linear in decibels — perceptually even; the right default for fades to silence.
    case dbLinear
    /// Equal-power (sin/cos) — for crossfades and fades that stay audible.
    case equalPower
    /// Linear in amplitude.
    case linear
    /// Smoothstep ease-in-out.
    case sCurve

    public var displayName: String {
        switch self {
        case .dbLinear: return "dB Linear"
        case .equalPower: return "Equal Power"
        case .linear: return "Linear"
        case .sCurve: return "S-Curve"
        }
    }

    /// Normalized progress curve: f(0) = 0, f(1) = 1.
    public func progress(at t: Double) -> Double {
        let t = min(max(t, 0), 1)
        switch self {
        case .linear, .dbLinear:
            // dbLinear's shaping happens in dB space (see interpolateDB).
            return t
        case .equalPower:
            return sin(t * .pi / 2)
        case .sCurve:
            return t * t * (3 - 2 * t)
        }
    }

    /// Interpolate a level in dB from `fromDB` to `toDB` at progress t.
    /// For dbLinear the path is a straight line in dB space; other curves
    /// shape amplitude and are converted back to dB.
    public func interpolateDB(from fromDB: Double, to toDB: Double, at t: Double) -> Double {
        let t = min(max(t, 0), 1)
        switch self {
        case .dbLinear:
            // Straight line in dB, with the silence floor as a hard endpoint.
            let from = max(fromDB, silenceFloorDB)
            let to = max(toDB, silenceFloorDB)
            return from + (to - from) * t
        case .linear, .equalPower, .sCurve:
            let fromAmp = FadeCurve.amplitude(fromDB: fromDB)
            let toAmp = FadeCurve.amplitude(fromDB: toDB)
            let amp = fromAmp + (toAmp - fromAmp) * progress(at: t)
            return FadeCurve.dB(fromAmplitude: amp)
        }
    }

    /// dB → linear amplitude. The silence floor maps to exactly 0.0 so a
    /// completed fade-out can never leave a residual signal (click source).
    public static func amplitude(fromDB dB: Double) -> Double {
        if dB <= silenceFloorDB { return 0 }
        return pow(10, dB / 20)
    }

    public static func dB(fromAmplitude amp: Double) -> Double {
        if amp <= 0 { return silenceFloorDB }
        return max(20 * log10(amp), silenceFloorDB)
    }
}
