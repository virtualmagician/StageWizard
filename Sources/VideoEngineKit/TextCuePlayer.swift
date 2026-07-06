import AppKit
import QuartzCore

/// Rich text on stage outputs. The RTF renders once onto a fixed
/// 1920×1080 reference canvas (the editor's authoring space, text inside
/// its bounding box) and aspect-fit scales to every target — editor and
/// outputs are pixel-identical at any size. Indefinite: holds until stopped.
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
                // The canvas is a FIXED 1920×1080 reference (what the editor
                // shows); aspect-fit scaling makes every output — full
                // display or tiny preview — render the same picture.
                layer.contentsGravity = .resizeAspect
                layer.isOpaque = false
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.frame = host.bounds
                layer.opacity = 0
                layer.zPosition = CGFloat(body.layer)
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
        let rendered = Self.render(body: body)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in built { layer.contents = rendered }
        CATransaction.commit()
        applyGeometry(body.geometry, fillMode: .stretch)
    }

    // MARK: - Rendering

    /// The authoring space: every text cue is designed and rendered on this
    /// canvas, then aspect-fit scaled to the actual output.
    public static let referenceSize = CGSize(width: 1920, height: 1080)

    /// RTF → bitmap on the 2×-supersampled reference canvas. The text lives
    /// inside its bounding box (normalized stage rect): wrapped to the box
    /// width, vertically centered within it, clipped to it. Background
    /// fills the whole canvas or stays transparent.
    static func render(body: TextBody) -> CGImage? {
        guard let attributed = NSAttributedString(rtf: body.rtf, documentAttributes: nil) else { return nil }

        let size = referenceSize
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
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

        let boxRect = NSRect(
            x: body.box.x * size.width,
            y: body.box.y * size.height,
            width: body.box.width * size.width,
            height: body.box.height * size.height
        )
        let bounding = attributed.boundingRect(
            with: NSSize(width: boxRect.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        NSBezierPath(rect: boxRect).addClip()   // overflow stays inside the box
        let origin = NSPoint(
            x: boxRect.minX,
            y: boxRect.minY + max(0, (boxRect.height - bounding.height) / 2)
        )
        attributed.draw(
            with: NSRect(origin: origin, size: NSSize(width: boxRect.width, height: min(bounding.height, boxRect.height))),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return rep.cgImage
    }

    /// Live content/background/box change from the inspector — one render,
    /// shared by every target layer.
    public func applyText(_ newBody: TextBody) {
        guard !stopped else { return }
        body = newBody
        let rendered = Self.render(body: newBody)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in layers {
            layer.contents = rendered
        }
        CATransaction.commit()
    }

    /// The reference canvas scales with the layer — geometry pushes only
    /// need the transform (no re-render on window resizes).
    public func applyGeometry(_ geometry: VideoGeometry, fillMode: FillMode) {
        guard !stopped else { return }
        body.geometry = geometry
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in layers {
            layer.transform = geometry.transform(stageSize: layer.superlayer?.bounds.size ?? layer.bounds.size)
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
