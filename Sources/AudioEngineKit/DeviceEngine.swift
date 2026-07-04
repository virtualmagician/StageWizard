import AVFoundation
import CoreAudio
import Foundation

/// Errors from the audio engine layer.
public enum AudioEngineError: Error, LocalizedError {
    case engineStartFailed(String)
    case playerPoolExhausted
    case emptyTrimRange
    case unreadableAudioFile(String)

    public var errorDescription: String? {
        switch self {
        case .engineStartFailed(let detail):
            return "The audio engine could not start: \(detail)"
        case .playerPoolExhausted:
            return "Too many simultaneous audio cues on one output device (max \(DeviceEngine.playerPoolSize))."
        case .emptyTrimRange:
            return "The cue's trim range contains no audio."
        case .unreadableAudioFile(let detail):
            return "The audio file could not be read: \(detail)"
        }
    }
}

/// A playback client whose scheduled audio lives on a DeviceEngine.
/// AudioCuePlayer conforms; the engine calls this when a configuration change
/// wipes every scheduled event so the player can funnel through its stop path.
@MainActor
public protocol AudioEngineClient: AnyObject {
    func audioEngineDidInvalidate()
}

/// One AVAudioEngine bound to one output device (nil UID = system default),
/// with a fixed pool of pre-attached AVAudioPlayerNodes. Nodes are NEVER
/// attached or detached mid-show — cue players check nodes out and back in.
///
/// Configuration changes (device unplugged, sample-rate change, default-device
/// switch): AVAudioEngine stops itself and clears every scheduled event. v1
/// policy — deliberately simple and safe — is to mark every active player as
/// stopped (through its normal stop funnel, reason .error), rebuild the engine
/// and pool from scratch, and tell the operator via `onEngineRebuilt`. No
/// position-recompute or auto-resume in v1.
@MainActor
public final class DeviceEngine {
    public nonisolated static let playerPoolSize = 32

    /// The device this engine is bound to; nil = system default output.
    public let deviceUID: String?
    /// Fired (on the main actor) after a configuration-change rebuild; the UI
    /// uses this for an operator banner ("audio device changed, cues stopped").
    public var onEngineRebuilt: (@MainActor () -> Void)?

    private(set) var engine = AVAudioEngine()
    /// Free nodes of the *current* engine generation.
    private var pool: [AVAudioPlayerNode] = []
    /// Every node of the current generation (identity check for checkin).
    private var allNodes: [AVAudioPlayerNode] = []

    private struct WeakClient {
        weak var client: AudioEngineClient?
    }
    private var clients: [ObjectIdentifier: WeakClient] = [:]
    private var configChangeObserver: NSObjectProtocol?
    /// Master level preserved across rebuilds (the panic bus ramps it).
    private var savedMasterVolume: Float = 1

    init(deviceUID: String?) throws {
        self.deviceUID = deviceUID
        try buildEngine()
    }

    // MARK: - Master volume (panic bus)

    /// Per-device master: mainMixerNode.outputVolume. The panic ramp drives
    /// this off-main through FadeClock — a documented-thread-safe setter.
    public var masterVolume: Float {
        engine.mainMixerNode.outputVolume
    }

    public func setMasterVolume(_ volume: Float) {
        savedMasterVolume = volume
        engine.mainMixerNode.outputVolume = volume
    }

    /// The mixer whose outputVolume the panic bus ramps via FadeClock.
    public var masterMixerNode: AVAudioMixerNode {
        engine.mainMixerNode
    }

    // MARK: - Node pool

    func checkoutNode() throws -> AVAudioPlayerNode {
        if allNodes.isEmpty {
            // A previous rebuild failed (e.g. no device at all) — retry now.
            try buildEngine()
        }
        try ensureRunning()
        guard let node = pool.popLast() else {
            throw AudioEngineError.playerPoolExhausted
        }
        return node
    }

    func register(_ client: AudioEngineClient) {
        clients[ObjectIdentifier(client)] = WeakClient(client: client)
    }

    func checkin(node: AVAudioPlayerNode, client: AudioEngineClient) {
        clients.removeValue(forKey: ObjectIdentifier(client))
        // Ignore nodes from a previous engine generation (post-rebuild checkin)
        // and double-checkins.
        guard allNodes.contains(where: { $0 === node }),
              !pool.contains(where: { $0 === node }) else { return }
        node.stop() // clears any residual scheduled events; safe when stopped
        pool.append(node)
    }

    func ensureRunning() throws {
        guard !engine.isRunning else { return }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw AudioEngineError.engineStartFailed(error.localizedDescription)
        }
    }

    // MARK: - Build / rebuild

    private func buildEngine() throws {
        let engine = AVAudioEngine()

        // Bind the output BEFORE start (and before any format queries) via the
        // output AU. An unresolvable UID falls back to the default device —
        // the arm-time warning path tells the operator (AudioEngineManager).
        if let deviceUID, let deviceID = AudioDeviceManager.shared.deviceID(forUID: deviceUID) {
            do {
                try engine.outputNode.auAudioUnit.setDeviceID(deviceID)
            } catch {
                // Device exists but refused binding — keep the default device
                // rather than failing the whole engine mid-show.
            }
        }

        let hardwareFormat = engine.outputNode.outputFormat(forBus: 0)
        let sampleRate = hardwareFormat.sampleRate > 0 ? hardwareFormat.sampleRate : 44_100
        guard let connectionFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw AudioEngineError.engineStartFailed("could not create the connection format")
        }

        // Accessing mainMixerNode auto-wires mixer → output at the HW format.
        let mixer = engine.mainMixerNode
        var nodes: [AVAudioPlayerNode] = []
        nodes.reserveCapacity(Self.playerPoolSize)
        for _ in 0..<Self.playerPoolSize {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: mixer, fromBus: 0, toBus: mixer.nextAvailableInputBus, format: connectionFormat)
            nodes.append(node)
        }
        mixer.outputVolume = savedMasterVolume

        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw AudioEngineError.engineStartFailed(error.localizedDescription)
        }

        self.engine = engine
        self.allNodes = nodes
        self.pool = nodes
        observeConfigurationChanges(of: engine)
    }

    private func observeConfigurationChanges(of engine: AVAudioEngine) {
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
        }
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            // Arrives on an arbitrary AVFoundation queue → hop to the main
            // actor. The Notification itself is not Sendable; don't carry it.
            Task { @MainActor in
                self?.handleConfigurationChange()
            }
        }
    }

    /// The engine stopped itself and every scheduled event is gone. Stop all
    /// active players through their normal funnel, rebuild, notify operator.
    private func handleConfigurationChange() {
        let activeClients = clients.values.compactMap(\.client)
        clients.removeAll()
        // Invalidate the old generation first so late checkins become no-ops.
        allNodes = []
        pool = []

        for client in activeClients {
            client.audioEngineDidInvalidate()
        }

        savedMasterVolume = engine.mainMixerNode.outputVolume
        engine.stop()
        do {
            try buildEngine()
        } catch {
            // No usable device right now. The next checkoutNode() retries.
        }
        onEngineRebuilt?()
    }
}
