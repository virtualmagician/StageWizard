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

/// The seven things the stage display can show. Order here is the STABLE
/// order used everywhere panes are enumerated (settings UI, layout editor,
/// `StageDisplaySettings.panes` after migration/fill-in) — changing it
/// changes nothing functionally (each pane is looked up by kind) but keeps
/// lists/checklists from reordering across app versions. `gesture` (D15) is
/// appended at the end for exactly that reason — older show files simply
/// don't have it yet, and `StageDisplayPane.fillingMissing` fills it in.
public enum StageDisplayPaneKind: String, Codable, CaseIterable, Sendable {
    case clock, showTimer, standingBy, notes, running, program, gesture
}

/// One region of the stage display: whether it's shown, and where — in
/// NORMALIZED, Y-DOWN coordinates (origin top-left, same as screen/window
/// coordinates in most UI toolkits) — deliberately the OPPOSITE convention
/// from `StageRect`'s other use (`TextBody.box`, bottom-left/y-up, matching
/// stage/layer space) because pane layout is authored top-down like any
/// other 2D UI canvas; `StageDisplayGeometry.appKitFrame` converts to
/// AppKit's y-up window space when the program pane hosts a live layer.
public struct StageDisplayPane: Codable, Hashable, Sendable, Identifiable {
    public var kind: StageDisplayPaneKind
    public var enabled: Bool
    public var rect: StageRect
    /// D16: which output group a PROGRAM pane mirrors. Meaningless (always
    /// nil) for every other kind. The panes array may now hold MULTIPLE
    /// `.program` panes — one per mirrored group — distinguished by this id;
    /// a `.program` pane with a nil groupID is a legacy, not-yet-migrated
    /// entry (see `StageDisplayPane.fillingMissing`) and never survives
    /// reconciliation.
    public var programGroupID: UUID?

    /// Stable per-pane identity for SwiftUI lists/ForEach and lookups: the
    /// kind's raw value for every non-program kind (exactly one of those
    /// ever exists), or `"program-<group uuid>"` for a program pane — so
    /// multiple program panes (one per mirrored group) each get their own
    /// distinct, stable id. A program pane that hasn't been assigned a group
    /// yet (only possible transiently, mid-migration) falls back to a fixed
    /// placeholder id; `fillingMissing` never lets one of those survive into
    /// a settled `panes` array.
    public var id: String {
        switch kind {
        case .program: programGroupID.map { "program-\($0.uuidString)" } ?? "program-legacy"
        default: kind.rawValue
        }
    }

    public init(kind: StageDisplayPaneKind, enabled: Bool, rect: StageRect, programGroupID: UUID? = nil) {
        self.kind = kind
        self.enabled = enabled
        self.rect = Self.clamped(rect)
        self.programGroupID = programGroupID
    }

    private enum CodingKeys: String, CodingKey { case kind, enabled, rect, programGroupID }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(StageDisplayPaneKind.self, forKey: .kind)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        let decodedRect = try c.decodeIfPresent(StageRect.self, forKey: .rect) ?? Self.defaultRect(for: kind)
        rect = Self.clamped(decodedRect)
        programGroupID = try c.decodeIfPresent(UUID.self, forKey: .programGroupID)
    }

    /// Smallest a pane may ever be — enforced on every decode AND every
    /// live edit (layout editor drags), so a corrupt/hand-edited show file
    /// or an aggressive resize can never collapse a pane to nothing.
    public static let minimumSize = (width: 0.05, height: 0.04)

    /// Clamp fully inside 0...1 with the enforced minimum size. Also guards
    /// against non-finite numbers (NaN/inf from bad hand-edited JSON)
    /// collapsing the whole layout.
    public static func clamped(_ rect: StageRect) -> StageRect {
        let width = (rect.width.isFinite ? rect.width : minimumSize.width).clamped(to: minimumSize.width...1)
        let height = (rect.height.isFinite ? rect.height : minimumSize.height).clamped(to: minimumSize.height...1)
        let x = (rect.x.isFinite ? rect.x : 0).clamped(to: 0...(1 - width))
        let y = (rect.y.isFinite ? rect.y : 0).clamped(to: 0...(1 - height))
        return StageRect(x: x, y: y, width: width, height: height)
    }

    /// Default position/size per pane — chosen so all seven fit the 16:9
    /// stage without overlapping badly out of the box; the operator
    /// rearranges from there in the layout editor.
    public static func defaultRect(for kind: StageDisplayPaneKind) -> StageRect {
        switch kind {
        case .clock: StageRect(x: 0.02, y: 0.02, width: 0.30, height: 0.12)
        case .showTimer: StageRect(x: 0.68, y: 0.02, width: 0.30, height: 0.12)
        case .standingBy: StageRect(x: 0.05, y: 0.18, width: 0.90, height: 0.34)
        case .notes: StageRect(x: 0.10, y: 0.55, width: 0.80, height: 0.15)
        case .running: StageRect(x: 0.02, y: 0.72, width: 0.96, height: 0.26)
        case .program: StageRect(x: 0.62, y: 0.52, width: 0.36, height: 0.18)
        case .gesture: StageRect(x: 0.02, y: 0.52, width: 0.30, height: 0.18)
        }
    }

    /// Every pane starts enabled EXCEPT the program view (targets no output
    /// group until the operator picks one — showing it by default would
    /// just be a black box) and the D15 gesture pane (experimental, and
    /// meaningless until a camera cue has gesture GO enabled).
    public static func defaultEnabled(for kind: StageDisplayPaneKind) -> Bool {
        switch kind {
        case .program, .gesture: false
        default: true
        }
    }

    /// One pane per NON-program kind, at its default position and enabled
    /// state. No default `.program` pane — D16 program panes only exist once
    /// the operator picks a group to mirror (there's no meaningful "default"
    /// group to pre-select), so a fresh show simply mirrors nothing.
    public static var defaults: [StageDisplayPane] {
        StageDisplayPaneKind.allCases.filter { $0 != .program }.map {
            StageDisplayPane(kind: $0, enabled: defaultEnabled(for: $0), rect: defaultRect(for: $0))
        }
    }

    /// Reconcile a decoded panes array: every NON-program kind fills in to
    /// exactly one entry (an older-minor-version file, or a hand-trimmed
    /// array, gets its default; duplicates drop with last-one-wins) exactly
    /// as before D16. `.program` panes are handled separately since there
    /// can now be any number of them, one per mirrored output group:
    /// `legacyProgramGroupID` (present only when migrating a D13-era file —
    /// see `StageDisplaySettings.init(from:)`) is grafted onto the first
    /// still-ungrouped program pane, and any program pane that ends up with
    /// no group at all (never migrated, or hand-authored without one) is
    /// dropped — it would mirror nothing. Remaining program panes dedup by
    /// group (last one wins), keeping first-seen order.
    public static func fillingMissing(_ decoded: [StageDisplayPane], legacyProgramGroupID: UUID? = nil) -> [StageDisplayPane] {
        var byKind: [StageDisplayPaneKind: StageDisplayPane] = [:]
        var programPanes: [StageDisplayPane] = []
        for pane in decoded {
            if pane.kind == .program {
                programPanes.append(pane)
            } else {
                byKind[pane.kind] = pane
            }
        }
        let nonProgram = StageDisplayPaneKind.allCases.filter { $0 != .program }.map {
            byKind[$0] ?? StageDisplayPane(kind: $0, enabled: defaultEnabled(for: $0), rect: defaultRect(for: $0))
        }

        if let legacyProgramGroupID,
           let idx = programPanes.firstIndex(where: { $0.programGroupID == nil }) {
            programPanes[idx].programGroupID = legacyProgramGroupID
        }

        var byGroup: [UUID: StageDisplayPane] = [:]
        var groupOrder: [UUID] = []
        for pane in programPanes {
            guard let groupID = pane.programGroupID else { continue }
            if byGroup[groupID] == nil { groupOrder.append(groupID) }
            byGroup[groupID] = pane
        }
        let reconciledProgramPanes = groupOrder.compactMap { byGroup[$0] }

        return nonProgram + reconciledProgramPanes
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

/// A fullscreen performer-facing confidence monitor (clock, show timer,
/// standing-by cue, notes, running cues, and — D13 — a live PROGRAM view
/// mirroring an output group) shown on a chosen display while the workspace
/// is in Show or Rehearsal mode. Reads transport state only (the program
/// view is the one exception: it also mirrors real cue output) — it is
/// NEVER a cue target itself, so it uses the same `DisplayFingerprint`
/// matching mechanism as `OutputGroup.displays` but is otherwise unrelated
/// to output routing.
public struct StageDisplaySettings: Codable, Hashable, Sendable {
    public var enabled: Bool
    /// The chosen physical display; nil = none picked yet.
    public var display: DisplayFingerprint?
    /// Exactly one entry per NON-program `StageDisplayPaneKind`, plus zero or
    /// more `.program` panes — one per output group currently mirrored on
    /// the stage display (D16). Program panes are distinguished by
    /// `StageDisplayPane.programGroupID` / `.id`, not by kind.
    public var panes: [StageDisplayPane]

    public init(
        enabled: Bool = false,
        display: DisplayFingerprint? = nil,
        panes: [StageDisplayPane] = StageDisplayPane.defaults
    ) {
        self.enabled = enabled
        self.display = display
        self.panes = StageDisplayPane.fillingMissing(panes)
    }

    /// Look up one pane by kind. Meaningful only for NON-program kinds — for
    /// those, `panes` is guaranteed (by every initializer/decoder) to hold
    /// exactly one entry, so this always succeeds; the fallback default only
    /// guards a theoretical invariant violation (never trust that blindly
    /// with `!`). For `.program`, prefer `programPanes` or
    /// `programPane(forGroup:)` — this returns only the FIRST program pane
    /// (if any), which is rarely what a D16 caller wants.
    public func pane(_ kind: StageDisplayPaneKind) -> StageDisplayPane {
        panes.first { $0.kind == kind }
            ?? StageDisplayPane(kind: kind, enabled: StageDisplayPane.defaultEnabled(for: kind), rect: StageDisplayPane.defaultRect(for: kind))
    }

    /// Every `.program` pane — one per output group currently mirrored on
    /// the stage display, in `panes` order.
    public var programPanes: [StageDisplayPane] {
        panes.filter { $0.kind == .program }
    }

    /// The program pane mirroring a specific output group, if any.
    public func programPane(forGroup groupID: UUID) -> StageDisplayPane? {
        panes.first { $0.kind == .program && $0.programGroupID == groupID }
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, display, panes
    }

    /// Pre-D13 key names, plus D13-era `programGroupID` — decode-only (never
    /// encoded again once a show file is resaved). A pre-D13 dev-build file
    /// has NO `panes` key; its meaning carries forward into the matching
    /// pane's `enabled` flag. `standingBy` had no toggle before D13 (always
    /// shown) and `program` didn't exist, so both fall back to their
    /// ordinary defaults. D13-D15 encoded the program pane's mirrored group
    /// as this top-level `programGroupID` (exactly one program pane, always);
    /// D16 moved that onto the pane itself (`StageDisplayPane.programGroupID`)
    /// to support more than one — see `StageDisplayPane.fillingMissing`.
    private enum LegacyCodingKeys: String, CodingKey {
        case showsClock, showsShowTimer, showsNotes, showsRunning, programGroupID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        display = try container.decodeIfPresent(DisplayFingerprint.self, forKey: .display)
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)

        if let decodedPanes = try container.decodeIfPresent([StageDisplayPane].self, forKey: .panes) {
            // D13-D15 files carry the mirrored group as a top-level key
            // sitting alongside a bare `.program` pane with no groupID of
            // its own — graft it on. Files that never had a `.program` pane
            // to begin with (pre-D13) never reach this branch at all (no
            // `panes` key), so there's nothing to graft onto there.
            let legacyProgramGroupID = try legacy.decodeIfPresent(UUID.self, forKey: .programGroupID)
            panes = StageDisplayPane.fillingMissing(decodedPanes, legacyProgramGroupID: legacyProgramGroupID)
        } else {
            let showsClock = try legacy.decodeIfPresent(Bool.self, forKey: .showsClock) ?? true
            let showsShowTimer = try legacy.decodeIfPresent(Bool.self, forKey: .showsShowTimer) ?? true
            let showsNotes = try legacy.decodeIfPresent(Bool.self, forKey: .showsNotes) ?? true
            let showsRunning = try legacy.decodeIfPresent(Bool.self, forKey: .showsRunning) ?? true
            panes = StageDisplayPaneKind.allCases.filter { $0 != .program }.map { kind in
                let enabled: Bool
                switch kind {
                case .clock: enabled = showsClock
                case .showTimer: enabled = showsShowTimer
                case .standingBy: enabled = true
                case .notes: enabled = showsNotes
                case .running: enabled = showsRunning
                case .gesture: enabled = StageDisplayPane.defaultEnabled(for: .gesture)
                case .program: enabled = false // unreachable — filtered above
                }
                return StageDisplayPane(kind: kind, enabled: enabled, rect: StageDisplayPane.defaultRect(for: kind))
            }
        }
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
