import Foundation

/// Type-specific payload of a cue. Encoded flat with a `"type"` discriminator
/// so show files stay diff-friendly and forward-migratable. Unknown types
/// decode to `.broken` instead of failing the whole file.
public enum CueBody: Hashable, Sendable {
    case audio(AudioBody)
    case video(VideoBody)
    case camera(CameraBody)
    case image(ImageBody)
    case text(TextBody)
    case slide(SlideBody)
    case fade(FadeBody)
    case stop(StopBody)
    case oscSend(OSCSendBody)
    case group(GroupBody)
    case broken(BrokenBody)

    public var defaultName: String {
        switch self {
        case .audio(let body): return body.media.fileName
        case .video(let body): return body.media.fileName
        case .camera(let body): return body.cameraName ?? "Camera"
        case .image(let body): return body.media.fileName
        case .text(let body):
            let firstLine = body.plainPreview
                .components(separatedBy: .newlines).first?
                .trimmingCharacters(in: .whitespaces) ?? ""
            return firstLine.isEmpty ? "Text" : String(firstLine.prefix(40))
        case .slide(let body):
            if let index = body.slideIndex, let count = body.slideCount {
                return "\(body.deckName) · \(index)/\(count)"
            }
            return body.media.fileName
        case .fade: return "Fade"
        case .stop: return "Stop"
        case .oscSend(let body): return body.address != "/" ? body.address : "OSC Send"
        case .group(let body): return body.mode == .timeline ? "Timeline Group" : "Group"
        case .broken(let body): return "Unknown cue (\(body.originalType))"
        }
    }

    public var typeLabel: String {
        switch self {
        case .audio: return "Audio"
        case .video: return "Video"
        case .camera: return "Camera"
        case .image: return "Image"
        case .text: return "Text"
        case .slide: return "Slide"
        case .fade: return "Fade"
        case .stop: return "Stop"
        case .oscSend: return "OSC Send"
        case .group: return "Group"
        case .broken: return "Broken"
        }
    }

    /// The output group this cue's visual output targets — every kind that
    /// carries `outputGroupID` (video/camera/image/text/slide); nil for
    /// audio/fade/stop/group/broken, and nil for a video/camera cue still on
    /// the legacy direct-`display` assignment (no group at all). D17: the
    /// single place that extracts a cue's group id, shared by the live
    /// mirror-attach diff (`AppModel.syncMirrorAttachments`) and anywhere
    /// else that needs it — mirrors exactly the `groupID` `EngineBridge`
    /// resolves targets against at arm time. D25: a sensor-only camera cue
    /// draws nowhere, so it reports nil here even if a group id is still
    /// saved on the body — it must never be treated as a live-mirror
    /// candidate.
    public var outputGroupID: UUID? {
        switch self {
        case .video(let body): return body.outputGroupID
        case .camera(let body): return body.sensorOnly ? nil : body.outputGroupID
        case .image(let body): return body.outputGroupID
        case .text(let body): return body.outputGroupID
        case .slide(let body): return body.outputGroupID
        case .audio, .fade, .stop, .oscSend, .group, .broken: return nil
        }
    }
}

extension CueBody: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
    }

    private enum Kind: String, Codable {
        case audio, video, camera, image, text, slide, fade, stop, oscSend, group
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawType = try container.decode(String.self, forKey: .type)
        switch Kind(rawValue: rawType) {
        case .audio: self = .audio(try AudioBody(from: decoder))
        case .video: self = .video(try VideoBody(from: decoder))
        case .camera: self = .camera(try CameraBody(from: decoder))
        case .image: self = .image(try ImageBody(from: decoder))
        case .text: self = .text(try TextBody(from: decoder))
        case .slide: self = .slide(try SlideBody(from: decoder))
        case .fade: self = .fade(try FadeBody(from: decoder))
        case .stop: self = .stop(try StopBody(from: decoder))
        case .oscSend: self = .oscSend(try OSCSendBody(from: decoder))
        case .group: self = .group(try GroupBody(from: decoder))
        case nil: self = .broken(BrokenBody(originalType: rawType))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .audio(let body):
            try container.encode(Kind.audio, forKey: .type)
            try body.encode(to: encoder)
        case .video(let body):
            try container.encode(Kind.video, forKey: .type)
            try body.encode(to: encoder)
        case .camera(let body):
            try container.encode(Kind.camera, forKey: .type)
            try body.encode(to: encoder)
        case .image(let body):
            try container.encode(Kind.image, forKey: .type)
            try body.encode(to: encoder)
        case .text(let body):
            try container.encode(Kind.text, forKey: .type)
            try body.encode(to: encoder)
        case .slide(let body):
            try container.encode(Kind.slide, forKey: .type)
            try body.encode(to: encoder)
        case .fade(let body):
            try container.encode(Kind.fade, forKey: .type)
            try body.encode(to: encoder)
        case .stop(let body):
            try container.encode(Kind.stop, forKey: .type)
            try body.encode(to: encoder)
        case .oscSend(let body):
            try container.encode(Kind.oscSend, forKey: .type)
            try body.encode(to: encoder)
        case .group(let body):
            try container.encode(Kind.group, forKey: .type)
            try body.encode(to: encoder)
        case .broken(let body):
            // Preserve the original tag so a newer app version can still claim it.
            try container.encode(body.originalType, forKey: .type)
        }
    }
}

/// Placeholder for cue types this app version doesn't understand.
public struct BrokenBody: Codable, Hashable, Sendable {
    public var originalType: String

    public init(originalType: String) {
        self.originalType = originalType
    }
}

// MARK: - Media cues

/// Floor below which a dB value is treated as silence (-inf).
public let silenceFloorDB: Double = -120

public struct AudioBody: Codable, Hashable, Sendable {
    public var media: MediaReference
    /// In-point trim, seconds from file start.
    public var startTime: TimeInterval
    /// Out-point trim; nil = play to file end.
    public var endTime: TimeInterval?
    public var playCount: Int
    public var infiniteLoop: Bool
    /// 0 = unity gain; `silenceFloorDB` = silence.
    public var volumeDB: Double
    /// Authored edge fades; 0 = none.
    public var fadeInDuration: TimeInterval
    public var fadeOutDuration: TimeInterval
    /// Core Audio device UID; nil = system default output.
    public var outputDeviceUID: String?
    /// Human-readable device name for the UI when the UID doesn't resolve.
    public var outputDeviceName: String?
    /// Playback speed multiplier, 0.25…4 (1 = normal). Applied via
    /// AVAudioUnitVarispeed, which is tape-style — pitch shifts with rate.
    public var rate: Double
    /// Named points on the file-time axis; UI-authored, and the anchor for
    /// FollowAction.autoContinueAtMarker.
    public var markers: [CueMarker]

    public init(
        media: MediaReference,
        startTime: TimeInterval = 0,
        endTime: TimeInterval? = nil,
        playCount: Int = 1,
        infiniteLoop: Bool = false,
        volumeDB: Double = 0,
        fadeInDuration: TimeInterval = 0,
        fadeOutDuration: TimeInterval = 0,
        outputDeviceUID: String? = nil,
        outputDeviceName: String? = nil,
        rate: Double = 1,
        markers: [CueMarker] = []
    ) {
        self.media = media
        self.startTime = startTime
        self.endTime = endTime
        self.playCount = playCount
        self.infiniteLoop = infiniteLoop
        self.volumeDB = volumeDB
        self.fadeInDuration = fadeInDuration
        self.fadeOutDuration = fadeOutDuration
        self.outputDeviceUID = outputDeviceUID
        self.outputDeviceName = outputDeviceName
        self.rate = min(max(rate, 0.25), 4)
        self.markers = markers
    }

    private enum CodingKeys: String, CodingKey {
        case media, startTime, endTime, playCount, infiniteLoop, volumeDB
        case fadeInDuration, fadeOutDuration, outputDeviceUID, outputDeviceName, rate, markers
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        media = try c.decode(MediaReference.self, forKey: .media)
        startTime = try c.decode(TimeInterval.self, forKey: .startTime)
        endTime = try c.decodeIfPresent(TimeInterval.self, forKey: .endTime)
        playCount = try c.decode(Int.self, forKey: .playCount)
        infiniteLoop = try c.decode(Bool.self, forKey: .infiniteLoop)
        volumeDB = try c.decode(Double.self, forKey: .volumeDB)
        fadeInDuration = try c.decode(TimeInterval.self, forKey: .fadeInDuration)
        fadeOutDuration = try c.decode(TimeInterval.self, forKey: .fadeOutDuration)
        outputDeviceUID = try c.decodeIfPresent(String.self, forKey: .outputDeviceUID)
        outputDeviceName = try c.decodeIfPresent(String.self, forKey: .outputDeviceName)
        // Pre-D3 files predate rate; default to normal speed.
        rate = min(max(try c.decodeIfPresent(Double.self, forKey: .rate) ?? 1, 0.25), 4)
        // Pre-D4 files predate markers.
        markers = try c.decodeIfPresent([CueMarker].self, forKey: .markers) ?? []
    }
}

/// How video/camera content is placed on its stage (output). Fill Stage uses
/// the whole output per FillMode; Custom positions and scales the aspect-fit
/// image. Units are STAGE-RELATIVE so one layout means the same thing on
/// every display of a multi-screen output group: x/y are fractions of the
/// stage size (+x right, +y up; 0.25 = quarter of the stage), scale is a
/// multiplier on the aspect-fit size.
public struct VideoGeometry: Codable, Hashable, Sendable {
    public enum Mode: String, Codable, Hashable, Sendable {
        case fillStage, custom
    }

    public var mode: Mode
    public var x: Double
    public var y: Double
    public var scaleX: Double
    public var scaleY: Double

    public init(mode: Mode = .fillStage, x: Double = 0, y: Double = 0, scaleX: Double = 1, scaleY: Double = 1) {
        self.mode = mode
        self.x = x
        self.y = y
        self.scaleX = scaleX
        self.scaleY = scaleY
    }

    public static let fillStage = VideoGeometry()

    public var isIdentity: Bool {
        x == 0 && y == 0 && scaleX == 1 && scaleY == 1
    }
}

public enum FillMode: String, Codable, Hashable, Sendable, CaseIterable {
    /// Letterbox/pillarbox to fit inside the display.
    case fit
    /// Fill the display, cropping overflow.
    case fill
    /// Distort to exactly match the display.
    case stretch
}

/// What this cue's video output does when playback reaches the out-point.
/// Sequencing of the NEXT cue is `Cue.follow`, not this.
public enum VideoEndBehavior: String, Codable, Hashable, Sendable, CaseIterable {
    /// Last frame persists on the output; instance stays active until stopped.
    case holdLastFrame
    /// Output fades/blanks and the player is released.
    case stopAndUnload
}

public struct VideoBody: Codable, Hashable, Sendable {
    public var media: MediaReference
    public var startTime: TimeInterval
    public var endTime: TimeInterval?
    public var playCount: Int
    public var infiniteLoop: Bool
    /// Gain applied to the file's embedded audio track.
    public var volumeDB: Double
    /// Core Audio device UID for the embedded audio; nil = system default.
    public var audioDeviceUID: String?
    public var audioDeviceName: String?
    /// Legacy direct display assignment (pre-v3); superseded by outputGroupID.
    public var display: DisplayFingerprint?
    /// Virtual output the cue plays on; nil = operator's main display.
    public var outputGroupID: UUID?
    public var fillMode: FillMode
    public var geometry: VideoGeometry
    public var endBehavior: VideoEndBehavior
    public var fadeInDuration: TimeInterval
    public var fadeOutDuration: TimeInterval
    /// Render order on the output, 1 (background) … 10 (front).
    /// Equal layers stack by start order, like before layers existed.
    public var layer: Int
    /// Playback speed multiplier, 0.25…4 (1 = normal).
    public var rate: Double
    /// Named points on the file-time axis; UI-authored, and the anchor for
    /// FollowAction.autoContinueAtMarker.
    public var markers: [CueMarker]

    public init(
        media: MediaReference,
        startTime: TimeInterval = 0,
        endTime: TimeInterval? = nil,
        playCount: Int = 1,
        infiniteLoop: Bool = false,
        volumeDB: Double = 0,
        audioDeviceUID: String? = nil,
        audioDeviceName: String? = nil,
        display: DisplayFingerprint? = nil,
        outputGroupID: UUID? = nil,
        fillMode: FillMode = .fit,
        geometry: VideoGeometry = .fillStage,
        endBehavior: VideoEndBehavior = .stopAndUnload,
        fadeInDuration: TimeInterval = 0,
        fadeOutDuration: TimeInterval = 0,
        layer: Int = 5,
        rate: Double = 1,
        markers: [CueMarker] = []
    ) {
        self.media = media
        self.startTime = startTime
        self.endTime = endTime
        self.playCount = playCount
        self.infiniteLoop = infiniteLoop
        self.volumeDB = volumeDB
        self.audioDeviceUID = audioDeviceUID
        self.audioDeviceName = audioDeviceName
        self.display = display
        self.outputGroupID = outputGroupID
        self.fillMode = fillMode
        self.geometry = geometry
        self.endBehavior = endBehavior
        self.fadeInDuration = fadeInDuration
        self.fadeOutDuration = fadeOutDuration
        self.layer = layer.clampedToLayerRange
        self.rate = min(max(rate, 0.25), 4)
        self.markers = markers
    }

    private enum CodingKeys: String, CodingKey {
        case media, startTime, endTime, playCount, infiniteLoop, volumeDB
        case audioDeviceUID, audioDeviceName, display, outputGroupID
        case fillMode, geometry, endBehavior, fadeInDuration, fadeOutDuration, layer, rate, markers
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        media = try c.decode(MediaReference.self, forKey: .media)
        startTime = try c.decode(TimeInterval.self, forKey: .startTime)
        endTime = try c.decodeIfPresent(TimeInterval.self, forKey: .endTime)
        playCount = try c.decode(Int.self, forKey: .playCount)
        infiniteLoop = try c.decode(Bool.self, forKey: .infiniteLoop)
        volumeDB = try c.decode(Double.self, forKey: .volumeDB)
        audioDeviceUID = try c.decodeIfPresent(String.self, forKey: .audioDeviceUID)
        audioDeviceName = try c.decodeIfPresent(String.self, forKey: .audioDeviceName)
        display = try c.decodeIfPresent(DisplayFingerprint.self, forKey: .display)
        outputGroupID = try c.decodeIfPresent(UUID.self, forKey: .outputGroupID)
        fillMode = try c.decode(FillMode.self, forKey: .fillMode)
        // Pre-v4 files predate geometry.
        geometry = try c.decodeIfPresent(VideoGeometry.self, forKey: .geometry) ?? .fillStage
        endBehavior = try c.decode(VideoEndBehavior.self, forKey: .endBehavior)
        fadeInDuration = try c.decode(TimeInterval.self, forKey: .fadeInDuration)
        fadeOutDuration = try c.decode(TimeInterval.self, forKey: .fadeOutDuration)
        layer = (try c.decodeIfPresent(Int.self, forKey: .layer) ?? 5).clampedToLayerRange
        // Pre-D3 files predate rate; default to normal speed.
        rate = min(max(try c.decodeIfPresent(Double.self, forKey: .rate) ?? 1, 0.25), 4)
        // Pre-D4 files predate markers.
        markers = try c.decodeIfPresent([CueMarker].self, forKey: .markers) ?? []
    }
}

extension Int {
    /// Render layers live in 1…10.
    var clampedToLayerRange: Int { Swift.min(Swift.max(self, 1), 10) }
}

/// Live effects applied to a camera cue's frames. All default OFF — a cue
/// with effects disabled uses the zero-cost passthrough preview path.
public struct CameraEffects: Codable, Hashable, Sendable {
    /// Vision person segmentation: the background turns transparent, so
    /// render layers BEHIND the camera show through around the performer.
    public var segmentation: Bool
    /// Particle emitters that follow the performer's hands.
    public var magicDust: Bool
    /// Custom Particle Designer .pex file; wins over `dustPreset`.
    public var dustEmitter: MediaReference?
    /// Bundled preset name (Support/presets); nil = default preset.
    public var dustPreset: String?
    /// Particle size multiplier, 0.5…10.
    public var dustScale: Double
    /// Green-screen keying: pixels near `chromaKeyColor` turn transparent.
    /// Runs BEFORE segmentation in the pipeline, so the two compose (a
    /// keyed-out background still shows through a segmentation hole too).
    public var chromaKey: Bool
    /// The color to key out. Defaults to pure green.
    public var chromaKeyColor: RGBAColor
    /// YCbCr chroma-distance threshold, 0…1: how close to `chromaKeyColor`
    /// (luma-independent) counts as background.
    public var chromaTolerance: Double
    /// Width of the smoothstep falloff band straddling `chromaTolerance`,
    /// 0…1 — 0 is a hard cutoff, larger softens the edge.
    public var chromaSoftness: Double
    /// Experimental (D11): fires GO when `goGesture` is held to the camera
    /// for ~1 s. Requires the Vision hand-pose request, so it counts toward
    /// `anyEnabled` (and activates the processed capture path) even when
    /// `magicDust` — the OTHER hand-pose consumer — is off.
    public var gestureGo: Bool
    /// D15: which hand shape `gestureGo` waits for. Default `.openPalm` —
    /// D11 only ever recognized an open palm, so an old file with
    /// `gestureGo: true` and no `goGesture` key behaves exactly as before.
    public var goGesture: HandGesture
    /// D25: how long `goGesture` must be held before GO fires, 0.25…5 s.
    /// Default 1.0 matches the fixed duration every file before D25 used —
    /// an old file with no key decodes to exactly the old behavior.
    public var gestureHoldSeconds: Double

    public init(
        segmentation: Bool = false,
        magicDust: Bool = false,
        dustEmitter: MediaReference? = nil,
        dustPreset: String? = nil,
        dustScale: Double = 1,
        chromaKey: Bool = false,
        chromaKeyColor: RGBAColor = RGBAColor(red: 0, green: 1, blue: 0),
        chromaTolerance: Double = 0.35,
        chromaSoftness: Double = 0.1,
        gestureGo: Bool = false,
        goGesture: HandGesture = .openPalm,
        gestureHoldSeconds: Double = 1.0
    ) {
        self.segmentation = segmentation
        self.magicDust = magicDust
        self.dustEmitter = dustEmitter
        self.dustPreset = dustPreset
        self.dustScale = min(max(dustScale, 0.5), 10)
        self.chromaKey = chromaKey
        self.chromaKeyColor = chromaKeyColor
        self.chromaTolerance = min(max(chromaTolerance, 0), 1)
        self.chromaSoftness = min(max(chromaSoftness, 0), 1)
        self.gestureGo = gestureGo
        self.goGesture = goGesture
        self.gestureHoldSeconds = min(max(gestureHoldSeconds, 0.25), 5)
    }

    public var anyEnabled: Bool { segmentation || magicDust || chromaKey || gestureGo }

    private enum CodingKeys: String, CodingKey {
        case segmentation, magicDust, dustEmitter, dustPreset, dustScale
        case chromaKey, chromaKeyColor, chromaTolerance, chromaSoftness, gestureGo, goGesture
        case gestureHoldSeconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        segmentation = try c.decodeIfPresent(Bool.self, forKey: .segmentation) ?? false
        magicDust = try c.decodeIfPresent(Bool.self, forKey: .magicDust) ?? false
        dustEmitter = try c.decodeIfPresent(MediaReference.self, forKey: .dustEmitter)
        dustPreset = try c.decodeIfPresent(String.self, forKey: .dustPreset)
        dustScale = min(max(try c.decodeIfPresent(Double.self, forKey: .dustScale) ?? 1, 0.5), 10)
        // Pre-D10 files predate chroma key; default off, pure green, 0.35/0.1.
        chromaKey = try c.decodeIfPresent(Bool.self, forKey: .chromaKey) ?? false
        chromaKeyColor = try c.decodeIfPresent(RGBAColor.self, forKey: .chromaKeyColor)
            ?? RGBAColor(red: 0, green: 1, blue: 0)
        chromaTolerance = min(max(try c.decodeIfPresent(Double.self, forKey: .chromaTolerance) ?? 0.35, 0), 1)
        chromaSoftness = min(max(try c.decodeIfPresent(Double.self, forKey: .chromaSoftness) ?? 0.1, 0), 1)
        // Pre-D11 files predate gesture GO; default off.
        gestureGo = try c.decodeIfPresent(Bool.self, forKey: .gestureGo) ?? false
        // Pre-D15 files predate the gesture picker; D11 only ever recognized
        // an open palm, so that's the default for every older file too.
        goGesture = try c.decodeIfPresent(HandGesture.self, forKey: .goGesture) ?? .openPalm
        // Pre-D25 files predate the selectable warm-up time; default to the
        // fixed 1 s every one of them actually used.
        gestureHoldSeconds = min(max(try c.decodeIfPresent(Double.self, forKey: .gestureHoldSeconds) ?? 1.0, 0.25), 5)
    }
}

/// Live camera input shown fullscreen on a display. Video-only — sound stays
/// with audio cues. Indefinite: runs until explicitly stopped.
public struct CameraBody: Codable, Hashable, Sendable {
    /// AVCaptureDevice.uniqueID; nil = first available camera.
    public var cameraUID: String?
    /// Human-readable name for the UI when the UID doesn't resolve.
    public var cameraName: String?
    /// Legacy direct display assignment (pre-v3); superseded by outputGroupID.
    public var display: DisplayFingerprint?
    /// Virtual output the camera shows on; nil = operator's main display.
    public var outputGroupID: UUID?
    public var fillMode: FillMode
    public var geometry: VideoGeometry
    public var fadeInDuration: TimeInterval
    public var fadeOutDuration: TimeInterval
    /// Render order on the output, 1 (background) … 10 (front).
    public var layer: Int
    /// Live effects (segmentation, magic dust) — all off by default.
    public var effects: CameraEffects
    /// D25: the camera runs purely as a hand-gesture sensor — it draws to
    /// NO output at all (no window/preview/content layers, no output group
    /// needed). This carves the one deliberate exception into the pinned
    /// "video/camera/image/slide cues REQUIRE an output group" rule — see
    /// `EnginePlayerProvider.resolveTargets` and `CameraCuePlayer`. Lives on
    /// the BODY (not `effects`) because it changes OUTPUT semantics, not
    /// frame processing.
    public var sensorOnly: Bool

    public init(
        cameraUID: String? = nil,
        cameraName: String? = nil,
        display: DisplayFingerprint? = nil,
        outputGroupID: UUID? = nil,
        fillMode: FillMode = .fit,
        geometry: VideoGeometry = .fillStage,
        fadeInDuration: TimeInterval = 0,
        fadeOutDuration: TimeInterval = 0,
        layer: Int = 5,
        effects: CameraEffects = CameraEffects(),
        sensorOnly: Bool = false
    ) {
        self.cameraUID = cameraUID
        self.cameraName = cameraName
        self.display = display
        self.outputGroupID = outputGroupID
        self.fillMode = fillMode
        self.geometry = geometry
        self.fadeInDuration = fadeInDuration
        self.fadeOutDuration = fadeOutDuration
        self.layer = layer.clampedToLayerRange
        self.effects = effects
        self.sensorOnly = sensorOnly
    }

    private enum CodingKeys: String, CodingKey {
        case cameraUID, cameraName, display, outputGroupID, fillMode, geometry
        case fadeInDuration, fadeOutDuration, layer, effects, sensorOnly
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cameraUID = try c.decodeIfPresent(String.self, forKey: .cameraUID)
        cameraName = try c.decodeIfPresent(String.self, forKey: .cameraName)
        display = try c.decodeIfPresent(DisplayFingerprint.self, forKey: .display)
        outputGroupID = try c.decodeIfPresent(UUID.self, forKey: .outputGroupID)
        fillMode = try c.decode(FillMode.self, forKey: .fillMode)
        geometry = try c.decodeIfPresent(VideoGeometry.self, forKey: .geometry) ?? .fillStage
        fadeInDuration = try c.decode(TimeInterval.self, forKey: .fadeInDuration)
        fadeOutDuration = try c.decode(TimeInterval.self, forKey: .fadeOutDuration)
        layer = (try c.decodeIfPresent(Int.self, forKey: .layer) ?? 5).clampedToLayerRange
        effects = try c.decodeIfPresent(CameraEffects.self, forKey: .effects) ?? CameraEffects()
        // Pre-D25 files predate sensor-only mode; default off (draws as before).
        sensorOnly = try c.decodeIfPresent(Bool.self, forKey: .sensorOnly) ?? false
    }
}

/// A standalone still image (PNG/JPEG/HEIC…) on stage outputs. Indefinite
/// like a camera cue: holds until stopped. Video-only; fades ride layer
/// opacity. Unlike slides, images never replace each other — they layer,
/// exactly like video cues.
public struct ImageBody: Codable, Hashable, Sendable {
    public var media: MediaReference
    /// Virtual output; nil = unassigned (won't play), like video.
    public var outputGroupID: UUID?
    public var fillMode: FillMode
    public var geometry: VideoGeometry
    public var fadeInDuration: TimeInterval
    public var fadeOutDuration: TimeInterval
    /// Render order on the output, 1 (background) … 10 (front).
    public var layer: Int

    public init(
        media: MediaReference,
        outputGroupID: UUID? = nil,
        fillMode: FillMode = .fit,
        geometry: VideoGeometry = .fillStage,
        fadeInDuration: TimeInterval = 0,
        fadeOutDuration: TimeInterval = 0,
        layer: Int = 5
    ) {
        self.media = media
        self.outputGroupID = outputGroupID
        self.fillMode = fillMode
        self.geometry = geometry
        self.fadeInDuration = fadeInDuration
        self.fadeOutDuration = fadeOutDuration
        self.layer = layer.clampedToLayerRange
    }

    private enum CodingKeys: String, CodingKey {
        case media, outputGroupID, fillMode, geometry, fadeInDuration, fadeOutDuration, layer
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        media = try c.decode(MediaReference.self, forKey: .media)
        outputGroupID = try c.decodeIfPresent(UUID.self, forKey: .outputGroupID)
        fillMode = try c.decode(FillMode.self, forKey: .fillMode)
        geometry = try c.decodeIfPresent(VideoGeometry.self, forKey: .geometry) ?? .fillStage
        fadeInDuration = try c.decode(TimeInterval.self, forKey: .fadeInDuration)
        fadeOutDuration = try c.decode(TimeInterval.self, forKey: .fadeOutDuration)
        layer = (try c.decodeIfPresent(Int.self, forKey: .layer) ?? 5).clampedToLayerRange
    }
}

/// Model-level RGBA color (0…1 components) — ShowModel stays AppKit-free.
public struct RGBAColor: Codable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

/// A rectangle in normalized stage coordinates (0…1 fractions of the
/// stage, origin bottom-left — same space as layer coordinates).
public struct StageRect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Reproduces the pre-box text layout: full height, 4% side margins.
    public static let textDefault = StageRect(x: 0.04, y: 0, width: 0.92, height: 1)
}

/// Rich text on stage outputs — titles, lower thirds, prompter notes.
/// Content is RTF (pasted formatting survives); rendered to a bitmap at the
/// stage's size at arm/edit time. Indefinite: holds until stopped.
public struct TextBody: Codable, Hashable, Sendable {
    /// The rich text, as RTF data (NSAttributedString round-trip).
    public var rtf: Data
    /// First line of the plain text, maintained by the editor — used for the
    /// cue's default name without needing AppKit in the model layer.
    public var plainPreview: String
    /// nil = transparent (layers behind show through).
    public var backgroundColor: RGBAColor?
    /// Virtual output; nil = unassigned (won't play), like video.
    public var outputGroupID: UUID?
    public var geometry: VideoGeometry
    public var fadeInDuration: TimeInterval
    public var fadeOutDuration: TimeInterval
    /// Render order on the output, 1 (background) … 10 (front).
    public var layer: Int
    /// Where the text block lives on the 16:9 stage (normalized).
    public var box: StageRect

    public init(
        rtf: Data,
        plainPreview: String = "Text",
        backgroundColor: RGBAColor? = nil,
        outputGroupID: UUID? = nil,
        geometry: VideoGeometry = .fillStage,
        fadeInDuration: TimeInterval = 0,
        fadeOutDuration: TimeInterval = 0,
        layer: Int = 5,
        box: StageRect = .textDefault
    ) {
        self.rtf = rtf
        self.plainPreview = plainPreview
        self.backgroundColor = backgroundColor
        self.outputGroupID = outputGroupID
        self.geometry = geometry
        self.fadeInDuration = fadeInDuration
        self.fadeOutDuration = fadeOutDuration
        self.layer = layer.clampedToLayerRange
        self.box = box
    }

    private enum CodingKeys: String, CodingKey {
        case rtf, plainPreview, backgroundColor, outputGroupID, geometry
        case fadeInDuration, fadeOutDuration, layer, box
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rtf = try c.decode(Data.self, forKey: .rtf)
        plainPreview = try c.decodeIfPresent(String.self, forKey: .plainPreview) ?? "Text"
        backgroundColor = try c.decodeIfPresent(RGBAColor.self, forKey: .backgroundColor)
        outputGroupID = try c.decodeIfPresent(UUID.self, forKey: .outputGroupID)
        geometry = try c.decodeIfPresent(VideoGeometry.self, forKey: .geometry) ?? .fillStage
        fadeInDuration = try c.decode(TimeInterval.self, forKey: .fadeInDuration)
        fadeOutDuration = try c.decode(TimeInterval.self, forKey: .fadeOutDuration)
        layer = (try c.decodeIfPresent(Int.self, forKey: .layer) ?? 5).clampedToLayerRange
        box = try c.decodeIfPresent(StageRect.self, forKey: .box) ?? .textDefault
    }
}

/// One slide of an imported deck, rendered to a still image at import time
/// (PowerPoint/PDF decks are flattened — the research showed no live path
/// survives a stage). Indefinite like a camera cue: holds until stopped.
/// Starting the next slide on the same output replaces this one (crossfade).
public struct SlideBody: Codable, Hashable, Sendable {
    /// The rendered slide image (PNG in the slide cache).
    public var media: MediaReference
    /// The original deck (.pptx/.pdf) for reconversion.
    public var sourceDeck: MediaReference?
    /// 1-based position within the deck, for display.
    public var slideIndex: Int?
    public var slideCount: Int?
    /// Virtual output; nil = unassigned (won't play), like video.
    public var outputGroupID: UUID?
    public var fillMode: FillMode
    public var geometry: VideoGeometry
    public var fadeInDuration: TimeInterval
    public var fadeOutDuration: TimeInterval
    /// Starting this slide fades out other running slides on the same output.
    public var replacesPreviousSlide: Bool
    /// Render order on the output, 1 (background) … 10 (front).
    public var layer: Int

    public init(
        media: MediaReference,
        sourceDeck: MediaReference? = nil,
        slideIndex: Int? = nil,
        slideCount: Int? = nil,
        outputGroupID: UUID? = nil,
        fillMode: FillMode = .fit,
        geometry: VideoGeometry = .fillStage,
        fadeInDuration: TimeInterval = 0.15,
        fadeOutDuration: TimeInterval = 0,
        replacesPreviousSlide: Bool = true,
        layer: Int = 5
    ) {
        self.media = media
        self.sourceDeck = sourceDeck
        self.slideIndex = slideIndex
        self.slideCount = slideCount
        self.outputGroupID = outputGroupID
        self.fillMode = fillMode
        self.geometry = geometry
        self.fadeInDuration = fadeInDuration
        self.fadeOutDuration = fadeOutDuration
        self.replacesPreviousSlide = replacesPreviousSlide
        self.layer = layer.clampedToLayerRange
    }

    /// Deck display name derived from the source (or the image as fallback).
    public var deckName: String {
        let name = (sourceDeck ?? media).fileName
        return (name as NSString).deletingPathExtension
    }

    private enum CodingKeys: String, CodingKey {
        case media, sourceDeck, slideIndex, slideCount, outputGroupID
        case fillMode, geometry, fadeInDuration, fadeOutDuration, replacesPreviousSlide, layer
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        media = try c.decode(MediaReference.self, forKey: .media)
        sourceDeck = try c.decodeIfPresent(MediaReference.self, forKey: .sourceDeck)
        slideIndex = try c.decodeIfPresent(Int.self, forKey: .slideIndex)
        slideCount = try c.decodeIfPresent(Int.self, forKey: .slideCount)
        outputGroupID = try c.decodeIfPresent(UUID.self, forKey: .outputGroupID)
        fillMode = try c.decode(FillMode.self, forKey: .fillMode)
        geometry = try c.decodeIfPresent(VideoGeometry.self, forKey: .geometry) ?? .fillStage
        fadeInDuration = try c.decode(TimeInterval.self, forKey: .fadeInDuration)
        fadeOutDuration = try c.decode(TimeInterval.self, forKey: .fadeOutDuration)
        replacesPreviousSlide = try c.decodeIfPresent(Bool.self, forKey: .replacesPreviousSlide) ?? true
        layer = (try c.decodeIfPresent(Int.self, forKey: .layer) ?? 5).clampedToLayerRange
    }
}

// MARK: - Control cues

public struct FadeBody: Codable, Hashable, Sendable {
    /// Resolved against running instances at fire time; not running → no-op.
    public var targetID: UUID?
    public var duration: TimeInterval
    public var curve: FadeCurve
    /// Absolute target level for audio (or a video cue's embedded audio).
    public var toVolumeDB: Double?
    /// 0…1, video targets only.
    public var toOpacity: Double?
    public var stopTargetWhenDone: Bool

    public init(
        targetID: UUID? = nil,
        duration: TimeInterval = 3,
        curve: FadeCurve = .dbLinear,
        toVolumeDB: Double? = silenceFloorDB,
        toOpacity: Double? = nil,
        stopTargetWhenDone: Bool = true
    ) {
        self.targetID = targetID
        self.duration = duration
        self.curve = curve
        self.toVolumeDB = toVolumeDB
        self.toOpacity = toOpacity
        self.stopTargetWhenDone = stopTargetWhenDone
    }
}

public struct StopBody: Codable, Hashable, Sendable {
    /// nil = stop ALL playing cues (bulk selector).
    public var targetID: UUID?
    /// 0 = hard stop; >0 = fade to silence over this time, then stop.
    public var fadeOutTime: TimeInterval
    public var curve: FadeCurve

    public init(
        targetID: UUID? = nil,
        fadeOutTime: TimeInterval = 0,
        curve: FadeCurve = .dbLinear
    ) {
        self.targetID = targetID
        self.fadeOutTime = fadeOutTime
        self.curve = curve
    }
}

/// D29: one typed OSC 1.0 argument, as authored on an `OSCSendBody`.
/// Model-pure — ShowModel stays AppKit/Network-free, so this is NOT the same
/// type as the app layer's wire-level `OSCArgument`; the app converts one to
/// the other at fire time (int32→.int32, float→.float32(Float), string→.string).
public enum OSCSendArgument: Hashable, Sendable {
    case int32(Int32)
    case float(Double)
    case string(String)
}

extension OSCSendArgument: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, value
    }

    private enum Kind: String, Codable {
        case int32, float, string
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .int32:
            self = .int32(try container.decode(Int32.self, forKey: .value))
        case .float:
            self = .float(try container.decode(Double.self, forKey: .value))
        case .string:
            self = .string(try container.decode(String.self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .int32(let value):
            try container.encode(Kind.int32, forKey: .type)
            try container.encode(value, forKey: .value)
        case .float(let value):
            try container.encode(Kind.float, forKey: .type)
            try container.encode(value, forKey: .value)
        case .string(let value):
            try container.encode(Kind.string, forKey: .type)
            try container.encode(value, forKey: .value)
        }
    }
}

/// D29: the first OUTBOUND cue type. GO fires exactly one OSC 1.0 message at
/// `host:port` — instant, fire-and-forget, same "never blocks GO" contract as
/// Stop/Fade (see ShowRuntime.CueInstance.runOSCSendAction). `host` empty is
/// "unconfigured" — a warned no-op, mirroring a fade cue with no target.
public struct OSCSendBody: Codable, Hashable, Sendable {
    /// Destination hostname or IP; "" = unconfigured (warned no-op at fire).
    public var host: String
    public var port: UInt16
    /// OSC address pattern; UI normalizes to a leading "/" on commit.
    public var address: String
    public var arguments: [OSCSendArgument]

    public init(
        host: String = "",
        port: UInt16 = 8000,
        address: String = "/",
        arguments: [OSCSendArgument] = []
    ) {
        self.host = host
        self.port = OSCSendBody.clampedPort(port)
        self.address = address
        self.arguments = arguments
    }

    private enum CodingKeys: String, CodingKey {
        case host, port, address, arguments
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = OSCSendBody.clampedPort(try c.decodeIfPresent(UInt16.self, forKey: .port) ?? 8000)
        address = try c.decodeIfPresent(String.self, forKey: .address) ?? "/"
        arguments = try c.decodeIfPresent([OSCSendArgument].self, forKey: .arguments) ?? []
    }

    /// UInt16 already excludes negative/overflow, but 0 is not a usable port —
    /// falls back to the default like any other out-of-range authored/decoded value.
    private static func clampedPort(_ raw: UInt16) -> UInt16 {
        raw == 0 ? 8000 : raw
    }
}

// MARK: - Groups

public enum GroupMode: String, Codable, Hashable, Sendable, CaseIterable {
    /// All children start together the moment the group fires.
    case fireAll
    /// Children start at per-child offsets from group start.
    case timeline
    /// GO on the group plays the FIRST child and moves the playhead inside;
    /// each further GO advances to the next child (slide-deck navigation).
    case enterAndPlayFirst
}

/// Children are the cues whose `parentID` is this group cue's id, in document
/// order. Fire-all and timeline share one code path: schedule each armed child
/// at its offset (fire-all = all offsets zero).
public struct GroupBody: Codable, Hashable, Sendable {
    public var mode: GroupMode
    /// Timeline offsets keyed by child cue id; missing key = 0.
    public var childOffsets: [UUID: TimeInterval]
    /// List-UI collapse state; persisted with the show file.
    public var collapsed: Bool

    public init(mode: GroupMode = .fireAll, childOffsets: [UUID: TimeInterval] = [:], collapsed: Bool = false) {
        self.mode = mode
        self.childOffsets = childOffsets
        self.collapsed = collapsed
    }

    private enum CodingKeys: String, CodingKey {
        case mode, childOffsets, collapsed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decode(GroupMode.self, forKey: .mode)
        childOffsets = try container.decodeIfPresent([UUID: TimeInterval].self, forKey: .childOffsets) ?? [:]
        collapsed = try container.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
    }

    public func offset(for childID: UUID) -> TimeInterval {
        guard mode == .timeline else { return 0 }
        return childOffsets[childID] ?? 0
    }
}
