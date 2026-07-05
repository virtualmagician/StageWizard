import AppKit
import ImageIO
import QuartzCore

public enum StillEngineError: LocalizedError {
    case unreadableImage(String)

    public var errorDescription: String? {
        switch self {
        case .unreadableImage(let name):
            return "Image “\(name)” couldn't be read."
        }
    }
}

/// A rendered slide (or any still image) on stage outputs. Indefinite like a
/// camera cue: holds until stopped; the runtime replaces it when the next
/// slide starts on the same output. Video-only; fades ride layer opacity.
@MainActor
public final class StillCuePlayer: MediaPlayback {
    /// Where this still renders (real displays and/or rehearsal previews).
    public let targets: [OutputTarget]
    /// Real displays only — the app's unplug sweep checks these.
    public var displayIDs: [CGDirectDisplayID] { targets.compactMap(\.displayID) }

    private let layers: [CALayer]
    private var fillModeSetting: FillMode
    private var geometrySetting: VideoGeometry
    private let fadeInDuration: TimeInterval
    private var startedAt: ContinuousClock.Instant?
    private var pausedFlag = false
    private var stopped = false
    private var finishedFired = false
    private var thenStopTask: Task<Void, Never>?

    public var onFinished: (@MainActor (PlaybackEndReason) -> Void)?

    /// Single-display convenience (tests).
    public static func arm(
        body: SlideBody,
        imageURL: URL,
        displayID: CGDirectDisplayID,
        windowFrameOverride: CGRect? = nil
    ) async throws -> StillCuePlayer {
        try await arm(body: body, imageURL: imageURL, targets: [.display(displayID)], windowFrameOverride: windowFrameOverride)
    }

    public static func arm(
        body: SlideBody,
        imageURL: URL,
        targets: [OutputTarget],
        windowFrameOverride: CGRect? = nil
    ) async throws -> StillCuePlayer {
        try StillCuePlayer(
            fillMode: body.fillMode, geometry: body.geometry,
            fadeInDuration: body.fadeInDuration,
            image: try await loadImage(url: imageURL),
            targets: targets, windowFrameOverride: windowFrameOverride
        )
    }

    /// Standalone image cues share the whole pipeline with slides.
    public static func arm(
        body: ImageBody,
        imageURL: URL,
        targets: [OutputTarget],
        windowFrameOverride: CGRect? = nil
    ) async throws -> StillCuePlayer {
        try StillCuePlayer(
            fillMode: body.fillMode, geometry: body.geometry,
            fadeInDuration: body.fadeInDuration,
            image: try await loadImage(url: imageURL),
            targets: targets, windowFrameOverride: windowFrameOverride
        )
    }

    /// Decode off the main actor — 4K PNGs take tens of ms.
    private static func loadImage(url: URL) async throws -> CGImage {
        try await Task.detached(priority: .userInitiated) { () throws -> CGImage in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [
                      kCGImageSourceShouldCache: true,
                  ] as CFDictionary) else {
                throw StillEngineError.unreadableImage(url.lastPathComponent)
            }
            return image
        }.value
    }

    private init(
        fillMode: FillMode,
        geometry: VideoGeometry,
        fadeInDuration: TimeInterval,
        image: CGImage,
        targets: [OutputTarget],
        windowFrameOverride: CGRect?
    ) throws {
        self.targets = targets
        self.fillModeSetting = fillMode
        self.geometrySetting = geometry
        self.fadeInDuration = max(0, fadeInDuration)

        let gravity: CALayerContentsGravity = switch geometry.mode == .custom ? .fit : fillMode {
        case .fit: .resizeAspect
        case .fill: .resizeAspectFill
        case .stretch: .resize
        }

        var built: [CALayer] = []
        var leased: [OutputTarget] = []
        do {
            for target in targets {
                let host = try OutputWindowManager.shared.hostLayer(for: target, frameOverride: windowFrameOverride)
                leased.append(target)
                let layer = CALayer()
                layer.contents = image
                layer.contentsGravity = gravity
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.frame = host.bounds
                layer.opacity = 0
                host.addSublayer(layer)
                CATransaction.commit()
                built.append(layer)
            }
        } catch {
            for layer in built { layer.removeFromSuperlayer() }
            for target in leased { OutputWindowManager.shared.releaseLayer(for: target) }
            throw error
        }
        self.layers = built
        if geometry.mode == .custom {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for layer in built {
                layer.transform = geometry.transform(stageSize: layer.superlayer?.bounds.size ?? layer.bounds.size)
            }
            CATransaction.commit()
        }
    }

    // MARK: - MediaPlayback

    public var duration: TimeInterval? { nil }   // holds until stopped

    public var currentTime: TimeInterval {
        guard let startedAt else { return 0 }
        return startedAt.duration(to: .now).seconds
    }

    public var isPaused: Bool { pausedFlag }
    public var currentVolumeDB: Double { 0 }     // no audio

    public func start() {
        guard !stopped else { return }
        startedAt = .now
        animateOpacity(to: 1, duration: fadeInDuration)
    }

    /// Pausing a still is a no-op visually; track state for the panel.
    public func pause() {
        guard !stopped else { return }
        pausedFlag = true
    }

    public func resume() {
        guard !stopped else { return }
        pausedFlag = false
    }

    public func stop() {
        guard !stopped else { return }
        stopped = true
        thenStopTask?.cancel()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in layers {
            layer.removeAllAnimations()
            layer.removeFromSuperlayer()
        }
        CATransaction.commit()
        for target in targets {
            OutputWindowManager.shared.releaseLayer(for: target)
        }
        if !finishedFired {
            finishedFired = true
            onFinished?(.stopped)
        }
    }

    public func setVolume(dB: Double) {}

    /// No audio, but `thenStop` must still stop after the ramp — this is how
    /// fade-outs, stop cues, panic, and slide replacement reach stills.
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

    /// Live geometry update from the inspector / preview resizes.
    public func applyGeometry(_ geometry: VideoGeometry, fillMode: FillMode) {
        guard !stopped else { return }
        geometrySetting = geometry
        fillModeSetting = fillMode
        let gravity: CALayerContentsGravity = switch geometry.mode == .custom ? .fit : fillMode {
        case .fit: .resizeAspect
        case .fill: .resizeAspectFill
        case .stretch: .resize
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in layers {
            layer.contentsGravity = gravity
            layer.transform = geometry.transform(stageSize: layer.superlayer?.bounds.size ?? layer.bounds.size)
        }
        CATransaction.commit()
    }

    private func animateOpacity(to value: Float, duration: TimeInterval) {
        for layer in layers {
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
