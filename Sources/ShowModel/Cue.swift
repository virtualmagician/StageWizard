import Foundation

/// What happens to the *next* cue when this one runs.
/// Orthogonal to media end behavior: auto-continue is anchored to this cue's
/// START (+ postWait); auto-follow fires when this cue's action COMPLETES.
public enum FollowAction: Hashable, Sendable {
    case none
    case autoContinue(postWait: TimeInterval)
    case autoFollow
}

extension FollowAction: Codable {
    private enum CodingKeys: String, CodingKey {
        case mode
        case postWait
    }

    private enum Mode: String, Codable {
        case none, autoContinue, autoFollow
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Mode.self, forKey: .mode) {
        case .none:
            self = .none
        case .autoContinue:
            let postWait = try container.decodeIfPresent(TimeInterval.self, forKey: .postWait) ?? 0
            self = .autoContinue(postWait: postWait)
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
        self.body = body
    }

    /// Name shown in lists: explicit name, else a type-derived default.
    public var displayName: String {
        if let name, !name.isEmpty { return name }
        return body.defaultName
    }
}
