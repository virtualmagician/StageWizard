import AVFoundation
import QuartzCore

extension VideoGeometry {
    /// Layer transform for this geometry on a stage of the given size.
    /// Computed PER LAYER (each display/preview in an output group has its own
    /// stage size) so stage-relative x/y land in the same visual spot on every
    /// screen. Scale happens about the layer's center anchor, translation in
    /// stage units on top (T·S: scale first, then move).
    public func transform(stageSize: CGSize) -> CATransform3D {
        guard mode == .custom else { return CATransform3DIdentity }
        let translation = CATransform3DMakeTranslation(
            CGFloat(x) * stageSize.width,
            CGFloat(y) * stageSize.height,
            0
        )
        return CATransform3DScale(translation, CGFloat(scaleX), CGFloat(scaleY), 1)
    }
}

extension FillMode {
    public var layerGravity: AVLayerVideoGravity {
        switch self {
        case .fit: return .resizeAspect
        case .fill: return .resizeAspectFill
        case .stretch: return .resize
        }
    }
}

extension VideoGeometry {
    /// Gravity for the content: Fill Stage honors the cue's fill mode; Custom
    /// always starts from the aspect-fit image and transforms that.
    public func gravity(fillMode: FillMode) -> AVLayerVideoGravity {
        mode == .custom ? .resizeAspect : fillMode.layerGravity
    }

    /// Apply gravity + transform to a hosted output layer, transform-safely
    /// (never touches `frame` — undefined with a non-identity transform).
    @MainActor
    public func apply(to layer: CALayer, fillMode: FillMode) {
        let stage = layer.superlayer?.bounds.size ?? layer.bounds.size
        if let playerLayer = layer as? AVPlayerLayer {
            playerLayer.videoGravity = gravity(fillMode: fillMode)
        } else if let previewLayer = layer as? AVCaptureVideoPreviewLayer {
            previewLayer.videoGravity = gravity(fillMode: fillMode)
        }
        layer.transform = transform(stageSize: stage)
    }
}
