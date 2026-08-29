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
    private var chromaKeyEnabled = false
    private var chromaKeyColor = RGBAColor(red: 0, green: 1, blue: 0)
    private var chromaTolerance: Double = 0.35
    private var chromaSoftness: Double = 0.1
    private var onFrame: (@Sendable (FrameProduct) -> Void)?
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    /// Cube dimension for the chroma-key lattice — 64 per axis, per the D10 spec.
    private static let chromaCubeSize = 64
    /// Params the currently-loaded cube data was built from — rebuild only
    /// when these actually change (the ~1 MB float table is fine on a param
    /// change, never per frame).
    private struct ChromaCubeParams: Equatable {
        let color: RGBAColor
        let tolerance: Double
        let softness: Double
    }
    private var cachedChromaParams: ChromaCubeParams?
    private let chromaKeyFilter: CIColorCubeWithColorSpace = {
        let filter = CIFilter.colorCubeWithColorSpace()
        filter.cubeDimension = Float(CameraFrameProcessor.chromaCubeSize)
        // The cube is authored in plain sRGB-gamma 0…1 values — the same
        // domain as the NSColor(sRGB) components the inspector's ColorPicker
        // writes into `chromaKeyColor` (see InspectorView). Giving the
        // filter device RGB here makes it convert the (extended-linear)
        // working-space image into that domain before indexing the cube, so
        // the lattice lines up with the color the user actually picked.
        filter.colorSpace = CGColorSpaceCreateDeviceRGB()
        return filter
    }()
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
        chromaKey: Bool,
        chromaKeyColor: RGBAColor,
        chromaTolerance: Double,
        chromaSoftness: Double,
        onFrame: @escaping @Sendable (FrameProduct) -> Void
    ) {
        queue.async {
            self.segmentationEnabled = segmentation
            self.handTrackingEnabled = handTracking
            self.mirrored = mirrored
            self.chromaKeyEnabled = chromaKey
            self.chromaKeyColor = chromaKeyColor
            self.chromaTolerance = min(max(chromaTolerance, 0), 1)
            self.chromaSoftness = min(max(chromaSoftness, 0), 1)
            self.onFrame = onFrame
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard segmentationEnabled || handTrackingEnabled || chromaKeyEnabled,
              let onFrame,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        var requests: [VNRequest] = []
        if segmentationEnabled { requests.append(segmentationRequest) }
        if handTrackingEnabled { requests.append(handRequest) }
        if !requests.isEmpty {
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
            try? handler.perform(requests)
        }

        var image = CIImage(cvPixelBuffer: pixelBuffer)
        if mirrored {
            image = image
                .transformed(by: CGAffineTransform(scaleX: -1, y: 1))
                .transformed(by: CGAffineTransform(translationX: image.extent.width, y: 0))
        }

        // Chroma key sits BETWEEN mirror and segmentation: it punches the
        // background's alpha to 0 first, then the person mask below
        // composites on top — the two effects compose (a keyed background
        // still shows a segmentation-shaped hole).
        if chromaKeyEnabled {
            image = applyChromaKey(to: image)
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

    // MARK: - Chroma key

    /// Runs the cached `CIColorCubeWithColorSpace` lookup over `image`,
    /// rebuilding the cube's lattice data first if the live params changed
    /// since the last frame. The filter is a pointwise kernel — output
    /// extent matches input, so callers can keep using `image.extent`.
    private func applyChromaKey(to image: CIImage) -> CIImage {
        let params = ChromaCubeParams(color: chromaKeyColor, tolerance: chromaTolerance, softness: chromaSoftness)
        if cachedChromaParams != params {
            chromaKeyFilter.cubeData = Self.chromaKeyCubeData(
                color: params.color, tolerance: params.tolerance, softness: params.softness, size: Self.chromaCubeSize
            )
            cachedChromaParams = params
        }
        chromaKeyFilter.inputImage = image
        return chromaKeyFilter.outputImage ?? image
    }

    /// YCbCr (BT.601, SDTV) chroma distance between two RGB colors — the
    /// standard luma-independent green-screen metric. The conventional +0.5
    /// chroma offset is skipped: it's a constant shift that cancels out in
    /// the subtraction below, so distances come out identical without it.
    static func chromaDistance(_ a: RGBAColor, _ b: RGBAColor) -> Double {
        func cbcr(_ c: RGBAColor) -> (cb: Double, cr: Double) {
            let cb = -0.168736 * c.red - 0.331264 * c.green + 0.5 * c.blue
            let cr = 0.5 * c.red - 0.418688 * c.green - 0.081312 * c.blue
            return (cb, cr)
        }
        let x = cbcr(a)
        let y = cbcr(b)
        let dCb = x.cb - y.cb
        let dCr = x.cr - y.cr
        return (dCb * dCb + dCr * dCr).squareRoot()
    }

    /// Hermite smoothstep from 0 at `edge0` to 1 at `edge1`, clamped outside
    /// that band. Falls back to a hard step if the band has zero width.
    static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        guard edge1 > edge0 else { return x < edge0 ? 0 : 1 }
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Builds the RGBA float32 lattice for a chroma-key `CIColorCubeWithColorSpace`:
    /// `size`³ cells in Apple's documented CIColorCube ordering — columns
    /// indexed by red (fastest), rows by green, planes by blue (slowest) —
    /// each cell's RGB PREMULTIPLIED by its own alpha (the filter's
    /// documented input format).
    ///
    /// A cell's alpha comes from `smoothstep` over its YCbCr chroma distance
    /// to `color`: cells within `tolerance − softness` of the key color key
    /// fully transparent (alpha 0, i.e. background); cells beyond
    /// `tolerance + softness` stay fully opaque (alpha 1, foreground); the
    /// `softness`-wide band between falls off smoothly and monotonically.
    static func chromaKeyCubeData(
        color: RGBAColor,
        tolerance: Double,
        softness: Double,
        size: Int = chromaCubeSize
    ) -> Data {
        let t = min(max(tolerance, 0), 1)
        let s = min(max(softness, 0), 1)
        let edge0 = max(0, t - s)
        let edge1 = t + s
        let denominator = Double(max(size - 1, 1))
        var cube = [Float](repeating: 0, count: size * size * size * 4)
        var offset = 0
        for blueIndex in 0..<size {
            let blue = Double(blueIndex) / denominator
            for greenIndex in 0..<size {
                let green = Double(greenIndex) / denominator
                for redIndex in 0..<size {
                    let red = Double(redIndex) / denominator
                    let distance = chromaDistance(RGBAColor(red: red, green: green, blue: blue), color)
                    let alpha = smoothstep(edge0, edge1, distance)
                    cube[offset]     = Float(red * alpha)
                    cube[offset + 1] = Float(green * alpha)
                    cube[offset + 2] = Float(blue * alpha)
                    cube[offset + 3] = Float(alpha)
                    offset += 4
                }
            }
        }
        return cube.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
