import AppKit
import QuartzCore

/// Rich text on stage outputs. The RTF is rendered to a bitmap at each
/// target's current size (re-rendered on edits and preview resizes), shown
/// on a CALayer with the same fade/geometry/z-order behavior as stills.
/// Indefinite like a camera cue: holds until stopped.
@MainActor
public final class TextCuePlayer: MediaPlayback {
    public let targets: [OutputTarget]
    public var displayIDs: [CGDirectDisplayID] { targets.compactMap(\.displayID) }

    private let layers: [CALayer]
    private var body: TextBody
    private var startedAt: ContinuousClock.Instant?
    private var pausedFlag = false
    private var stopped = false
    private var finishedFired = false
    private var thenStopTask: Task<Void, Never>?

    public var onFinished: (@MainActor (PlaybackEndReason) -> Void)?

    public static func arm(
        body: TextBody,
        targets: [OutputTarget],
        windowFrameOverride: CGRect? = nil
    ) async throws -> TextCuePlayer {
        try TextCuePlayer(body: body, targets: targets, windowFrameOverride: windowFrameOverride)
    }

    private init(body: TextBody, targets: [OutputTarget], windowFrameOverride: CGRect?) throws {
        self.targets = targets
        self.body = body

        var built: [CALayer] = []
        var leased: [OutputTarget] = []
        do {
            for target in targets {
                let host = try OutputWindowManager.shared.hostLayer(for: target, frameOverride: windowFrameOverride)
                leased.append(target)
                let layer = CALayer()
                layer.contentsGravity = .resize   // canvas is rendered at stage size
                layer.isOpaque = false
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.frame = host.bounds
                layer.opacity = 0
                layer.zPosition = CGFloat(body.layer)
                layer.contents = Self.render(body: body, size: host.bounds.size)
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
        applyGeometry(body.geometry, fillMode: .stretch)
    }

    // MARK: - Rendering

    /// RTF → bitmap at 2× the stage size (crisp on Retina outputs). Text is
    /// drawn full-width (its own paragraph alignment applies) and centered
    /// vertically; background fills the whole canvas or stays transparent.
    static func render(body: TextBody, size: CGSize) -> CGImage? {
        guard size.width >= 1, size.height >= 1 else { return nil }
        guard let attributed = NSAttributedString(rtf: body.rtf, documentAttributes: nil) else { return nil }

        let scale: CGFloat = 2
        let pixelSize = CGSize(width: size.width * scale, height: size.height * scale)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(pixelSize.width), pixelsHigh: Int(pixelSize.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        defer { NSGraphicsContext.restoreGraphicsState() }

        if let bg = body.backgroundColor {
            NSColor(red: bg.red, green: bg.green, blue: bg.blue, alpha: bg.alpha).setFill()
            NSRect(origin: .zero, size: size).fill()
        }

        // Side margins of 4% keep text off the physical screen edge.
        let inset = size.width * 0.04
        let textWidth = size.width - inset * 2
        let bounding = attributed.boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let origin = NSPoint(x: inset, y: max(0, (size.height - bounding.height) / 2))
        attributed.draw(
            with: NSRect(origin: origin, size: NSSize(width: textWidth, height: min(bounding.height, size.height))),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return rep.cgImage
    }

    /// Live content/background change from the inspector.
    public func applyText(_ newBody: TextBody) {
        guard !stopped else { return }
        body = newBody
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in layers {
            layer.contents = Self.render(body: newBody, size: layer.bounds.size)
        }
        CATransaction.commit()
    }

    /// Geometry push doubles as the resize hook: preview-window resizes
    /// re-push geometry app-wide, so re-render at the new canvas size here.
    public func applyGeometry(_ geometry: VideoGeometry, fillMode: FillMode) {
        guard !stopped else { return }
        body.geometry = geometry
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in layers {
            layer.transform = geometry.transform(stageSize: layer.superlayer?.bounds.size ?? layer.bounds.size)
            layer.contents = Self.render(body: body, size: layer.bounds.size)
        }
        CATransaction.commit()
    }

    /// Live render-order change from the inspector (1 = back … 10 = front).
    public func applyRenderLayer(_ value: Int) {
        guard !stopped else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in layers {
            layer.zPosition = CGFloat(value)
        }
        CATransaction.commit()
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
        animateOpacity(to: 1, duration: max(0, body.fadeInDuration))
    }

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
    /// fade-outs, stop cues, and panic reach text.
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
