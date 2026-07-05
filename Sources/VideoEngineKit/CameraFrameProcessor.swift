import AVFoundation
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins

/// Per-frame processing for camera effects: Vision person segmentation
/// (background → transparent) and hand-pose tracking (for magic-dust
/// emitters). Lives entirely OFF the main actor: every mutable property is
/// confined to the capture queue (`queue`) — the delegate callback, the
/// Vision requests, and the CoreImage render all run there. The only thing
/// that leaves is an immutable FrameProduct handed to `onFrame`.
/// `@unchecked Sendable` is sound under that queue-confinement invariant
/// (same pattern as CameraCuePlayer.SessionBox).
final class CameraFrameProcessor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {

    /// One processed frame + everything the UI thread needs to place it.
    struct FrameProduct: @unchecked Sendable {
        /// Composited frame (BGRA; transparent background when segmenting).
        let image: CGImage
        /// Capture-buffer pixel size (for coordinate mapping).
        let bufferSize: CGSize
        /// Normalized hand positions (0…1, bottom-left origin), ≤2 entries.
        let hands: [CGPoint]
    }

    let output = AVCaptureVideoDataOutput()

    private let queue = DispatchQueue(label: "com.marcotempest.stagewizard.camera-effects")

    // Queue-confined state — touch ONLY on `queue`.
    private var segmentationEnabled = false
    private var handTrackingEnabled = false
    private var mirrored = false
    private var onFrame: (@Sendable (FrameProduct) -> Void)?
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let segmentationRequest: VNGeneratePersonSegmentationRequest = {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced   // ANE-backed; comfortable at 1080p30
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return request
    }()
    private let handRequest: VNDetectHumanHandPoseRequest = {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
        return request
    }()

    override init() {
        super.init()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)
    }

    /// Reconfigure live; safe from any thread.
    func configure(
        segmentation: Bool,
        handTracking: Bool,
        mirrored: Bool,
        onFrame: @escaping @Sendable (FrameProduct) -> Void
    ) {
        queue.async {
            self.segmentationEnabled = segmentation
            self.handTrackingEnabled = handTracking
            self.mirrored = mirrored
            self.onFrame = onFrame
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard segmentationEnabled || handTrackingEnabled,
              let onFrame,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        var requests: [VNRequest] = []
        if segmentationEnabled { requests.append(segmentationRequest) }
        if handTrackingEnabled { requests.append(handRequest) }
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try? handler.perform(requests)

        var image = CIImage(cvPixelBuffer: pixelBuffer)
        if mirrored {
            image = image
                .transformed(by: CGAffineTransform(scaleX: -1, y: 1))
                .transformed(by: CGAffineTransform(translationX: image.extent.width, y: 0))
        }

        if segmentationEnabled,
           let maskBuffer = segmentationRequest.results?.first?.pixelBuffer {
            var mask = CIImage(cvPixelBuffer: maskBuffer)
            if mirrored {
                mask = mask
                    .transformed(by: CGAffineTransform(scaleX: -1, y: 1))
                    .transformed(by: CGAffineTransform(translationX: mask.extent.width, y: 0))
            }
            mask = mask.transformed(by: CGAffineTransform(
                scaleX: image.extent.width / mask.extent.width,
                y: image.extent.height / mask.extent.height
            ))
            let blend = CIFilter.blendWithMask()
            blend.inputImage = image
            blend.backgroundImage = CIImage(color: .clear).cropped(to: image.extent)
            blend.maskImage = mask
            image = blend.outputImage ?? image
        }

        var hands: [CGPoint] = []
        if handTrackingEnabled, let observations = handRequest.results {
            for observation in observations.prefix(2) {
                // The palm center reads better than fingertips for dust.
                guard let point = try? observation.recognizedPoint(.middleMCP),
                      point.confidence > 0.3 else { continue }
                let x = mirrored ? 1 - point.location.x : point.location.x
                hands.append(CGPoint(x: x, y: point.location.y))
            }
        }

        // GPU→CPU readback; ~8 MB/frame at 1080p — fine on Apple Silicon.
        // If a future rig needs 4K here, switch to an IOSurface-backed
        // CVPixelBufferPool and hand layers the surface instead.
        guard let cgImage = ciContext.createCGImage(image, from: image.extent) else { return }
        onFrame(FrameProduct(
            image: cgImage,
            bufferSize: image.extent.size,
            hands: hands
        ))
    }
}
