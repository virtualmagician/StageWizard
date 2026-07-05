import AppKit
import CoreMediaIO
import os
import ScreenCaptureKit
import SystemExtensions

/// Runs the "StageWizard Camera" — a CoreMedia IO camera extension other
/// apps (Zoom, Teams, OBS…) see as a webcam. StageWizard feeds it by
/// rendering cues into a floating 16:9 monitor panel (ordinary preview
/// machinery, so video/camera/text layers all render natively) and
/// streaming that panel with ScreenCaptureKit into the extension's sink.
@MainActor
@Observable
final class VirtualCameraManager: NSObject {
    /// The monitor panel's stable preview identity — output groups with
    /// "Send to Virtual Webcam" get this appended to their targets.
    static let monitorPreviewID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    static let monitorTarget = OutputTarget.preview(id: monitorPreviewID, title: "Virtual Webcam")
    static let extensionBundleID = "com.marcotempest.stagewizard.camera"

    enum Status: Equatable {
        case inactive
        case activating
        case needsApproval
        case active
        case failed(String)

        var label: String {
            switch self {
            case .inactive: return "Not activated"
            case .activating: return "Activating…"
            case .needsApproval: return "Approve in System Settings → General → Login Items & Extensions"
            case .active: return "Active — apps see “StageWizard Camera”"
            case .failed(let message): return "Failed: \(message)"
            }
        }
    }

    private(set) var status: Status = .inactive
    /// True while frames flow to the extension (monitor open + capture live).
    private(set) var isFeeding = false

    var onWarning: (@MainActor (String) -> Void)?

    private let feed = SinkFeed()
    private var stream: SCStream?
    private var connectTask: Task<Void, Never>?
    private var captureConfiguration: SCStreamConfiguration?
    private var resizeObserver: NSObjectProtocol?
    private let log = Logger(subsystem: "com.marcotempest.stagewizard", category: "virtualcam")

    override init() {
        super.init()
        // If the extension is already installed from an earlier run, the
        // device shows up in CMIO — resume feeding without re-activating.
        connectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, self.status == .inactive else { return }
            let device = SinkFeed.findDevice()
            self.log.info("launch probe: extension device \(device.map(String.init(describing:)) ?? "NOT FOUND")")
            if device != nil {
                self.status = .active
                await self.startFeeding()
            }
        }
    }

    // MARK: - System-extension activation

    func activate() {
        status = .activating
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: Self.extensionBundleID, queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func deactivate() {
        stopFeeding()
        let request = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: Self.extensionBundleID, queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
        status = .inactive
    }

    // MARK: - Feeding

    func startFeeding() async {
        log.info("startFeeding: status \(String(describing: self.status)) feeding \(self.isFeeding)")
        guard status == .active, !isFeeding else { return }

        // Screen Recording permission gates the monitor capture.
        let preflight = CGPreflightScreenCaptureAccess()
        log.info("screen recording preflight: \(preflight)")
        if !preflight {
            CGRequestScreenCaptureAccess()
            guard CGPreflightScreenCaptureAccess() else {
                log.info("screen recording still denied after request")
                onWarning?("Virtual webcam needs Screen Recording access — enable it in System Settings → Privacy & Security → Screen Recording, then relaunch.")
                return
            }
        }

        let connected = feed.connect()
        log.info("sink connect: \(connected)")
        guard connected else {
            onWarning?("Virtual webcam: the camera extension is installed but its device didn't appear yet — try again in a few seconds.")
            return
        }

        // The monitor panel: a pinned 16:9 preview window cues render into.
        OutputWindowManager.shared.openPreview(id: Self.monitorPreviewID, title: "Virtual Webcam")
        guard let window = OutputWindowManager.shared.window(for: Self.monitorTarget) else { return }
        window.contentAspectRatio = NSSize(width: 16, height: 9)
        if window.frame.width < 480 {
            window.setContentSize(NSSize(width: 640, height: 360))
        }

        do {
            try await startCapture(of: window)
            isFeeding = true
            log.info("capture started: window \(window.windowNumber)")
        } catch {
            log.error("capture failed: \(error.localizedDescription)")
            onWarning?("Virtual webcam capture failed: \(error.localizedDescription)")
        }
    }

    func stopFeeding() {
        isFeeding = false
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
            self.resizeObserver = nil
        }
        captureConfiguration = nil
        let stream = stream
        self.stream = nil
        Task { try? await stream?.stopCapture() }
        feed.disconnect()
    }

    private func startCapture(of window: NSWindow) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let scWindow = content.windows.first(where: {
            $0.windowID == CGWindowID(window.windowNumber)
        }) else {
            throw NSError(domain: "StageWizard", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "monitor window not found for capture",
            ])
        }
        let configuration = SCStreamConfiguration()
        configuration.width = 1920
        configuration.height = 1080
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.showsCursor = false
        // Window captures paste at native size into the top-left unless told
        // to scale — the camera frame must be full 1080p.
        configuration.scalesToFit = true
        // Crop the title bar out or the 16:9 content gets pillarboxed.
        configuration.sourceRect = Self.contentSourceRect(of: window)
        configuration.queueDepth = 5

        let stream = SCStream(
            filter: SCContentFilter(desktopIndependentWindow: scWindow),
            configuration: configuration,
            delegate: nil
        )
        try stream.addStreamOutput(feed, type: .screen, sampleHandlerQueue: feed.queue)
        try await stream.startCapture()
        self.stream = stream
        self.captureConfiguration = configuration

        // Track panel resizes: the crop rect is in points and must follow.
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let stream = self.stream,
                      let configuration = self.captureConfiguration,
                      let window = note.object as? NSWindow else { return }
                configuration.sourceRect = Self.contentSourceRect(of: window)
                stream.updateConfiguration(configuration)
            }
        }
    }

    /// The window's content region (title bar excluded), in the top-left
    /// origin point coordinates SCK's sourceRect expects.
    private static func contentSourceRect(of window: NSWindow) -> CGRect {
        let frame = window.frame
        let content = window.contentView?.frame ?? frame
        let titleBarHeight = frame.height - content.height
        return CGRect(x: 0, y: titleBarHeight, width: content.width, height: content.height)
    }
}

// MARK: - Activation delegate

extension VirtualCameraManager: OSSystemExtensionRequestDelegate {
    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in
            self.status = .needsApproval
        }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        Task { @MainActor in
            self.status = .active
            await self.startFeeding()
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Task { @MainActor in
            // Code 1 = missing/unvalidated entitlement — the build was
            // signed without the provisioning profile (see CLAUDE.md).
            if (error as NSError).domain == OSSystemExtensionErrorDomain,
               (error as NSError).code == OSSystemExtensionError.missingEntitlement.rawValue {
                self.status = .failed("this build lacks the system-extension entitlement — a Developer ID provisioning profile is required (see README)")
            } else {
                self.status = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - CMIO sink plumbing + SCK output (capture-queue confined)

/// Owns the extension's sink stream and pushes captured frames into it.
/// All mutable state is confined to `queue` (the SCK sample-handler queue);
/// `@unchecked Sendable` is sound under that invariant.
private final class SinkFeed: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.marcotempest.stagewizard.virtualcam-feed")
    private let log = Logger(subsystem: "com.marcotempest.stagewizard", category: "virtualcam")
    private var receivedCount = 0
    private var completeCount = 0
    private var enqueuedCount = 0
    private var fullCount = 0

    // queue-confined (connect/disconnect hop onto it):
    private var deviceID: CMIODeviceID = 0
    private var sinkStreamID: CMIOStreamID = 0
    private var sinkQueue: CMSimpleQueue?
    // SCK only delivers frames when the window CHANGES — a held frame or
    // still image goes silent and the extension would fall back to its
    // splash. Re-send the last frame at 30 fps so the camera never starves.
    private var lastPixelBuffer: CVPixelBuffer?
    private var lastEnqueueUptime: UInt64 = 0
    private var repeatTimer: DispatchSourceTimer?

    /// SCK's own sample buffers don't survive the XPC hop into the
    /// extension (consumeSampleBuffer fails with OSStatus -6 even with a
    /// full queue) — wrap the IOSurface-backed pixel buffer in a plain,
    /// freshly-stamped vanilla buffer instead.
    private func makeVanillaBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var format: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &format
        )
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var buffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &buffer
        )
        return buffer
    }

    /// The extension's fixed device UUID (VirtualCameraIDs.device).
    private static let deviceUID = "7A9EB600-1000-4000-8000-5747697A6172"

    // MARK: CMIO discovery (C API)

    private static func address(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(selector),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
    }

    static func findDevice() -> CMIODeviceID? {
        var addr = address(kCMIOHardwarePropertyDevices)
        var dataSize: UInt32 = 0
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        guard CMIOObjectGetPropertyDataSize(system, &addr, 0, nil, &dataSize) == 0, dataSize > 0 else { return nil }
        let count = Int(dataSize) / MemoryLayout<CMIODeviceID>.size
        var devices = [CMIODeviceID](repeating: 0, count: count)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &addr, 0, nil, dataSize, &used, &devices) == 0 else { return nil }

        for device in devices {
            var uidAddr = address(kCMIODevicePropertyDeviceUID)
            var uidSize: UInt32 = 0
            guard CMIOObjectGetPropertyDataSize(device, &uidAddr, 0, nil, &uidSize) == 0 else { continue }
            var uid: CFString = "" as CFString
            guard withUnsafeMutablePointer(to: &uid, { pointer in
                CMIOObjectGetPropertyData(device, &uidAddr, 0, nil, uidSize, &used, pointer)
            }) == 0 else { continue }
            if (uid as String).caseInsensitiveCompare(deviceUID) == .orderedSame {
                return device
            }
        }
        return nil
    }

    private static func sinkStream(of device: CMIODeviceID) -> CMIOStreamID? {
        var addr = address(kCMIODevicePropertyStreams)
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(device, &addr, 0, nil, &dataSize) == 0, dataSize > 0 else { return nil }
        let count = Int(dataSize) / MemoryLayout<CMIOStreamID>.size
        var streams = [CMIOStreamID](repeating: 0, count: count)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(device, &addr, 0, nil, dataSize, &used, &streams) == 0 else { return nil }
        // The extension adds its streams source-first, sink-second.
        return streams.count >= 2 ? streams[1] : nil
    }

    /// Open the sink queue + start the stream. Main-thread callable; state
    /// lands on `queue`.
    func connect() -> Bool {
        guard let device = Self.findDevice(), let sink = Self.sinkStream(of: device) else { return false }
        var queueOut: Unmanaged<CMSimpleQueue>?
        guard CMIOStreamCopyBufferQueue(sink, { _, _, _ in }, nil, &queueOut) == 0,
              let simpleQueue = queueOut?.takeRetainedValue() else { return false }
        guard CMIODeviceStartStream(device, sink) == 0 else { return false }
        log.info("sink connected: device \(device) stream \(sink) capacity \(CMSimpleQueueGetCapacity(simpleQueue))")
        queue.sync {
            self.deviceID = device
            self.sinkStreamID = sink
            self.sinkQueue = simpleQueue
            self.startRepeatTimer()
        }
        return true
    }

    /// queue-confined. Re-enqueues the last frame (fresh timestamps) when
    /// SCK has been quiet for >100 ms.
    private func startRepeatTimer() {
        repeatTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 30.0)
        timer.setEventHandler { [weak self] in
            guard let self, let sinkQueue = self.sinkQueue, let pixelBuffer = self.lastPixelBuffer else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            guard now - self.lastEnqueueUptime > 100_000_000 else { return }
            guard CMSimpleQueueGetCount(sinkQueue) < CMSimpleQueueGetCapacity(sinkQueue) else { return }
            if let vanilla = self.makeVanillaBuffer(from: pixelBuffer) {
                self.lastEnqueueUptime = now
                CMSimpleQueueEnqueue(sinkQueue, element: Unmanaged.passRetained(vanilla).toOpaque())
            }
        }
        timer.resume()
        repeatTimer = timer
    }

    func disconnect() {
        queue.sync {
            repeatTimer?.cancel()
            repeatTimer = nil
            lastPixelBuffer = nil
            if deviceID != 0, sinkStreamID != 0 {
                CMIODeviceStopStream(deviceID, sinkStreamID)
            }
            deviceID = 0
            sinkStreamID = 0
            sinkQueue = nil
        }
    }

    // MARK: SCStreamOutput (called on `queue`)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let sinkQueue, sampleBuffer.isValid else { return }
        receivedCount += 1
        // Only complete frames — SCK also delivers idle/blank status frames.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              statusRaw == SCFrameStatus.complete.rawValue else { return }
        completeCount += 1
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastPixelBuffer = pixelBuffer
        lastEnqueueUptime = DispatchTime.now().uptimeNanoseconds
        guard CMSimpleQueueGetCount(sinkQueue) < CMSimpleQueueGetCapacity(sinkQueue) else {
            fullCount += 1
            if fullCount % 90 == 1 {
                log.info("sink queue FULL (\(self.fullCount)x) — extension not consuming?")
            }
            return
        }
        guard let vanilla = makeVanillaBuffer(from: pixelBuffer) else { return }
        CMSimpleQueueEnqueue(sinkQueue, element: Unmanaged.passRetained(vanilla).toOpaque())
        enqueuedCount += 1
        if enqueuedCount == 1 || enqueuedCount % 150 == 0 {
            log.info("pipeline: received \(self.receivedCount) complete \(self.completeCount) enqueued \(self.enqueuedCount) full \(self.fullCount)")
        }
    }
}
