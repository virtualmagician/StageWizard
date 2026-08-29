import Foundation

/// A named point in a media cue's file-time axis (same axis as
/// AudioBody/VideoBody startTime/endTime trim). Purely descriptive — the only
/// runtime behavior it drives today is `FollowAction.autoContinueAtMarker`.
public struct CueMarker: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// Seconds from file start (media/file time, not wall clock).
    public var time: TimeInterval
    public var name: String

    public init(id: UUID = UUID(), time: TimeInterval, name: String) {
        self.id = id
        self.time = time
        self.name = name
    }
}

/// What happens to the *next* cue when this one runs.
/// Orthogonal to media end behavior: auto-continue is anchored to this cue's
/// START (+ postWait); auto-follow fires when this cue's action COMPLETES.
public enum FollowAction: Hashable, Sendable {
    case none
    case autoContinue(postWait: TimeInterval)
    /// Like autoContinue, but anchored to a marker in the SOURCE cue's media
    /// (audio/video only) instead of a fixed post-wait. A marker id that no
    /// longer resolves (deleted) is treated as no follow at all — see
    /// TransportController.fire.
    case autoContinueAtMarker(markerID: UUID)
    case autoFollow

    public var isAutoContinueAtMarker: Bool {
        if case .autoContinueAtMarker = self { return true }
        return false
    }
}

extension FollowAction: Codable {
    private enum CodingKeys: String, CodingKey {
        case mode
        case postWait
        case markerID
    }

    private enum Mode: String, Codable {
        case none, autoContinue, autoContinueAtMarker, autoFollow
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Mode.self, forKey: .mode) {
        case .none:
            self = .none
        case .autoContinue:
            let postWait = try container.decodeIfPresent(TimeInterval.self, forKey: .postWait) ?? 0
            self = .autoContinue(postWait: postWait)
        case .autoContinueAtMarker:
            let markerID = try container.decode(UUID.self, forKey: .markerID)
            self = .autoContinueAtMarker(markerID: markerID)
        case .autoFollow:
            self = .autoFollow
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try container.encode(Mode.none, forKey: .mode)
        case .autoContinue(let postWait):
            try container.encode(Mode.autoContinue, forKey: .mode)
            try container.encode(postWait, forKey: .postWait)
        case .autoContinueAtMarker(let markerID):
            try container.encode(Mode.autoContinueAtMarker, forKey: .mode)
            try container.encode(markerID, forKey: .markerID)
        case .autoFollow:
            try container.encode(Mode.autoFollow, forKey: .mode)
        }
    }
}

/// A cue definition as stored in the show file. Runtime playback state never
/// lives here — see ShowRuntime.CueInstance.
public struct Cue: Codable, Identifiable, Hashable, Sendable {
    /// Stable identity. Fade/Stop cues and groups reference this, never `number`.
    public var id: UUID
    /// Operator-facing cue number; free text, renumberable without breaking targets.
    public var number: String
    /// nil → UI shows a type-derived default (e.g. the media file name).
    public var name: String?
    public var notes: String
    public var colorTag: String?
    /// Disarmed cues honor waits/follows but skip their action.
    public var armed: Bool
    public var preWait: TimeInterval
    public var follow: FollowAction
    /// nil = top level; otherwise the id of the containing group cue.
    public var parentID: UUID?
    public var hotkey: KeyBinding?
    /// Seconds since local midnight (0..<86400); nil = no wall-clock trigger.
    /// See TransportController's 1 Hz wall-clock scheduler.
    public var wallClock: TimeInterval?
    public var body: CueBody

    public init(
        id: UUID = UUID(),
        number: String = "",
        name: String? = nil,
        notes: String = "",
        colorTag: String? = nil,
        armed: Bool = true,
        preWait: TimeInterval = 0,
        follow: FollowAction = .none,
        parentID: UUID? = nil,
        hotkey: KeyBinding? = nil,
        wallClock: TimeInterval? = nil,
        body: CueBody
    ) {
        self.id = id
        self.number = number
        self.name = name
        self.notes = notes
        self.colorTag = colorTag
        self.armed = armed
        self.preWait = preWait
        self.follow = follow
        self.parentID = parentID
        self.hotkey = hotkey
        self.wallClock = Cue.normalizedWallClock(wallClock)
        self.body = body
    }

    /// Name shown in lists: explicit name, else a type-derived default.
    public var displayName: String {
        if let name, !name.isEmpty { return name }
        return body.defaultName
    }

    private enum CodingKeys: String, CodingKey {
        case id, number, name, notes, colorTag, armed, preWait, follow, parentID, hotkey, wallClock, body
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        number = try c.decode(String.self, forKey: .number)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        notes = try c.decode(String.self, forKey: .notes)
        colorTag = try c.decodeIfPresent(String.self, forKey: .colorTag)
        armed = try c.decode(Bool.self, forKey: .armed)
        preWait = try c.decode(TimeInterval.self, forKey: .preWait)
        follow = try c.decode(FollowAction.self, forKey: .follow)
        parentID = try c.decodeIfPresent(UUID.self, forKey: .parentID)
        hotkey = try c.decodeIfPresent(KeyBinding.self, forKey: .hotkey)
        // Pre-D5 files predate wall-clock triggers.
        wallClock = Cue.normalizedWallClock(try c.decodeIfPresent(TimeInterval.self, forKey: .wallClock))
        body = try c.decode(CueBody.self, forKey: .body)
    }

    /// Wraps (not rejects) an out-of-range time into 0..<86400 seconds —
    /// same "be liberal in what you accept" spirit as the render-layer clamp.
    private static func normalizedWallClock(_ raw: TimeInterval?) -> TimeInterval? {
        guard let raw else { return nil }
        let day: TimeInterval = 86400
        let wrapped = raw.truncatingRemainder(dividingBy: day)
        return wrapped < 0 ? wrapped + day : wrapped
    }
}
