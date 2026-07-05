import Foundation

/// Workspace mode, persisted with the show. Show and Rehearsal
/// both lock editing; Rehearsal additionally routes video/camera output into
/// floating preview windows instead of the real displays.
public enum WorkspaceMode: String, Codable, Hashable, Sendable {
    case edit, show, rehearsal
}

/// Show-wide settings persisted in the show file.
public struct ShowSettings: Codable, Hashable, Sendable {
    /// Soft-panic fade length; second panic inside this window = hard stop.
    public var panicDuration: TimeInterval
    /// 0 = off. GO presses within this window after a GO are ignored.
    public var doubleGOProtection: TimeInterval
    /// How many upcoming cues to keep armed (prerolled) ahead of the playhead.
    public var armAheadCount: Int
    /// Assignable transport shortcuts (panic/Esc is hardcoded, never here).
    public var keyBindings: [ShortcutAction: KeyBinding]
    /// Virtual video outputs; cues reference these by id.
    public var outputGroups: [OutputGroup]
    /// Last saved workspace mode — restored on open.
    public var workspaceMode: WorkspaceMode

    public init(
        panicDuration: TimeInterval = 3,
        doubleGOProtection: TimeInterval = 0,
        armAheadCount: Int = 3,
        keyBindings: [ShortcutAction: KeyBinding] = ShowSettings.defaultBindings,
        outputGroups: [OutputGroup] = [],
        workspaceMode: WorkspaceMode = .edit
    ) {
        self.panicDuration = panicDuration
        self.doubleGOProtection = doubleGOProtection
        self.armAheadCount = armAheadCount
        self.keyBindings = keyBindings
        self.outputGroups = outputGroups
        self.workspaceMode = workspaceMode
    }

    private enum CodingKeys: String, CodingKey {
        case panicDuration, doubleGOProtection, armAheadCount, keyBindings, outputGroups, workspaceMode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        panicDuration = try container.decode(TimeInterval.self, forKey: .panicDuration)
        doubleGOProtection = try container.decode(TimeInterval.self, forKey: .doubleGOProtection)
        armAheadCount = try container.decode(Int.self, forKey: .armAheadCount)
        keyBindings = try container.decode([ShortcutAction: KeyBinding].self, forKey: .keyBindings)
        // v1/v2 files predate output groups.
        outputGroups = try container.decodeIfPresent([OutputGroup].self, forKey: .outputGroups) ?? []
        workspaceMode = try container.decodeIfPresent(WorkspaceMode.self, forKey: .workspaceMode) ?? .edit
    }

    public func group(withID id: UUID) -> OutputGroup? {
        outputGroups.first { $0.id == id }
    }

    /// Space = GO. Other transport actions ship unbound; the operator assigns them.
    public static let defaultBindings: [ShortcutAction: KeyBinding] = [
        .go: KeyBinding(keyCode: 49),           // Space
        .previousCue: KeyBinding(keyCode: 126), // Up arrow
        .nextCue: KeyBinding(keyCode: 125),     // Down arrow
    ]
}

/// Root of the persisted show document.
public struct ShowFile: Codable, Hashable, Sendable {
    /// 2: video/camera cues target OutputGroups instead of raw displays.
    /// 3: GroupMode.enterAndPlayFirst (older apps can't decode the new mode,
    ///    so they must refuse v3 files cleanly instead of failing mid-parse).
    public static let currentFormatVersion = 3

    public var formatVersion: Int
    public var settings: ShowSettings
    /// FLAT list in document order; group nesting via `Cue.parentID`.
    public var cues: [Cue]

    public init(
        formatVersion: Int = ShowFile.currentFormatVersion,
        settings: ShowSettings = ShowSettings(),
        cues: [Cue] = []
    ) {
        self.formatVersion = formatVersion
        self.settings = settings
        self.cues = cues
    }
}

// MARK: - Persistence

public enum ShowFileError: LocalizedError {
    case newerFormat(Int)

    public var errorDescription: String? {
        switch self {
        case .newerFormat(let version):
            return "This show was saved by a newer version of StageWizard (format \(version)). Update the app to open it."
        }
    }
}

extension ShowFile {
    /// Decode with format-version migration. Old formats are upgraded here;
    /// newer-than-us formats refuse loudly rather than corrupting on resave.
    public static func load(from data: Data) throws -> ShowFile {
        struct VersionProbe: Codable { var formatVersion: Int }
        let decoder = JSONDecoder()
        let version = (try? decoder.decode(VersionProbe.self, from: data))?.formatVersion ?? 1
        guard version <= currentFormatVersion else {
            throw ShowFileError.newerFormat(version)
        }
        var show = try decoder.decode(ShowFile.self, from: data)
        if version < 2 {
            show.migrateDisplaysToOutputGroups()
        }
        show.formatVersion = currentFormatVersion
        return show
    }

    /// v1 → v2: every direct display assignment becomes a same-named output
    /// group (deduplicated by fingerprint) so old shows keep working and are
    /// immediately reconfigurable from the settings panel.
    private mutating func migrateDisplaysToOutputGroups() {
        func groupID(for fingerprint: DisplayFingerprint) -> UUID {
            if let existing = settings.outputGroups.first(where: { $0.displays == [fingerprint] }) {
                return existing.id
            }
            let group = OutputGroup(name: fingerprint.name, displays: [fingerprint])
            settings.outputGroups.append(group)
            return group.id
        }
        for index in cues.indices {
            switch cues[index].body {
            case .video(var body):
                if let display = body.display, body.outputGroupID == nil {
                    body.outputGroupID = groupID(for: display)
                    cues[index].body = .video(body)
                }
            case .camera(var body):
                if let display = body.display, body.outputGroupID == nil {
                    body.outputGroupID = groupID(for: display)
                    cues[index].body = .camera(body)
                }
            default:
                break
            }
        }
    }

    /// Pretty-printed, sorted keys — show files stay git-diff-friendly.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

// MARK: - Structure queries (flat list + parentID)

extension ShowFile {
    /// Direct children of a group, in document order.
    public func children(of groupID: UUID) -> [Cue] {
        cues.filter { $0.parentID == groupID }
    }

    /// Top-level cues in document order.
    public var topLevelCues: [Cue] {
        cues.filter { $0.parentID == nil }
    }

    public func cue(withID id: UUID) -> Cue? {
        cues.first { $0.id == id }
    }

    public func indexOfCue(withID id: UUID) -> Int? {
        cues.firstIndex { $0.id == id }
    }

    /// The next number for a newly appended cue: max numeric cue number + 1.
    public func nextCueNumber() -> String {
        let maxNumber = cues.compactMap { Double($0.number) }.max() ?? 0
        return String(format: "%g", floor(maxNumber) + 1)
    }
}
