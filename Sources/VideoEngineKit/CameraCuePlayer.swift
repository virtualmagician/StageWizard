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
        cameras = discovery.devices
            .filter { $0.localizedName != "StageWizard Camera" }   // no feedback loops
            .map { Camera(uid: $0.uniqueID, name: $0.localizedName) }
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
///
/// LAYERS: each target hosts one CONTAINER layer (fades, z-order, and
/// geometry live there). Inside sit two siblings sized by autoresizing:
/// the passthrough `AVCaptureVideoPreviewLayer` (zero-cost, used when all
/// effects are off) and a plain content layer fed processed frames by
/// `CameraFrameProcessor` (person segmentation / hand tracking). Effects
/// toggle live by swapping which inner layer is hidden.
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

    private struct TargetLayers {
        let container: CALayer
        let preview: AVCaptureVideoPreviewLayer
        let content: CALayer
    }

    private let sessionBox: SessionBox
    private var session: AVCaptureSession { sessionBox.session }
    /// One container per target display (groups can mirror).
    private let targetLayers: [TargetLayers]
    private var containers: [CALayer] { targetLayers.map(\.container) }
    private let processor = CameraFrameProcessor()
    /// True when the processor must flip frames itself (mirroring couldn't
    /// be pushed down into the capture connection).
    private let processorMirrors: Bool
    private var effects: CameraEffects
    private var dustEmitterURL: URL?
    /// Per target: up to 2 emitters (one per tracked hand), above the content.
    private var handEmitters: [[CAEmitterLayer]] = []
    /// Smoothed hand positions (normalized), index-aligned with emitters.
    private var smoothedHands: [CGPoint?] = [nil, nil]
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
        dustEmitterURL: URL? = nil,
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
            body: body, session: session, dustEmitterURL: dustEmitterURL,
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
        dustEmitterURL: URL?,
        targets: [OutputTarget],
        windowFrameOverride: CGRect?
    ) throws {
        self.sessionBox = SessionBox(session: session)
        self.targets = targets
        self.effects = body.effects
        self.dustEmitterURL = dustEmitterURL
        self.fillModeSetting = body.fillMode
        self.geometrySetting = body.geometry
        self.fadeInDuration = body.fadeInDuration

        let gravity = body.geometry.gravity(fillMode: body.fillMode)
        var built: [TargetLayers] = []
        var leased: [OutputTarget] = []
        do {
            for target in targets {
                let host = try OutputWindowManager.shared.hostLayer(for: target, frameOverride: windowFrameOverride)
                leased.append(target)

                CATransaction.begin()
                CATransaction.setDisableActions(true)
                let container = CALayer()
                container.frame = host.bounds
                container.opacity = 0
                container.zPosition = CGFloat(body.layer)

                let preview = AVCaptureVideoPreviewLayer(session: session)
                preview.videoGravity = gravity
                preview.frame = container.bounds
                preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
                container.addSublayer(preview)

                let content = CALayer()
                content.contentsGravity = Self.contentsGravity(for: gravity)
                content.isOpaque = false
                content.frame = container.bounds
                content.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
                content.isHidden = true
                container.addSublayer(content)

                host.addSublayer(container)
                CATransaction.commit()
                built.append(TargetLayers(container: container, preview: preview, content: content))
            }
        } catch {
            for entry in built { entry.container.removeFromSuperlayer() }
            for target in leased { OutputWindowManager.shared.releaseLayer(for: target) }
            throw error
        }
        self.targetLayers = built

        // The data output is always attached (before the session starts) so
        // effects can toggle live without a session reconfigure; when idle
        // its connection is disabled and it costs nothing.
        var mirrors = false
        if session.canAddOutput(processor.output) {
            session.addOutput(processor.output)
            let previewMirrored = built.first?.preview.connection?.isVideoMirrored ?? false
            if let connection = processor.output.connection(with: .video) {
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = previewMirrored
                } else {
                    mirrors = previewMirrored
                }
                connection.isEnabled = body.effects.anyEnabled
            }
        }
        self.processorMirrors = mirrors

        if body.geometry.mode == .custom {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for entry in built {
                body.geometry.apply(to: entry.container, fillMode: body.fillMode)
            }
            CATransaction.commit()
        }

        wireProcessor()
        setProcessedMode(effects.anyEnabled)
        rebuildDustEmitters()
    }

    private static func contentsGravity(for gravity: AVLayerVideoGravity) -> CALayerContentsGravity {
        switch gravity {
        case .resizeAspect: return .resizeAspect
        case .resizeAspectFill: return .resizeAspectFill
        default: return .resize
        }
    }

    // MARK: - Effects

    private func wireProcessor() {
        processor.configure(
            segmentation: effects.segmentation,
            handTracking: effects.magicDust,
            mirrored: processorMirrors
        ) { [weak self] product in
            Task { @MainActor in
                self?.showProcessedFrame(product)
            }
        }
    }

    private func showProcessedFrame(_ product: CameraFrameProcessor.FrameProduct) {
        guard !stopped, effects.anyEnabled else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for entry in targetLayers {
            entry.content.contents = product.image
        }
        CATransaction.commit()
        updateHandEmitters(hands: product.hands, bufferSize: product.bufferSize)
    }

    private func rebuildDustEmitters() {
        for emitters in handEmitters {
            for emitter in emitters { emitter.removeFromSuperlayer() }
        }
        handEmitters = []
        smoothedHands = [nil, nil]
        guard effects.magicDust else { return }
        let config = dustEmitterURL.flatMap { PEXEmitterConfig.parse(url: $0) }
            ?? PEXEmitterConfig.builtinSparkle()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for entry in targetLayers {
            var emitters: [CAEmitterLayer] = []
            for _ in 0..<2 {
                let emitter = config.makeEmitterLayer()
                emitter.frame = entry.container.bounds
                emitter.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
                entry.container.addSublayer(emitter)   // above preview + content
                emitters.append(emitter)
            }
            handEmitters.append(emitters)
        }
        CATransaction.commit()
    }

    /// Move the dust to the performer's hands. Positions are low-pass
    /// smoothed (Vision jitters a few px frame-to-frame); a lost hand turns
    /// its emitter's tap off so already-born dust winds down naturally.
    private func updateHandEmitters(hands: [CGPoint], bufferSize: CGSize) {
        guard effects.magicDust, !handEmitters.isEmpty else { return }
        for index in 0..<2 {
            if index < hands.count {
                let previous = smoothedHands[index]
                let smoothed = previous.map {
                    CGPoint(x: $0.x * 0.55 + hands[index].x * 0.45,
                            y: $0.y * 0.55 + hands[index].y * 0.45)
                } ?? hands[index]
                smoothedHands[index] = smoothed
            } else {
                smoothedHands[index] = nil
            }
        }
        let mappingFill: FillMode = geometrySetting.mode == .custom ? .fit : fillModeSetting
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (targetIndex, entry) in targetLayers.enumerated() {
            let emitters = handEmitters[targetIndex]
            for (index, emitter) in emitters.enumerated() {
                if let hand = smoothedHands[index] {
                    emitter.emitterPosition = mapNormalizedPoint(
                        hand, bufferSize: bufferSize,
                        layerSize: entry.container.bounds.size,
                        fillMode: mappingFill
                    )
                    emitter.birthRate = 1
                } else {
                    emitter.birthRate = 0
                }
            }
        }
        CATransaction.commit()
    }

    /// Live effects change from the inspector. Swapping passthrough ↔
    /// processed is just layer visibility — the session keeps running.
    public func applyEffects(_ newEffects: CameraEffects, dustEmitterURL: URL?) {
        guard !stopped else { return }
        effects = newEffects
        self.dustEmitterURL = dustEmitterURL
        wireProcessor()
        setProcessedMode(newEffects.anyEnabled)
        rebuildDustEmitters()
        processor.output.connection(with: .video)?.isEnabled = newEffects.anyEnabled
    }

    private func setProcessedMode(_ processed: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for entry in targetLayers {
            entry.preview.isHidden = processed
            entry.content.isHidden = !processed
            if !processed {
                entry.content.contents = nil   // release the last frame
            }
        }
        CATransaction.commit()
    }

    // MARK: - Geometry / layers

    /// Live geometry update — the transform rides the CONTAINER; the inner
    /// layers only track gravity.
    public func applyGeometry(_ geometry: VideoGeometry, fillMode: FillMode) {
        guard !stopped else { return }
        geometrySetting = geometry
        fillModeSetting = fillMode
        let gravity = geometry.gravity(fillMode: fillMode)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for entry in targetLayers {
            geometry.apply(to: entry.container, fillMode: fillMode)
            entry.preview.videoGravity = gravity
            entry.content.contentsGravity = Self.contentsGravity(for: gravity)
        }
        CATransaction.commit()
    }

    /// Live render-order change from the inspector (1 = back … 10 = front).
    public func applyRenderLayer(_ value: Int) {
        guard !stopped else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for entry in targetLayers {
            entry.container.zPosition = CGFloat(value)
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
        for entry in targetLayers { entry.container.removeFromSuperlayer() }
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
        for layer in containers {
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
