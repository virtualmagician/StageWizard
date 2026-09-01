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
    /// D17: targets attached LIVE after arm (mirror checkbox ticked, stage
    /// display opened, program pane re-enabled) — an ORDERED list (not a
    /// dictionary) because `handEmitters` below is index-aligned with
    /// `allTargetLayers` and iteration order must be deterministic.
    private var attachedExtras: [(target: OutputTarget, layers: TargetLayers)] = []
    /// `targetLayers` + any live-attached extras, arm-time entries first —
    /// every per-target loop (effects, geometry, render layer, dust,
    /// opacity) drives this so a mirrored target stays in lockstep.
    private var allTargetLayers: [TargetLayers] { attachedExtras.isEmpty ? targetLayers : targetLayers + attachedExtras.map(\.layers) }
    private var allTargets: [OutputTarget] { attachedExtras.isEmpty ? targets : targets + attachedExtras.map(\.target) }
    private var containers: [CALayer] { allTargetLayers.map(\.container) }
    private let processor = CameraFrameProcessor()
    /// True when the processor must flip frames itself (mirroring couldn't
    /// be pushed down into the capture connection).
    private let processorMirrors: Bool
    /// D25: this cue draws to NO output — it exists purely as a hand-
    /// gesture sensor. Fixed at arm time (mirrors `CameraBody.sensorOnly`);
    /// gates target leasing, attach/detach, geometry/opacity pushes, and
    /// reduces every effects update to gesture-only (see `effectiveEffects`).
    private let sensorOnly: Bool
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
    /// D11 (experimental): fires once when `CameraFrameProcessor` reports a
    /// gesture hold completed. AppModel wires this (via
    /// `EnginePlayerProvider`) to route a GO — see `wireProcessor`.
    public var onGesture: (@MainActor () -> Void)?
    /// D15: fires with the live gesture-tracking readout for the stage
    /// display's gesture pane. `nil` CLEARS it — sent explicitly when
    /// `gestureGo` turns off via a live effects edit, and unconditionally
    /// when this player stops (see `applyEffects`/`stop`), since the
    /// processor itself only streams payloads while actively tracking and
    /// has no way to know the whole player just tore down.
    public var onGestureReadout: (@MainActor (GestureReadout?) -> Void)?

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
            // D25: sensor-only NEVER leases a window/host, no matter what
            // the caller passed — the enforcement point is here, not just a
            // convention that `resolveTargets` happens to return `[]`.
            targets: body.sensorOnly ? [] : targets, windowFrameOverride: windowFrameOverride
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
        self.sensorOnly = body.sensorOnly
        self.effects = Self.effectiveEffects(body.effects, sensorOnly: body.sensorOnly)
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

    /// D25: a sensor-only cue draws to no output at all, so segmentation /
    /// magic dust / chroma key — every effect that only exists to change
    /// what gets DRAWN — are pointless work and forced off regardless of
    /// what's saved on the cue. Gesture GO (enable, pose, hold) is left
    /// completely untouched — gesture tracking is the entire point of
    /// sensor-only mode. Pulled out as a pure static function (rather than
    /// inlined at each call site) so both write sites (`init`, `applyEffects`)
    /// can't drift, and so the reduction itself is directly unit-testable.
    /// `nonisolated` — it touches no actor-isolated state (plain value types
    /// in, plain value types out), so it's callable from a synchronous,
    /// non-MainActor test context without hopping actors.
    nonisolated static func effectiveEffects(_ effects: CameraEffects, sensorOnly: Bool) -> CameraEffects {
        guard sensorOnly else { return effects }
        var reduced = effects
        reduced.segmentation = false
        reduced.magicDust = false
        reduced.chromaKey = false
        return reduced
    }

    private func wireProcessor() {
        processor.configure(
            segmentation: effects.segmentation,
            handTracking: effects.magicDust,
            mirrored: processorMirrors,
            chromaKey: effects.chromaKey,
            chromaKeyColor: effects.chromaKeyColor,
            chromaTolerance: effects.chromaTolerance,
            chromaSoftness: effects.chromaSoftness,
            gestureGo: effects.gestureGo,
            goGesture: effects.goGesture,
            gestureHoldSeconds: effects.gestureHoldSeconds,
            onFrame: { [weak self] product in
                Task { @MainActor in
                    self?.showProcessedFrame(product)
                }
            },
            onGesture: { [weak self] in
                Task { @MainActor in
                    self?.handleGesture()
                }
            },
            onGestureReadout: { [weak self] readout in
                Task { @MainActor in
                    self?.handleGestureReadout(readout)
                }
            }
        )
    }

    /// Subscriber-side hop off the capture queue (see `CameraFrameProcessor.onGesture`).
    /// Re-checks live state before forwarding — a reconfigure or stop landing
    /// between the processor firing and this Task running must not leak a
    /// gesture from a dead/reconfigured player.
    private func handleGesture() {
        guard !stopped, effects.gestureGo else { return }
        onGesture?()
    }

    /// Subscriber-side hop for the D15 readout stream — same re-check as
    /// `handleGesture`, so a readout in flight when the player stops or
    /// disables gestureGo never lands after the explicit `nil` clear below.
    private func handleGestureReadout(_ readout: GestureReadout) {
        guard !stopped, effects.gestureGo else { return }
        onGestureReadout?(readout)
    }

    private func showProcessedFrame(_ product: CameraFrameProcessor.FrameProduct) {
        guard !stopped, effects.anyEnabled else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for entry in allTargetLayers {
            entry.content.contents = product.image
        }
        CATransaction.commit()
        updateHandEmitters(hands: product.hands, bufferSize: product.bufferSize)
    }

    /// Rebuilds EVERY target's dust emitters from scratch (arm-time targets
    /// AND any live-attached extras) — called on every effects edit already,
    /// and reused by `attachTarget`/`detachTarget` for simplicity. A brief
    /// reset of in-flight dust particles on already-running targets when a
    /// new mirror attaches mid-show is an accepted tradeoff (D17) for
    /// keeping `handEmitters`' index-alignment with `allTargetLayers` simple
    /// and always correct, rather than surgically inserting/removing one
    /// target's pair.
    private func rebuildDustEmitters() {
        for emitters in handEmitters {
            for emitter in emitters { emitter.removeFromSuperlayer() }
        }
        handEmitters = []
        smoothedHands = [nil, nil]
        guard effects.magicDust else { return }
        let presetURL = DustPresets.url(for: effects.dustPreset ?? DustPresets.defaultName)
        let config = dustEmitterURL.flatMap { PEXEmitterConfig.parse(url: $0) }
            ?? presetURL.flatMap { PEXEmitterConfig.parse(url: $0) }
            ?? PEXEmitterConfig.builtinSparkle()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for entry in allTargetLayers {
            var emitters: [CAEmitterLayer] = []
            for _ in 0..<2 {
                let emitter = config.makeEmitterLayer(sizeScale: effects.dustScale)
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
        for (targetIndex, entry) in allTargetLayers.enumerated() {
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
        // D25: reduce BEFORE comparing/storing — sensorOnly forces
        // segmentation/magicDust/chromaKey off regardless of what the model
        // carries, same as at arm time.
        let effective = Self.effectiveEffects(newEffects, sensorOnly: sensorOnly)
        if effects.gestureGo, !effective.gestureGo {
            // Gesture tracking is turning off while the cue keeps running —
            // the processor will simply stop streaming, so clear explicitly
            // rather than leaving a stale readout on the stage display.
            onGestureReadout?(nil)
        }
        effects = effective
        self.dustEmitterURL = dustEmitterURL
        wireProcessor()
        setProcessedMode(effective.anyEnabled)
        rebuildDustEmitters()
        processor.output.connection(with: .video)?.isEnabled = effective.anyEnabled
    }

    private func setProcessedMode(_ processed: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for entry in allTargetLayers {
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
    /// layers only track gravity. D25: a sensor-only cue has no container to
    /// move — no-op (this already falls out of `targetLayers` being empty,
    /// but the explicit guard documents the invariant and skips the dead
    /// CATransaction).
    public func applyGeometry(_ geometry: VideoGeometry, fillMode: FillMode) {
        guard !stopped, !sensorOnly else { return }
        geometrySetting = geometry
        fillModeSetting = fillMode
        let gravity = geometry.gravity(fillMode: fillMode)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // D20: mirror (`attachedExtras`) layers deliberately excluded — see
        // `attachTarget`. They stay pinned to `.resizeAspect`/no transform so
        // the stage-display program pane always letterboxes the full frame.
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
        for entry in allTargetLayers {
            entry.container.zPosition = CGFloat(value)
        }
        CATransaction.commit()
    }

    // MARK: - D17: live mirror attach/detach

    /// Lease `target`'s host layer and build a new container (preview +
    /// content siblings, same shape as `init`'s per-target construction)
    /// matching the cue's CURRENT effects mode/fill mode/geometry/render
    /// layer/opacity, then rebuild dust emitters so the new target gets its
    /// own pair too. Idempotent. D25: a sensor-only cue never mirrors
    /// anywhere — nothing draws, so there's nothing to attach — no-op even
    /// if a stale group id somehow makes this cue look like a mirror
    /// candidate (see `CueBody.outputGroupID`, the normal line of defense).
    public func attachTarget(_ target: OutputTarget) {
        guard !stopped, !sensorOnly, !allTargets.contains(target) else { return }
        guard let host = try? OutputWindowManager.shared.hostLayer(for: target) else { return }

        // Mid-fade-safe: read the PRESENTATION opacity of an existing
        // container (falls back to its model value) so an attach mid-fade
        // shows the picture at its current level instead of popping.
        let currentOpacity = (targetLayers.first?.container.presentation() ?? targetLayers.first?.container)?.opacity ?? 0
        let currentZ = targetLayers.first?.container.zPosition ?? 5   // matches CameraBody's default render layer
        // D20: mirror layers always letterbox the full frame — forced
        // `.resizeAspect` (never the cue's own fill mode) and no custom
        // stage-position transform on the container (see the skipped
        // `geometrySetting.apply` below) — since `attachTarget` is only ever
        // reached via the stage-display program pane (see
        // `AppModel.syncMirrorAttachments`), a monitor thumbnail rather than
        // a second real output.
        let gravity: AVLayerVideoGravity = .resizeAspect
        let processed = effects.anyEnabled

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let container = CALayer()
        container.frame = host.bounds
        container.opacity = currentOpacity
        container.zPosition = currentZ

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = gravity
        preview.frame = container.bounds
        preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        preview.isHidden = processed
        container.addSublayer(preview)

        let content = CALayer()
        content.contentsGravity = Self.contentsGravity(for: gravity)
        content.isOpaque = false
        content.frame = container.bounds
        content.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        content.isHidden = !processed
        container.addSublayer(content)

        host.addSublayer(container)
        CATransaction.commit()

        attachedExtras.append((target, TargetLayers(container: container, preview: preview, content: content)))
        rebuildDustEmitters()
    }

    /// Remove the container `attachTarget` added and release its host
    /// lease. Idempotent — a target never attached (or already detached)
    /// no-ops.
    public func detachTarget(_ target: OutputTarget) {
        guard let index = attachedExtras.firstIndex(where: { $0.target == target }) else { return }
        let removed = attachedExtras.remove(at: index)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        removed.layers.container.removeFromSuperlayer()
        CATransaction.commit()
        OutputWindowManager.shared.releaseLayer(for: target)
        rebuildDustEmitters()
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
        onGestureReadout?(nil)
        thenStopTask?.cancel()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for entry in allTargetLayers { entry.container.removeFromSuperlayer() }
        CATransaction.commit()
        let box = sessionBox
        Task.detached(priority: .userInitiated) {
            box.session.stopRunning()
        }
        for target in allTargets { OutputWindowManager.shared.releaseLayer(for: target) }
        attachedExtras.removeAll()
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

    /// D25: sensor-only has no container to fade (`start()`'s fade-in and
    /// `fadeOpacity` both funnel through here) — no-op. Already implied by
    /// `containers` being empty, but the explicit guard pins the invariant.
    private func animateOpacity(to value: Float, duration: TimeInterval) {
        guard !sensorOnly else { return }
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
