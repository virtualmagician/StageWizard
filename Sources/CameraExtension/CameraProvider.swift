import Foundation
import CoreMediaIO
import CoreVideo
import IOKit.audio
import os
import AppKit

let extLog = Logger(subsystem: "com.marcotempest.stagewizard.camera", category: "extension")

// The virtual "StageWizard Camera": a CoreMedia IO camera extension with a
// SOURCE stream (what Zoom/Teams/OBS read) and a SINK stream (what the
// StageWizard app feeds frames into). When nothing feeds the sink, a
// generated splash frame keeps the device alive and identifiable.
//
// Fixed identifiers — the app finds the device/streams by these.
enum VirtualCameraIDs {
    static let device = UUID(uuidString: "7A9EB600-1000-4000-8000-5747697A6172")!
    static let sourceStream = UUID(uuidString: "7A9EB600-2000-4000-8000-5747697A6172")!
    static let sinkStream = UUID(uuidString: "7A9EB600-3000-4000-8000-5747697A6172")!
    static let width = 1920
    static let height = 1080
    static let frameRate = 30
}

final class CameraProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: CameraDeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = CameraDeviceSource(localizedName: "StageWizard Camera")
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("Failed to add device: \(error.localizedDescription)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {
        extLog.info("provider: client connected \(client.clientID)")
    }

    func disconnect(from client: CMIOExtensionClient) {
        extLog.info("provider: client disconnected \(client.clientID)")
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.providerManufacturer]
    }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let providerProperties = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) {
            providerProperties.manufacturer = "MagicLab AG"
        }
        return providerProperties
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}

final class CameraDeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private var sourceStream: CameraStreamSource!
    private var sinkStream: CameraSinkStreamSource!
    private var videoDescription: CMFormatDescription!
    private var bufferPool: CVPixelBufferPool!
    private var splashBuffer: CVPixelBuffer?

    private let stateQueue = DispatchQueue(label: "com.marcotempest.stagewizard.camera.state")
    private let timerQueue = DispatchQueue(label: "com.marcotempest.stagewizard.camera.timer", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    // stateQueue-confined:
    private var streamingCounter = 0
    private var sinkFeeding = false
    private var sinkClient: CMIOExtensionClient?
    private var lastSinkFrameHostTime: UInt64 = 0

    init(localizedName: String) {
        super.init()
        device = CMIOExtensionDevice(
            localizedName: localizedName,
            deviceID: VirtualCameraIDs.device,
            legacyDeviceID: VirtualCameraIDs.device.uuidString,
            source: self
        )

        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_32BGRA,
            width: Int32(VirtualCameraIDs.width),
            height: Int32(VirtualCameraIDs.height),
            extensions: nil,
            formatDescriptionOut: &videoDescription
        )
        let poolAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: VirtualCameraIDs.width,
            kCVPixelBufferHeightKey as String: VirtualCameraIDs.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, poolAttributes as CFDictionary, &bufferPool)

        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(VirtualCameraIDs.frameRate))
        let streamFormat = CMIOExtensionStreamFormat(
            formatDescription: videoDescription,
            maxFrameDuration: frameDuration,
            minFrameDuration: frameDuration,
            validFrameDurations: nil
        )
        sourceStream = CameraStreamSource(
            localizedName: "StageWizard Camera",
            streamID: VirtualCameraIDs.sourceStream,
            streamFormat: streamFormat,
            device: device,
            deviceSource: self
        )
        sinkStream = CameraSinkStreamSource(
            localizedName: "StageWizard Camera Sink",
            streamID: VirtualCameraIDs.sinkStream,
            streamFormat: streamFormat,
            device: device,
            deviceSource: self
        )
        do {
            try device.addStream(sourceStream.stream)
            try device.addStream(sinkStream.stream)
        } catch {
            fatalError("Failed to add streams: \(error.localizedDescription)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let deviceProperties = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            deviceProperties.transportType = kIOAudioDeviceTransportTypeVirtual
        }
        if properties.contains(.deviceModel) {
            deviceProperties.model = "StageWizard Camera"
        }
        return deviceProperties
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    // MARK: - Source stream lifecycle

    func startStreaming() {
        let count = stateQueue.sync { () -> Int in streamingCounter += 1; return streamingCounter }
        extLog.info("source stream started: \(count) watcher(s)")
        startSplashTimerIfNeeded()
    }

    func stopStreaming() {
        let count = stateQueue.sync { () -> Int in streamingCounter = max(0, streamingCounter - 1); return streamingCounter }
        extLog.info("source stream stopped: \(count) watcher(s)")
    }

    /// Splash frames run at the nominal rate but only get SENT while no
    /// sink frame arrived for >0.5 s — the app's feed always wins.
    private func startSplashTimerIfNeeded() {
        stateQueue.sync {
            guard timer == nil else { return }
            let newTimer = DispatchSource.makeTimerSource(queue: timerQueue)
            newTimer.schedule(
                deadline: .now(),
                repeating: 1.0 / Double(VirtualCameraIDs.frameRate)
            )
            newTimer.setEventHandler { [weak self] in
                self?.emitSplashFrameIfIdle()
            }
            newTimer.resume()
            timer = newTimer
        }
    }

    private func emitSplashFrameIfIdle() {
        let shouldEmit = stateQueue.sync {
            streamingCounter > 0 &&
            (DispatchTime.now().uptimeNanoseconds - lastSinkFrameHostTime) > 500_000_000
        }
        guard shouldEmit, let buffer = splashPixelBuffer() else { return }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(VirtualCameraIDs.frameRate)),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        var formatDescription: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &formatDescription
        )
        guard let formatDescription else { return }
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        if let sampleBuffer {
            sourceStream.stream.send(
                sampleBuffer,
                discontinuity: [],
                hostTimeInNanoseconds: UInt64(timing.presentationTimeStamp.seconds * 1_000_000_000)
            )
        }
    }

    /// Dark slate with a subtle brand-blue band — instantly recognizable as
    /// "StageWizard is connected but no output is routed here yet".
    private func splashPixelBuffer() -> CVPixelBuffer? {
        if let splashBuffer { return splashBuffer }
        guard let bufferPool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, bufferPool, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let context = CGContext(
            data: base,
            width: VirtualCameraIDs.width, height: VirtualCameraIDs.height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
        guard let context else { return nil }
        context.setFillColor(CGColor(red: 0.09, green: 0.10, blue: 0.11, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: VirtualCameraIDs.width, height: VirtualCameraIDs.height))
        context.setFillColor(CGColor(red: 0x7A / 255.0, green: 0x9E / 255.0, blue: 0xB6 / 255.0, alpha: 1))
        context.fill(CGRect(x: 0, y: VirtualCameraIDs.height / 2 - 3, width: VirtualCameraIDs.width, height: 6))
        splashBuffer = buffer
        return buffer
    }

    // MARK: - Sink → source forwarding

    private var consumedCount = 0
    private var forwardedCount = 0
    private var consumeErrorCount = 0

    func sinkStarted(client: CMIOExtensionClient) {
        extLog.info("sink started by client \(client.clientID, privacy: .public)")
        stateQueue.sync {
            sinkClient = client
            sinkFeeding = true
        }
        consumeBuffer()
    }

    /// A NEW app instance authorized while the sink is already running (the
    /// old instance died without stopping) — switch the consume loop over,
    /// or its frames pile up in a queue nobody reads.
    func adoptSinkClient(_ client: CMIOExtensionClient) {
        let switched = stateQueue.sync { () -> Bool in
            guard sinkFeeding, sinkClient?.clientID != client.clientID else {
                sinkClient = client
                return false
            }
            sinkClient = client
            return true
        }
        if switched {
            extLog.info("sink client switched to \(client.clientID, privacy: .public)")
        }
    }

    func sinkStopped() {
        extLog.info("sink stopped")
        stateQueue.sync {
            sinkFeeding = false
            sinkClient = nil
            lastSinkFrameHostTime = 0
        }
    }

    private func consumeBuffer() {
        guard let client = (stateQueue.sync { sinkFeeding ? sinkClient : nil }) else { return }
        sinkStream.stream.consumeSampleBuffer(from: client) { [weak self] sampleBuffer, sequenceNumber, discontinuity, hasMoreSampleBuffers, error in
            guard let self else { return }
            if let error {
                self.consumeErrorCount += 1
                if self.consumeErrorCount == 1 || self.consumeErrorCount % 50 == 0 {
                    extLog.error("consumeSampleBuffer error #\(self.consumeErrorCount) from client \(client.clientID, privacy: .public): \((error as NSError).domain, privacy: .public) \((error as NSError).code) — \(error.localizedDescription, privacy: .public)")
                }
                // Persistent errors would otherwise spin hot.
                self.stateQueue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.consumeBuffer()
                }
                return
            }
            if let sampleBuffer {
                let hostNanos = UInt64(CMClockGetTime(CMClockGetHostTimeClock()).seconds * 1_000_000_000)
                let streaming = self.stateQueue.sync { () -> Bool in
                    self.lastSinkFrameHostTime = DispatchTime.now().uptimeNanoseconds
                    return self.streamingCounter > 0
                }
                self.consumedCount += 1
                if streaming {
                    self.sourceStream.stream.send(
                        sampleBuffer, discontinuity: [], hostTimeInNanoseconds: hostNanos
                    )
                    self.forwardedCount += 1
                }
                if self.consumedCount == 1 || self.consumedCount % 300 == 0 {
                    extLog.info("sink consumed \(self.consumedCount), forwarded \(self.forwardedCount)")
                }
                let output = CMIOExtensionScheduledOutput(
                    sequenceNumber: sequenceNumber, hostTimeInNanoseconds: hostNanos
                )
                self.sinkStream.stream.notifyScheduledOutputChanged(output)
            }
            self.consumeBuffer()
        }
    }
}

// MARK: - Source stream (what conferencing apps read)

final class CameraStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let device: CMIOExtensionDevice
    private let streamFormat: CMIOExtensionStreamFormat
    private weak var deviceSource: CameraDeviceSource?

    init(
        localizedName: String, streamID: UUID,
        streamFormat: CMIOExtensionStreamFormat,
        device: CMIOExtensionDevice, deviceSource: CameraDeviceSource
    ) {
        self.device = device
        self.streamFormat = streamFormat
        self.deviceSource = deviceSource
        super.init()
        stream = CMIOExtensionStream(
            localizedName: localizedName, streamID: streamID,
            direction: .source, clockType: .hostTime, source: self
        )
    }

    var formats: [CMIOExtensionStreamFormat] { [streamFormat] }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = 0
        }
        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration = CMTime(value: 1, timescale: CMTimeScale(VirtualCameraIDs.frameRate))
        }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        true   // any conferencing app may read the camera
    }

    func startStream() throws {
        deviceSource?.startStreaming()
    }

    func stopStream() throws {
        deviceSource?.stopStreaming()
    }
}

// MARK: - Sink stream (what the StageWizard app writes)

final class CameraSinkStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let device: CMIOExtensionDevice
    private let streamFormat: CMIOExtensionStreamFormat
    private weak var deviceSource: CameraDeviceSource?
    private var client: CMIOExtensionClient?

    init(
        localizedName: String, streamID: UUID,
        streamFormat: CMIOExtensionStreamFormat,
        device: CMIOExtensionDevice, deviceSource: CameraDeviceSource
    ) {
        self.device = device
        self.streamFormat = streamFormat
        self.deviceSource = deviceSource
        super.init()
        stream = CMIOExtensionStream(
            localizedName: localizedName, streamID: streamID,
            direction: .sink, clockType: .hostTime, source: self
        )
    }

    var formats: [CMIOExtensionStreamFormat] { [streamFormat] }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration, .streamSinkBufferQueueSize,
         .streamSinkBuffersRequiredForStartup, .streamSinkBufferUnderrunCount, .streamSinkEndOfData]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = 0
        }
        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration = CMTime(value: 1, timescale: CMTimeScale(VirtualCameraIDs.frameRate))
        }
        if properties.contains(.streamSinkBufferQueueSize) {
            streamProperties.sinkBufferQueueSize = 3
        }
        if properties.contains(.streamSinkBuffersRequiredForStartup) {
            streamProperties.sinkBuffersRequiredForStartup = 1
        }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        // Only our own app should feed the camera.
        extLog.info("sink authorizedToStartStream for \(client.clientID, privacy: .public)")
        self.client = client
        deviceSource?.adoptSinkClient(client)
        return true
    }

    func startStream() throws {
        extLog.info("sink startStream (client known: \(self.client != nil))")
        guard let client else { return }
        deviceSource?.sinkStarted(client: client)
    }

    func stopStream() throws {
        deviceSource?.sinkStopped()
    }
}
