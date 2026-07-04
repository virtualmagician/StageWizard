import Foundation

/// Non-fatal routing fallback surfaced at arm time: the cue's saved output
/// device is not connected, so the cue was armed on the system default output.
/// The integrator shows this to the operator (banner / inspector warning).
public struct AudioRoutingWarning: Sendable, Equatable, CustomStringConvertible {
    public let requestedUID: String
    public let requestedName: String?

    public var description: String {
        "Output device “\(requestedName ?? requestedUID)” is not connected — playing on the system default output."
    }
}

/// Owns one lazily-created DeviceEngine per in-use output device, keyed by
/// device UID (nil = system default). Engines live for the process lifetime.
@MainActor
public final class AudioEngineManager {
    public static let shared = AudioEngineManager()

    /// Dictionary key for the default-device engine ("" is never a real UID).
    private static let defaultKey = ""

    private var engines: [String: DeviceEngine] = [:]

    /// Fired after any engine rebuilt itself following a configuration change
    /// (device unplugged / sample rate changed / default output switched).
    /// Argument = the engine's device UID, nil for the default-device engine.
    /// All cues that were playing on that engine have already been stopped.
    public var onEngineRebuilt: (@MainActor (_ deviceUID: String?) -> Void)?

    private init() {}

    /// Every engine created so far — the panic bus ramps each one's master.
    public var activeEngines: [DeviceEngine] {
        Array(engines.values)
    }

    /// Engine for a cue's saved device UID. An unresolvable UID falls back to
    /// the default-device engine and returns a warning for the operator.
    public func resolveEngine(
        forDeviceUID uid: String?,
        deviceName: String? = nil
    ) throws -> (engine: DeviceEngine, warning: AudioRoutingWarning?) {
        if let uid {
            if AudioDeviceManager.shared.deviceID(forUID: uid) != nil {
                return (try engine(key: uid), nil)
            }
            let fallback = try engine(key: Self.defaultKey)
            return (fallback, AudioRoutingWarning(requestedUID: uid, requestedName: deviceName))
        }
        return (try engine(key: Self.defaultKey), nil)
    }

    private func engine(key: String) throws -> DeviceEngine {
        if let existing = engines[key] {
            try existing.ensureRunning()
            return existing
        }
        let uid: String? = key.isEmpty ? nil : key
        let created = try DeviceEngine(deviceUID: uid)
        created.onEngineRebuilt = { [weak self] in
            self?.onEngineRebuilt?(uid)
        }
        engines[key] = created
        return created
    }
}
