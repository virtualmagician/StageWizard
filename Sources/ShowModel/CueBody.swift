import Foundation

/// Type-specific payload of a cue. Encoded flat with a `"type"` discriminator
/// so show files stay diff-friendly and forward-migratable. Unknown types
/// decode to `.broken` instead of failing the whole file.
public enum CueBody: Hashable, Sendable {
    case audio(AudioBody)
    case video(VideoBody)
    case camera(CameraBody)
    case image(ImageBody)
    case slide(SlideBody)
    case fade(FadeBody)
    case stop(StopBody)
    case group(GroupBody)
    case broken(BrokenBody)

    public var defaultName: String {
        switch self {
        case .audio(let body): return body.media.fileName
        case .video(let body): return body.media.fileName
        case .camera(let body): return body.cameraName ?? "Camera"
        case .image(let body): return body.media.fileName
        case .slide(let body):
            if let index = body.slideIndex, let count = body.slideCount {
                return "\(body.deckName) · \(index)/\(count)"
            }
            return body.media.fileName
        case .fade: return "Fade"
        case .stop: return "Stop"
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
        case .slide: return "Slide"
        case .fade: return "Fade"
        case .stop: return "Stop"
        case .group: return "Group"
        case .broken: return "Broken"
        }
    }
}

extension CueBody: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
    }

    private enum Kind: String, Codable {
        case audio, video, camera, image, slide, fade, stop, group
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawType = try container.decode(String.self, forKey: .type)
        switch Kind(rawValue: rawType) {
        case .audio: self = .audio(try AudioBody(from: decoder))
        case .video: self = .video(try VideoBody(from: decoder))
        case .camera: self = .camera(try CameraBody(from: decoder))
        case .image: self = .image(try ImageBody(from: decoder))
        case .slide: self = .slide(try SlideBody(from: decoder))
        case .fade: self = .fade(try FadeBody(from: decoder))
        case .stop: self = .stop(try StopBody(from: decoder))
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
        case .slide(let body):
            try container.encode(Kind.slide, forKey: .type)
            try body.encode(to: encoder)
        case .fade(let body):
            try container.encode(Kind.fade, forKey: .type)
            try body.encode(to: encoder)
        case .stop(let body):
            try container.encode(Kind.stop, forKey: .type)
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
        outputDeviceName: String? = nil
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
        fadeOutDuration: TimeInterval = 0
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
    }

    private enum CodingKeys: String, CodingKey {
        case media, startTime, endTime, playCount, infiniteLoop, volumeDB
        case audioDeviceUID, audioDeviceName, display, outputGroupID
        case fillMode, geometry, endBehavior, fadeInDuration, fadeOutDuration
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

    public init(
        cameraUID: String? = nil,
        cameraName: String? = nil,
        display: DisplayFingerprint? = nil,
        outputGroupID: UUID? = nil,
        fillMode: FillMode = .fit,
        geometry: VideoGeometry = .fillStage,
        fadeInDuration: TimeInterval = 0,
        fadeOutDuration: TimeInterval = 0
    ) {
        self.cameraUID = cameraUID
        self.cameraName = cameraName
        self.display = display
        self.outputGroupID = outputGroupID
        self.fillMode = fillMode
        self.geometry = geometry
        self.fadeInDuration = fadeInDuration
        self.fadeOutDuration = fadeOutDuration
    }

    private enum CodingKeys: String, CodingKey {
        case cameraUID, cameraName, display, outputGroupID, fillMode, geometry
        case fadeInDuration, fadeOutDuration
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

    public init(
        media: MediaReference,
        outputGroupID: UUID? = nil,
        fillMode: FillMode = .fit,
        geometry: VideoGeometry = .fillStage,
        fadeInDuration: TimeInterval = 0,
        fadeOutDuration: TimeInterval = 0
    ) {
        self.media = media
        self.outputGroupID = outputGroupID
        self.fillMode = fillMode
        self.geometry = geometry
        self.fadeInDuration = fadeInDuration
        self.fadeOutDuration = fadeOutDuration
    }

    private enum CodingKeys: String, CodingKey {
        case media, outputGroupID, fillMode, geometry, fadeInDuration, fadeOutDuration
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        media = try c.decode(MediaReference.self, forKey: .media)
        outputGroupID = try c.decodeIfPresent(UUID.self, forKey: .outputGroupID)
        fillMode = try c.decode(FillMode.self, forKey: .fillMode)
        geometry = try c.decodeIfPresent(VideoGeometry.self, forKey: .geometry) ?? .fillStage
        fadeInDuration = try c.decode(TimeInterval.self, forKey: .fadeInDuration)
        fadeOutDuration = try c.decode(TimeInterval.self, forKey: .fadeOutDuration)
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
        replacesPreviousSlide: Bool = true
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
    }

    /// Deck display name derived from the source (or the image as fallback).
    public var deckName: String {
        let name = (sourceDeck ?? media).fileName
        return (name as NSString).deletingPathExtension
    }

    private enum CodingKeys: String, CodingKey {
        case media, sourceDeck, slideIndex, slideCount, outputGroupID
        case fillMode, geometry, fadeInDuration, fadeOutDuration, replacesPreviousSlide
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
