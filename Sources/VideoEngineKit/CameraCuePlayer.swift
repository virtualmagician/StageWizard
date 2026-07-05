import AVFoundation
import AppKit

public enum CameraEngineError: LocalizedError {
    case accessDenied
    case noCamera(String)
    case cannotUseCamera(String)

    public var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Camera access is denied — enable it in System Settings → Privacy & Security → Camera."
        case .noCamera(let name):
            return "Camera “\(name)” is not connected and no other camera was found."
        case .cannotUseCamera(let name):
            return "Camera “\(name)” can't be used (in use by another app?)."
        }
    }
}

/// Enumerates connected cameras for the inspector picker.
@MainActor
@Observable
public final class CameraDeviceManager {
    public static let shared = CameraDeviceManager()

    public struct Camera: Identifiable, Sendable {
        public let uid: String
        public let name: String
        public var id: String { uid }
    }

    public private(set) var cameras: [Camera] = []

    private init() {
        refresh()
    }

    public func refresh() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )
        cameras = discovery.devices.map { Camera(uid: $0.uniqueID, name: $0.localizedName) }
    }

    /// Resolve a persisted UID; nil UID = first available camera.
    public func device(forUID uid: String?) -> AVCaptureDevice? {
        if let uid, let device = AVCaptureDevice(uniqueID: uid) { return device }
        guard uid == nil else { return nil }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices.first
    }
}

/// Live camera on a stage display. Video-only, indefinite duration: the cue
/// runs until explicitly stopped (like a holdLastFrame video). The capture
/// session starts at ARM (session spin-up is slow); GO just fades the layer in.
@MainActor
public final class CameraCuePlayer: MediaPlayback {
    /// Where this camera renders (real displays and/or rehearsal previews).
    public let targets: [OutputTarget]
    /// Real displays only — the app's unplug sweep checks these.
    public var displayIDs: [CGDirectDisplayID] { targets.compactMap(\.displayID) }

    /// startRunning/stopRunning are documented thread-safe but AVCaptureSession
    /// is not Sendable — this box carries it into the detached tasks that make
    /// those blocking calls (hundreds of ms) off the main actor.
    private struct SessionBox: @unchecked Sendable {
        let session: AVCaptureSession
    }

    private let sessionBox: SessionBox
    private var session: AVCaptureSession { sessionBox.session }
    /// One preview layer per target display (groups can mirror).
    private let previewLayers: [AVCaptureVideoPreviewLayer]
    private var fillModeSetting: FillMode
    private var geometrySetting: VideoGeometry
    private let fadeInDuration: TimeInterval
    private var startedAt: ContinuousClock.Instant?
    private var pausedFlag = false
    private var stopped = false
    private var finishedFired = false
    private var thenStopTask: Task<Void, Never>?

    public var onFinished: (@MainActor (PlaybackEndReason) -> Void)?

    /// Single-display convenience (tests, legacy call sites).
    public static func arm(
        body: CameraBody,
        displayID: CGDirectDisplayID,
        windowFrameOverride: CGRect? = nil
    ) async throws -> CameraCuePlayer {
        try await arm(body: body, targets: [.display(displayID)], windowFrameOverride: windowFrameOverride)
    }

    /// Multi-display convenience.
    public static func arm(
        body: CameraBody,
        displayIDs: [CGDirectDisplayID],
        windowFrameOverride: CGRect? = nil
    ) async throws -> CameraCuePlayer {
        try await arm(body: body, targets: displayIDs.map { .display($0) }, windowFrameOverride: windowFrameOverride)
    }

    public static func arm(
        body: CameraBody,
        targets: [OutputTarget],
        windowFrameOverride: CGRect? = nil
    ) async throws -> CameraCuePlayer {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                throw CameraEngineError.accessDenied
            }
        default:
            throw CameraEngineError.accessDenied
        }
        guard let device = CameraDeviceManager.shared.device(forUID: body.cameraUID) else {
            throw CameraEngineError.noCamera(body.cameraName ?? body.cameraUID ?? "default")
        }
        let session = AVCaptureSession()
        session.sessionPreset = .high
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                throw CameraEngineError.cannotUseCamera(device.localizedName)
            }
            session.addInput(input)
        } catch let error as CameraEngineError {
            throw error
        } catch {
            throw CameraEngineError.cannotUseCamera(device.localizedName)
        }

        let player = try CameraCuePlayer(
            body: body, session: session,
            targets: targets, windowFrameOverride: windowFrameOverride
        )
        // Spin the session up at arm so GO is instant. Blocking call →
        // detached; the session is internally thread-safe for start/stop.
        let box = SessionBox(session: session)
        await Task.detached(priority: .userInitiated) {
            box.session.startRunning()
        }.value
        return player
    }

    private init(
        body: CameraBody,
        session: AVCaptureSession,
        targets: [OutputTarget],
        windowFrameOverride: CGRect?
    ) throws {
        self.sessionBox = SessionBox(session: session)
        self.targets = targets
        self.fillModeSetting = body.fillMode
        self.geometrySetting = body.geometry
        self.fadeInDuration = body.fadeInDuration

        let gravity = body.geometry.gravity(fillMode: body.fillMode)
        var layers: [AVCaptureVideoPreviewLayer] = []
        var leased: [OutputTarget] = []
        do {
            for target in targets {
                let host = try OutputWindowManager.shared.hostLayer(for: target, frameOverride: windowFrameOverride)
                leased.append(target)
                let layer = AVCaptureVideoPreviewLayer(session: session)
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
            for layer in layers { layer.removeFromSuperlayer() }
            for target in leased { OutputWindowManager.shared.releaseLayer(for: target) }
            throw error
        }
        self.previewLayers = layers
        if body.geometry.mode == .custom {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for layer in layers {
                body.geometry.apply(to: layer, fillMode: body.fillMode)
            }
            CATransaction.commit()
        }
    }

    /// Live geometry update — see VideoCuePlayer.applyGeometry.
    public func applyGeometry(_ geometry: VideoGeometry, fillMode: FillMode) {
        guard !stopped else { return }
        geometrySetting = geometry
        fillModeSetting = fillMode
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in previewLayers {
            geometry.apply(to: layer, fillMode: fillMode)
        }
        CATransaction.commit()
    }

    /// Live render-order change from the inspector (1 = back … 10 = front).
    public func applyRenderLayer(_ value: Int) {
        guard !stopped else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in previewLayers {
            layer.zPosition = CGFloat(value)
        }
        CATransaction.commit()
    }

    // MARK: - MediaPlayback

    public var duration: TimeInterval? { nil }   // indefinite

    public var currentTime: TimeInterval {
        guard let startedAt else { return 0 }
        return startedAt.duration(to: .now).seconds
    }

    public var isPaused: Bool { pausedFlag }
    public var currentVolumeDB: Double { 0 }     // video-only

    public func start() {
        guard !stopped else { return }
        startedAt = .now
        animateOpacity(to: 1, duration: fadeInDuration)
    }

    /// Pause freezes the picture (session stops delivering frames).
    public func pause() {
        guard !stopped, !pausedFlag else { return }
        pausedFlag = true
        let box = sessionBox
        Task.detached(priority: .userInitiated) {
            box.session.stopRunning()
        }
    }

    public func resume() {
        guard !stopped, pausedFlag else { return }
        pausedFlag = false
        let box = sessionBox
        Task.detached(priority: .userInitiated) {
            box.session.startRunning()
        }
    }

    public func stop() {
        guard !stopped else { return }
        stopped = true
        thenStopTask?.cancel()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in previewLayers { layer.removeFromSuperlayer() }
        CATransaction.commit()
        let box = sessionBox
        Task.detached(priority: .userInitiated) {
            box.session.stopRunning()
        }
        for target in targets { OutputWindowManager.shared.releaseLayer(for: target) }
        if !finishedFired {
            finishedFired = true
            onFinished?(.stopped)
        }
    }

    public func setVolume(dB: Double) {}         // no audio path

    /// No audio to ramp, but `thenStop` must still stop after the ramp time —
    /// this is how fade-outs/panic reach camera cues.
    public func fadeVolume(toDB: Double, duration: TimeInterval, curve: FadeCurve, thenStop: Bool) {
        guard thenStop, !stopped else { return }
        thenStopTask?.cancel()
        thenStopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    public func fadeOpacity(to opacity: Double, duration: TimeInterval) {
        guard !stopped else { return }
        animateOpacity(to: Float(min(max(opacity, 0), 1)), duration: max(0, duration))
    }

    public func exitLoop() {}

    /// Second preview layer on the same session for the operator UI.
    public func makePreviewLayer() -> AVCaptureVideoPreviewLayer {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspect
        return layer
    }

    private func animateOpacity(to value: Float, duration: TimeInterval) {
        for layer in previewLayers {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = layer.presentation()?.opacity ?? layer.opacity
            animation.toValue = value
            animation.duration = max(duration, 0.01)
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.opacity = value
            layer.add(animation, forKey: "opacity")
        }
    }
}
