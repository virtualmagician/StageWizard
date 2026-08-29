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
    /// Whether the virtual-webcam feed should run for this show —
    /// restored on open (when the camera extension is active).
    public var virtualCameraFeed: Bool
    /// Whether the CoreMIDI listener should run for this show. Active in
    /// every workspace mode while true (same as hotkeys).
    public var midiEnabled: Bool
    /// MIDI-Learn assignments: a MIDI trigger mapped to a transport action.
    public var midiBindings: [MIDIBindingEntry]
    /// Whether the OSC UDP listener should run for this show. Active in
    /// every workspace mode while true (same as MIDI/hotkeys).
    public var oscEnabled: Bool
    /// UDP port the OSC listener binds to.
    public var oscPort: UInt16
    /// Whether the web remote (phone-friendly GO page) HTTP server should
    /// run for this show. Active in every workspace mode while true (same
    /// as MIDI/OSC/hotkeys).
    public var webRemoteEnabled: Bool
    /// TCP port the web remote HTTP server binds to.
    public var webRemotePort: UInt16
    /// A fullscreen performer-facing confidence monitor on a chosen display —
    /// clock, show timer, standing-by cue, notes, running cues. Reads
    /// transport state only; NEVER a cue target.
    public var stageDisplay: StageDisplaySettings

    public init(
        panicDuration: TimeInterval = 3,
        doubleGOProtection: TimeInterval = 0,
        armAheadCount: Int = 3,
        keyBindings: [ShortcutAction: KeyBinding] = ShowSettings.defaultBindings,
        outputGroups: [OutputGroup] = [],
        workspaceMode: WorkspaceMode = .edit,
        virtualCameraFeed: Bool = false,
        midiEnabled: Bool = false,
        midiBindings: [MIDIBindingEntry] = [],
        oscEnabled: Bool = false,
        oscPort: UInt16 = 53100,
        webRemoteEnabled: Bool = false,
        webRemotePort: UInt16 = 53200,
        stageDisplay: StageDisplaySettings = StageDisplaySettings()
    ) {
        self.panicDuration = panicDuration
        self.doubleGOProtection = doubleGOProtection
        self.armAheadCount = armAheadCount
        self.keyBindings = keyBindings
        self.outputGroups = outputGroups
        self.workspaceMode = workspaceMode
        self.virtualCameraFeed = virtualCameraFeed
        self.midiEnabled = midiEnabled
        self.midiBindings = midiBindings
        self.oscEnabled = oscEnabled
        self.oscPort = oscPort
        self.webRemoteEnabled = webRemoteEnabled
        self.webRemotePort = webRemotePort
        self.stageDisplay = stageDisplay
    }

    private enum CodingKeys: String, CodingKey {
        case panicDuration, doubleGOProtection, armAheadCount, keyBindings, outputGroups, workspaceMode
        case virtualCameraFeed, midiEnabled, midiBindings, oscEnabled, oscPort
        case webRemoteEnabled, webRemotePort, stageDisplay
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
        virtualCameraFeed = try container.decodeIfPresent(Bool.self, forKey: .virtualCameraFeed) ?? false
        // Pre-D6 files predate MIDI remote control entirely.
        midiEnabled = try container.decodeIfPresent(Bool.self, forKey: .midiEnabled) ?? false
        midiBindings = try container.decodeIfPresent([MIDIBindingEntry].self, forKey: .midiBindings) ?? []
        // Pre-D7 files predate OSC remote control entirely.
        oscEnabled = try container.decodeIfPresent(Bool.self, forKey: .oscEnabled) ?? false
        // Decoded as Int, not UInt16: a corrupt/out-of-range value (70000,
        // negative) would THROW straight through `decodeIfPresent(UInt16.self,
        // …)` — JSONDecoder validates range fit before the `if let` ever gets
        // a chance to fall back — and refuse the whole show file. Decoding as
        // Int always succeeds for any JSON number, so the range check below
        // can actually run and fall back instead of propagating the error.
        let oscPortRaw = try container.decodeIfPresent(Int.self, forKey: .oscPort) ?? 53100
        oscPort = (1024...65535).contains(oscPortRaw) ? UInt16(oscPortRaw) : 53100
        // Pre-D8 files predate the web remote entirely.
        webRemoteEnabled = try container.decodeIfPresent(Bool.self, forKey: .webRemoteEnabled) ?? false
        let webRemotePortRaw = try container.decodeIfPresent(Int.self, forKey: .webRemotePort) ?? 53200
        webRemotePort = (1024...65535).contains(webRemotePortRaw) ? UInt16(webRemotePortRaw) : 53200
        // Pre-D9 files predate the stage display entirely.
        stageDisplay = try container.decodeIfPresent(StageDisplaySettings.self, forKey: .stageDisplay) ?? StageDisplaySettings()
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

/// A fullscreen performer-facing confidence monitor (clock, show timer,
/// standing-by cue + notes, running cues) shown on a chosen display while
/// the workspace is in Show or Rehearsal mode. Reads transport state only —
/// it is NEVER a cue target, so it uses the same `DisplayFingerprint`
/// matching mechanism as `OutputGroup.displays` but is otherwise unrelated
/// to output routing.
public struct StageDisplaySettings: Codable, Hashable, Sendable {
    public var enabled: Bool
    /// The chosen physical display; nil = none picked yet.
    public var display: DisplayFingerprint?
    public var showsClock: Bool
    public var showsShowTimer: Bool
    public var showsNotes: Bool
    public var showsRunning: Bool

    public init(
        enabled: Bool = false,
        display: DisplayFingerprint? = nil,
        showsClock: Bool = true,
        showsShowTimer: Bool = true,
        showsNotes: Bool = true,
        showsRunning: Bool = true
    ) {
        self.enabled = enabled
        self.display = display
        self.showsClock = showsClock
        self.showsShowTimer = showsShowTimer
        self.showsNotes = showsNotes
        self.showsRunning = showsRunning
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, display, showsClock, showsShowTimer, showsNotes, showsRunning
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        display = try container.decodeIfPresent(DisplayFingerprint.self, forKey: .display)
        showsClock = try container.decodeIfPresent(Bool.self, forKey: .showsClock) ?? true
        showsShowTimer = try container.decodeIfPresent(Bool.self, forKey: .showsShowTimer) ?? true
        showsNotes = try container.decodeIfPresent(Bool.self, forKey: .showsNotes) ?? true
        showsRunning = try container.decodeIfPresent(Bool.self, forKey: .showsRunning) ?? true
    }
}

/// Root of the persisted show document.
public struct ShowFile: Codable, Hashable, Sendable {
    /// 2: video/camera cues target OutputGroups instead of raw displays.
    /// 3: GroupMode.enterAndPlayFirst (older apps can't decode the new mode,
    ///    so they must refuse v3 files cleanly instead of failing mid-parse).
    /// 4: FollowAction.autoContinueAtMarker (older apps' FollowAction decoder
    ///    throws on the unknown "mode" string, which would fail the whole
    ///    file mid-parse — so v4 files must be refused cleanly instead; no
    ///    migration needed, v3 files still decode as-is).
    public static let currentFormatVersion = 4

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
