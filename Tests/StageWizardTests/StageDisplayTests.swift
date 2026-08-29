import XCTest
import AppKit
import QuartzCore
@testable import StageWizard

/// Phase D9: stage display — a fullscreen performer-facing confidence
/// monitor (clock, show timer, standing-by cue, notes, running cues).
/// NEVER a cue target; reads transport state only.
///
/// Deliberately creates NO windows — coverage is Codable/defaults on
/// `StageDisplaySettings`, the pure `StageDisplayController.isActive`
/// decision function, and the pure formatting helpers in `StageDisplayFormat`.
@MainActor
final class StageDisplayTests: XCTestCase {

    // MARK: - Codable: StageDisplaySettings defaults

    func testStageDisplaySettingsDefaults() {
        let settings = StageDisplaySettings()
        XCTAssertFalse(settings.enabled)
        XCTAssertNil(settings.display)
        // D16: no default program pane at all — one per mirrored group, and
        // there's no meaningful "default" group to pre-select.
        XCTAssertTrue(settings.programPanes.isEmpty, "a fresh show mirrors no groups on the stage display")
        XCTAssertEqual(settings.panes.count, StageDisplayPaneKind.allCases.count - 1, "every non-program kind, no program panes")
        XCTAssertTrue(settings.pane(.clock).enabled)
        XCTAssertTrue(settings.pane(.showTimer).enabled)
        XCTAssertTrue(settings.pane(.standingBy).enabled)
        XCTAssertTrue(settings.pane(.notes).enabled)
        XCTAssertTrue(settings.pane(.running).enabled)
        XCTAssertFalse(settings.pane(.gesture).enabled, "D15 gesture pane is off by default — experimental")
    }

    func testShowSettingsDefaultsIncludeStageDisplay() {
        let settings = ShowSettings()
        XCTAssertFalse(settings.stageDisplay.enabled)
        XCTAssertNil(settings.stageDisplay.display)
    }

    func testOlderShowFileWithoutStageDisplayKeyDecodesToDefaults() throws {
        // A pre-D9 show file predates the stage display entirely.
        var show = ShowFile()
        show.settings.stageDisplay.enabled = true
        var json = try JSONSerialization.jsonObject(with: show.encoded()) as! [String: Any]
        var settings = json["settings"] as! [String: Any]
        settings.removeValue(forKey: "stageDisplay")
        json["settings"] = settings
        let stripped = try JSONSerialization.data(withJSONObject: json)

        let decoded = try ShowFile.load(from: stripped)
        XCTAssertFalse(decoded.settings.stageDisplay.enabled, "pre-D9 files predate the stage display")
        XCTAssertEqual(decoded.settings.stageDisplay.panes.count, StageDisplayPaneKind.allCases.count - 1, "every non-program kind, no program panes")
        XCTAssertTrue(decoded.settings.stageDisplay.pane(.clock).enabled)
        XCTAssertTrue(decoded.settings.stageDisplay.pane(.showTimer).enabled)
        XCTAssertTrue(decoded.settings.stageDisplay.pane(.standingBy).enabled)
        XCTAssertTrue(decoded.settings.stageDisplay.pane(.notes).enabled)
        XCTAssertTrue(decoded.settings.stageDisplay.pane(.running).enabled)
        XCTAssertFalse(decoded.settings.stageDisplay.pane(.program).enabled, "program view is brand new — off by default")
        XCTAssertFalse(decoded.settings.stageDisplay.pane(.gesture).enabled, "gesture pane is brand new — off by default")
    }

    func testStageDisplayLegacyBooleanKeysMigrateIntoPaneEnabledFlags() throws {
        // A pre-D13 dev-build file: `stageDisplay` object exists with the
        // OLD top-level booleans and no `panes` key at all. Their meaning
        // must carry forward into the matching pane's `enabled` flag.
        var json = try JSONSerialization.jsonObject(with: ShowFile().encoded()) as! [String: Any]
        var settings = json["settings"] as! [String: Any]
        settings["stageDisplay"] = [
            "enabled": true,
            "showsClock": false,
            "showsShowTimer": true,
            "showsNotes": false,
            "showsRunning": true,
        ]
        json["settings"] = settings
        let data = try JSONSerialization.data(withJSONObject: json)

        let decoded = try ShowFile.load(from: data)
        let s = decoded.settings.stageDisplay
        XCTAssertTrue(s.enabled)
        XCTAssertFalse(s.pane(.clock).enabled)
        XCTAssertTrue(s.pane(.showTimer).enabled)
        XCTAssertTrue(s.pane(.standingBy).enabled, "D9 always showed standing-by — no legacy toggle existed for it")
        XCTAssertFalse(s.pane(.notes).enabled)
        XCTAssertTrue(s.pane(.running).enabled)
        XCTAssertFalse(s.pane(.program).enabled, "brand new in D13 — off by default even migrating an old file")
        XCTAssertFalse(s.pane(.gesture).enabled, "brand new in D15 — off by default even migrating an old file")
    }

    func testStageDisplayObjectWithNoLegacyKeysAndNoPanesKeyDefaultsAllPanes() throws {
        // `stageDisplay` present but bare-bones — neither the old booleans
        // nor the new `panes` array (e.g. a minimal hand-authored file).
        var json = try JSONSerialization.jsonObject(with: ShowFile().encoded()) as! [String: Any]
        var settings = json["settings"] as! [String: Any]
        settings["stageDisplay"] = ["enabled": true]
        json["settings"] = settings
        let data = try JSONSerialization.data(withJSONObject: json)

        let decoded = try ShowFile.load(from: data)
        let s = decoded.settings.stageDisplay
        XCTAssertTrue(s.enabled)
        for kind: StageDisplayPaneKind in [.clock, .showTimer, .standingBy, .notes, .running] {
            XCTAssertTrue(s.pane(kind).enabled, "\(kind) defaults to enabled")
        }
        XCTAssertFalse(s.pane(.program).enabled)
        XCTAssertFalse(s.pane(.gesture).enabled)
    }

    func testStageDisplayPartialPanesArrayFillsInMissingKinds() throws {
        var json = try JSONSerialization.jsonObject(with: ShowFile().encoded()) as! [String: Any]
        var settings = json["settings"] as! [String: Any]
        settings["stageDisplay"] = [
            "enabled": true,
            "panes": [
                ["kind": "clock", "enabled": false, "rect": ["x": 0.0, "y": 0.0, "width": 0.2, "height": 0.1]],
            ],
        ]
        json["settings"] = settings
        let data = try JSONSerialization.data(withJSONObject: json)

        let decoded = try ShowFile.load(from: data)
        let s = decoded.settings.stageDisplay
        XCTAssertEqual(s.panes.count, StageDisplayPaneKind.allCases.count - 1, "every non-program kind present exactly once, no program panes")
        XCTAssertFalse(s.pane(.clock).enabled)
        XCTAssertEqual(s.pane(.clock).rect, StageRect(x: 0, y: 0, width: 0.2, height: 0.1))
        XCTAssertTrue(s.pane(.showTimer).enabled, "missing kind filled in with its default")
        XCTAssertEqual(s.pane(.showTimer).rect, StageDisplayPane.defaultRect(for: .showTimer))
        XCTAssertTrue(s.programPanes.isEmpty, "no program pane in the decoded array — nothing to fill in for it")
        XCTAssertFalse(s.pane(.gesture).enabled, "missing kind filled in with its (disabled) default")
        XCTAssertEqual(s.pane(.gesture).rect, StageDisplayPane.defaultRect(for: .gesture))
    }

    // MARK: - D15: gesture pane kind

    func testGesturePaneKindIsPartOfAllCases() {
        XCTAssertTrue(StageDisplayPaneKind.allCases.contains(.gesture))
    }

    func testGesturePaneDefaultsToDisabled() {
        XCTAssertFalse(StageDisplayPane.defaultEnabled(for: .gesture))
    }

    func testGesturePaneDefaultRectIsOnScreenAndAboveMinimumSize() {
        let rect = StageDisplayPane.defaultRect(for: .gesture)
        XCTAssertEqual(rect, StageRect(x: 0.02, y: 0.52, width: 0.30, height: 0.18))
        XCTAssertGreaterThanOrEqual(rect.width, StageDisplayPane.minimumSize.width)
        XCTAssertGreaterThanOrEqual(rect.height, StageDisplayPane.minimumSize.height)
    }

    /// Simulates a genuinely pre-D15 `panes` array — every OTHER kind
    /// present and explicitly enabled, `gesture` entirely absent (it did
    /// not exist yet) — the exact shape `fillingMissing` exists to repair.
    func testPreD15PanesArrayFillsInGestureAsDisabledAtItsDefaultRect() throws {
        // Faithful D13/14-era shape: a bare `.program` pane (no groupID of
        // its own yet) paired with the top-level legacy `programGroupID` —
        // D16 migrates that onto the pane (see the dedicated migration
        // tests below), so it survives reconciliation just like every other
        // pre-existing kind here.
        var json = try JSONSerialization.jsonObject(with: ShowFile().encoded()) as! [String: Any]
        var settings = json["settings"] as! [String: Any]
        let preD15Kinds: [StageDisplayPaneKind] = [.clock, .showTimer, .standingBy, .notes, .running, .program]
        let legacyGroupID = UUID()
        settings["stageDisplay"] = [
            "enabled": true,
            "programGroupID": legacyGroupID.uuidString,
            "panes": preD15Kinds.map { kind in
                ["kind": kind.rawValue, "enabled": true, "rect": ["x": 0.0, "y": 0.0, "width": 0.2, "height": 0.1]]
            },
        ]
        json["settings"] = settings
        let data = try JSONSerialization.data(withJSONObject: json)

        let decoded = try ShowFile.load(from: data)
        let s = decoded.settings.stageDisplay
        XCTAssertEqual(s.panes.count, StageDisplayPaneKind.allCases.count, "gesture filled in, program migrated onto its group — one entry per kind")
        XCTAssertFalse(s.pane(.gesture).enabled, "brand new kind — never present in the old array, so its default (off) applies")
        XCTAssertEqual(s.pane(.gesture).rect, StageDisplayPane.defaultRect(for: .gesture))
        // Every pre-existing kind keeps what the old file actually said.
        for kind in preD15Kinds {
            XCTAssertTrue(s.pane(kind).enabled, "\(kind) keeps its explicit pre-D15 value")
        }
        XCTAssertEqual(s.programPane(forGroup: legacyGroupID)?.programGroupID, legacyGroupID)
    }

    func testGesturePaneRoundTripsThroughShowFileWhenEnabled() throws {
        var show = ShowFile()
        var settings = StageDisplaySettings()
        if let idx = settings.panes.firstIndex(where: { $0.kind == .gesture }) {
            settings.panes[idx].enabled = true
            settings.panes[idx].rect = StageRect(x: 0.05, y: 0.6, width: 0.25, height: 0.2)
        }
        show.settings.stageDisplay = settings

        let decoded = try ShowFile.load(from: show.encoded())
        XCTAssertTrue(decoded.settings.stageDisplay.pane(.gesture).enabled)
        XCTAssertEqual(decoded.settings.stageDisplay.pane(.gesture).rect, StageRect(x: 0.05, y: 0.6, width: 0.25, height: 0.2))
    }

    func testStageDisplayPaneRectClampsOutOfRangeAndTooSmallOnDecode() throws {
        var json = try JSONSerialization.jsonObject(with: ShowFile().encoded()) as! [String: Any]
        var settings = json["settings"] as! [String: Any]
        settings["stageDisplay"] = [
            "enabled": true,
            "panes": [
                ["kind": "clock", "enabled": true, "rect": ["x": -0.5, "y": 1.5, "width": 2.0, "height": 0.001]],
            ],
        ]
        json["settings"] = settings
        let data = try JSONSerialization.data(withJSONObject: json)

        let decoded = try ShowFile.load(from: data)
        let rect = decoded.settings.stageDisplay.pane(.clock).rect
        XCTAssertGreaterThanOrEqual(rect.x, 0)
        XCTAssertLessThanOrEqual(rect.x + rect.width, 1.0001)
        XCTAssertGreaterThanOrEqual(rect.y, 0)
        XCTAssertLessThanOrEqual(rect.y + rect.height, 1.0001)
        XCTAssertGreaterThanOrEqual(rect.width, StageDisplayPane.minimumSize.width)
        XCTAssertGreaterThanOrEqual(rect.height, StageDisplayPane.minimumSize.height)
    }

    // MARK: - Codable: full round-trip with a fingerprint + panes

    func testStageDisplaySettingsRoundTripThroughShowFile() throws {
        var show = ShowFile()
        let fingerprint = DisplayFingerprint(
            vendorNumber: 1552,
            modelNumber: 0x4249,
            serialNumber: 12345,
            name: "Prompter Monitor",
            pixelWidth: 1920,
            pixelHeight: 1080
        )
        var settings = StageDisplaySettings(enabled: true, display: fingerprint)
        if let idx = settings.panes.firstIndex(where: { $0.kind == .clock }) {
            settings.panes[idx].enabled = false
        }
        show.settings.stageDisplay = settings

        let decoded = try ShowFile.load(from: show.encoded())
        XCTAssertEqual(decoded.settings.stageDisplay.enabled, true)
        XCTAssertEqual(decoded.settings.stageDisplay.display, fingerprint)
        XCTAssertFalse(decoded.settings.stageDisplay.pane(.clock).enabled)
        XCTAssertTrue(decoded.settings.stageDisplay.pane(.showTimer).enabled)
    }

    func testStageDisplayPanesRoundTripThroughShowFile() throws {
        var show = ShowFile()
        var settings = StageDisplaySettings()
        let groupID = UUID()
        settings.panes.append(StageDisplayPane(
            kind: .program, enabled: true, rect: StageRect(x: 0.1, y: 0.2, width: 0.3, height: 0.25), programGroupID: groupID
        ))
        show.settings.stageDisplay = settings

        let decoded = try ShowFile.load(from: show.encoded())
        XCTAssertEqual(decoded.settings.stageDisplay.panes.count, StageDisplayPaneKind.allCases.count)
        let pane = decoded.settings.stageDisplay.programPane(forGroup: groupID)
        XCTAssertEqual(pane?.enabled, true)
        XCTAssertEqual(pane?.rect, StageRect(x: 0.1, y: 0.2, width: 0.3, height: 0.25))
        XCTAssertEqual(pane?.programGroupID, groupID)
    }

    // MARK: - D16: multiple program panes (one per mirrored output group)

    func testMultipleProgramPanesRoundTripThroughShowFileWithTheirOwnGroupIDs() throws {
        var show = ShowFile()
        var settings = StageDisplaySettings()
        let groupA = UUID()
        let groupB = UUID()
        settings.panes.append(StageDisplayPane(
            kind: .program, enabled: true, rect: StageRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), programGroupID: groupA
        ))
        settings.panes.append(StageDisplayPane(
            kind: .program, enabled: false, rect: StageRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2), programGroupID: groupB
        ))
        show.settings.stageDisplay = settings

        let decoded = try ShowFile.load(from: show.encoded())
        let s = decoded.settings.stageDisplay
        XCTAssertEqual(s.programPanes.count, 2)
        XCTAssertEqual(s.programPane(forGroup: groupA)?.enabled, true)
        XCTAssertEqual(s.programPane(forGroup: groupA)?.rect, StageRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        XCTAssertEqual(s.programPane(forGroup: groupB)?.enabled, false)
        XCTAssertEqual(s.programPane(forGroup: groupB)?.rect, StageRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2))
        // Every non-program kind is still exactly one entry, untouched.
        for kind in StageDisplayPaneKind.allCases where kind != .program {
            XCTAssertNotNil(s.panes.first { $0.kind == kind })
        }
    }

    func testProgramPaneIDsAreDistinctPerGroupAndStableAcrossReencoding() throws {
        var show = ShowFile()
        var settings = StageDisplaySettings()
        let groupA = UUID()
        let groupB = UUID()
        settings.panes.append(StageDisplayPane(kind: .program, enabled: true, rect: StageDisplayPane.defaultRect(for: .program), programGroupID: groupA))
        settings.panes.append(StageDisplayPane(kind: .program, enabled: true, rect: StageDisplayPane.defaultRect(for: .program), programGroupID: groupB))
        show.settings.stageDisplay = settings

        let decoded = try ShowFile.load(from: show.encoded())
        let ids = Set(decoded.settings.stageDisplay.programPanes.map(\.id))
        XCTAssertEqual(ids.count, 2, "each program pane keeps its own distinct id")
    }

    func testD13EraFileWithTopLevelProgramGroupIDMigratesOntoTheBareProgramPane() throws {
        // Exact D13-D15 shape: `panes` contains a bare `.program` entry with
        // no groupID of its own, and the group it mirrors lives in the
        // sibling top-level `programGroupID` key.
        var json = try JSONSerialization.jsonObject(with: ShowFile().encoded()) as! [String: Any]
        var settings = json["settings"] as! [String: Any]
        let legacyGroupID = UUID()
        settings["stageDisplay"] = [
            "enabled": true,
            "programGroupID": legacyGroupID.uuidString,
            "panes": [
                ["kind": "program", "enabled": true, "rect": ["x": 0.6, "y": 0.5, "width": 0.3, "height": 0.2]],
            ],
        ]
        json["settings"] = settings
        let data = try JSONSerialization.data(withJSONObject: json)

        let decoded = try ShowFile.load(from: data)
        let s = decoded.settings.stageDisplay
        XCTAssertEqual(s.programPanes.count, 1, "the one D13-era program pane survives, now carrying its group")
        let pane = s.programPane(forGroup: legacyGroupID)
        XCTAssertNotNil(pane)
        XCTAssertEqual(pane?.enabled, true)
        XCTAssertEqual(pane?.rect, StageRect(x: 0.6, y: 0.5, width: 0.3, height: 0.2))
    }

    func testD13EraFileWithNilTopLevelProgramGroupIDDropsTheBareProgramPane() throws {
        // A D13-era file where the operator enabled the program pane but
        // never actually picked a group — `programGroupID` is present and
        // explicitly null. Nothing to migrate onto, so the pane is dropped
        // (it would mirror nothing either way).
        var json = try JSONSerialization.jsonObject(with: ShowFile().encoded()) as! [String: Any]
        var settings = json["settings"] as! [String: Any]
        settings["stageDisplay"] = [
            "enabled": true,
            "programGroupID": NSNull(),
            "panes": [
                ["kind": "program", "enabled": true, "rect": ["x": 0.6, "y": 0.5, "width": 0.3, "height": 0.2]],
            ],
        ]
        json["settings"] = settings
        let data = try JSONSerialization.data(withJSONObject: json)

        let decoded = try ShowFile.load(from: data)
        XCTAssertTrue(decoded.settings.stageDisplay.programPanes.isEmpty, "an ungrouped program pane mirrors nothing — dropped")
    }

    func testBareProgramPaneWithNoLegacyKeyAtAllIsDropped() throws {
        // No top-level `programGroupID` key whatsoever (not even present) —
        // same outcome as an explicit null: nothing to graft, so it drops.
        var json = try JSONSerialization.jsonObject(with: ShowFile().encoded()) as! [String: Any]
        var settings = json["settings"] as! [String: Any]
        settings["stageDisplay"] = [
            "enabled": true,
            "panes": [
                ["kind": "program", "enabled": true, "rect": ["x": 0.6, "y": 0.5, "width": 0.3, "height": 0.2]],
            ],
        ]
        json["settings"] = settings
        let data = try JSONSerialization.data(withJSONObject: json)

        let decoded = try ShowFile.load(from: data)
        XCTAssertTrue(decoded.settings.stageDisplay.programPanes.isEmpty)
    }

    func testNonProgramKindFillInNeverDuplicatesProgramPanes() throws {
        // A hand-trimmed `panes` array missing several non-program kinds AND
        // holding two genuinely-grouped program panes — filling in the
        // missing kinds must never touch, drop, or duplicate the program
        // panes already present.
        var json = try JSONSerialization.jsonObject(with: ShowFile().encoded()) as! [String: Any]
        var settings = json["settings"] as! [String: Any]
        let groupA = UUID()
        let groupB = UUID()
        settings["stageDisplay"] = [
            "enabled": true,
            "panes": [
                ["kind": "clock", "enabled": true, "rect": ["x": 0.0, "y": 0.0, "width": 0.2, "height": 0.1]],
                ["kind": "program", "enabled": true, "rect": ["x": 0.1, "y": 0.1, "width": 0.2, "height": 0.2], "programGroupID": groupA.uuidString],
                ["kind": "program", "enabled": true, "rect": ["x": 0.5, "y": 0.5, "width": 0.2, "height": 0.2], "programGroupID": groupB.uuidString],
            ],
        ]
        json["settings"] = settings
        let data = try JSONSerialization.data(withJSONObject: json)

        let decoded = try ShowFile.load(from: data)
        let s = decoded.settings.stageDisplay
        XCTAssertEqual(s.programPanes.count, 2, "both grouped program panes survive fill-in untouched")
        XCTAssertNotNil(s.programPane(forGroup: groupA))
        XCTAssertNotNil(s.programPane(forGroup: groupB))
        // Every non-program kind still fills to exactly one, including the
        // ones missing from this hand-trimmed array.
        let nonProgramCount = s.panes.filter { $0.kind != .program }.count
        XCTAssertEqual(nonProgramCount, StageDisplayPaneKind.allCases.count - 1)
    }

    func testDuplicateProgramPanesForTheSameGroupDedupWithLastOneWinning() throws {
        var json = try JSONSerialization.jsonObject(with: ShowFile().encoded()) as! [String: Any]
        var settings = json["settings"] as! [String: Any]
        let groupID = UUID()
        settings["stageDisplay"] = [
            "enabled": true,
            "panes": [
                ["kind": "program", "enabled": false, "rect": ["x": 0.0, "y": 0.0, "width": 0.2, "height": 0.2], "programGroupID": groupID.uuidString],
                ["kind": "program", "enabled": true, "rect": ["x": 0.4, "y": 0.4, "width": 0.3, "height": 0.3], "programGroupID": groupID.uuidString],
            ],
        ]
        json["settings"] = settings
        let data = try JSONSerialization.data(withJSONObject: json)

        let decoded = try ShowFile.load(from: data)
        let s = decoded.settings.stageDisplay
        XCTAssertEqual(s.programPanes.count, 1, "two entries for the same group collapse to one")
        XCTAssertEqual(s.programPane(forGroup: groupID)?.enabled, true, "last one wins")
        XCTAssertEqual(s.programPane(forGroup: groupID)?.rect, StageRect(x: 0.4, y: 0.4, width: 0.3, height: 0.3))
    }

    func testProgramPaneIDDistinguishesPanesByGroupNotJustKind() {
        let groupA = UUID()
        let groupB = UUID()
        let paneA = StageDisplayPane(kind: .program, enabled: true, rect: StageDisplayPane.defaultRect(for: .program), programGroupID: groupA)
        let paneB = StageDisplayPane(kind: .program, enabled: true, rect: StageDisplayPane.defaultRect(for: .program), programGroupID: groupB)
        XCTAssertNotEqual(paneA.id, paneB.id)
        XCTAssertEqual(paneA.id, "program-\(groupA.uuidString)")
    }

    func testNonProgramPaneIDIsJustTheKindRawValue() {
        let pane = StageDisplayPane(kind: .clock, enabled: true, rect: StageDisplayPane.defaultRect(for: .clock))
        XCTAssertEqual(pane.id, "clock")
    }

    // MARK: - StageDisplayController.programTargetID (D16 per-group derivation)

    func testProgramTargetIDIsDeterministicForTheSameGroup() {
        let groupID = UUID()
        XCTAssertEqual(StageDisplayController.programTargetID(for: groupID), StageDisplayController.programTargetID(for: groupID))
    }

    func testProgramTargetIDDiffersAcrossDifferentGroups() {
        let a = StageDisplayController.programTargetID(for: UUID())
        let b = StageDisplayController.programTargetID(for: UUID())
        XCTAssertNotEqual(a, b)
    }

    func testProgramTargetIDNeverEqualsItsOwnGroupID() {
        for _ in 0..<20 {
            let groupID = UUID()
            XCTAssertNotEqual(StageDisplayController.programTargetID(for: groupID), groupID)
        }
    }

    func testProgramTargetUsesTheDerivedIDAsAPreviewTarget() {
        let groupID = UUID()
        XCTAssertEqual(
            StageDisplayController.programTarget(for: groupID),
            .preview(id: StageDisplayController.programTargetID(for: groupID), title: "Stage Display")
        )
    }

    // MARK: - StageDisplayGeometry.appKitFrame (pure y-down -> y-up conversion)

    func testAppKitFrameConvertsTopLeftYDownRectToBottomLeftYUpFrame() {
        let rect = StageRect(x: 0.25, y: 0.1, width: 0.5, height: 0.2)
        let size = CGSize(width: 1000, height: 500)
        let frame = StageDisplayGeometry.appKitFrame(for: rect, in: size)
        XCTAssertEqual(frame.origin.x, 250, accuracy: 0.001)
        XCTAssertEqual(frame.width, 500, accuracy: 0.001)
        XCTAssertEqual(frame.height, 100, accuracy: 0.001)
        // rect.y = 0.1 (from the TOP) means the rect's top edge sits 50pt
        // down from the top (500 * 0.1); its bottom edge sits at 150pt down
        // from the top, i.e. 500 - 150 = 350pt UP from the bottom in
        // AppKit's y-up frame — the frame's origin.y.
        XCTAssertEqual(frame.origin.y, 350, accuracy: 0.001)
    }

    func testAppKitFrameFullBleedRectFillsContainer() {
        let rect = StageRect(x: 0, y: 0, width: 1, height: 1)
        let size = CGSize(width: 800, height: 450)
        let frame = StageDisplayGeometry.appKitFrame(for: rect, in: size)
        XCTAssertEqual(frame, CGRect(x: 0, y: 0, width: 800, height: 450))
    }

    func testAppKitFrameBottomAnchoredRectSitsAtOrigin() {
        // A pane touching the BOTTOM of the (y-down) model rect — y + height
        // == 1 — must land with frame.origin.y == 0 in the y-up frame.
        let rect = StageRect(x: 0, y: 0.8, width: 0.4, height: 0.2)
        let size = CGSize(width: 1000, height: 1000)
        let frame = StageDisplayGeometry.appKitFrame(for: rect, in: size)
        XCTAssertEqual(frame.origin.y, 0, accuracy: 0.001)
    }

    // MARK: - EnginePlayerProvider.extraTargets (D13 program-target injection, D16 multi-group)

    func testExtraTargetsIncludesProgramTargetWhenGroupIsInTheMirroredSet() {
        let group = OutputGroup(name: "Main")
        var settings = ShowSettings()
        settings.outputGroups = [group]
        let extra = EnginePlayerProvider.extraTargets(
            groupID: group.id, settings: settings,
            virtualCameraFeeding: false, stageDisplayProgramGroupIDs: [group.id]
        )
        XCTAssertTrue(extra.contains(StageDisplayController.programTarget(for: group.id)))
    }

    func testExtraTargetsExcludesProgramTargetForAGroupNotInTheMirroredSet() {
        let group = OutputGroup(name: "Main")
        let other = OutputGroup(name: "Other")
        var settings = ShowSettings()
        settings.outputGroups = [group, other]
        let extra = EnginePlayerProvider.extraTargets(
            groupID: group.id, settings: settings,
            virtualCameraFeeding: false, stageDisplayProgramGroupIDs: [other.id]
        )
        XCTAssertFalse(extra.contains(where: { $0 == StageDisplayController.programTarget(for: group.id) }))
    }

    func testExtraTargetsExcludesProgramTargetWhenMirroredSetIsEmpty() {
        let group = OutputGroup(name: "Main")
        var settings = ShowSettings()
        settings.outputGroups = [group]
        let extra = EnginePlayerProvider.extraTargets(
            groupID: group.id, settings: settings,
            virtualCameraFeeding: false, stageDisplayProgramGroupIDs: []
        )
        XCTAssertTrue(extra.isEmpty)
    }

    func testExtraTargetsExcludesProgramTargetWhenCueHasNoGroup() {
        let extra = EnginePlayerProvider.extraTargets(
            groupID: nil, settings: ShowSettings(),
            virtualCameraFeeding: false, stageDisplayProgramGroupIDs: [UUID()]
        )
        XCTAssertTrue(extra.isEmpty)
    }

    func testExtraTargetsCanIncludeBothVirtualCameraAndProgramTargetTogether() {
        let group = OutputGroup(name: "Main", virtualCamera: true)
        var settings = ShowSettings()
        settings.outputGroups = [group]
        let extra = EnginePlayerProvider.extraTargets(
            groupID: group.id, settings: settings,
            virtualCameraFeeding: true, stageDisplayProgramGroupIDs: [group.id]
        )
        XCTAssertTrue(extra.contains(VirtualCameraManager.monitorTarget))
        XCTAssertTrue(extra.contains(StageDisplayController.programTarget(for: group.id)))
        XCTAssertEqual(extra.count, 2)
    }

    // D16: a cue's group can be one of SEVERAL simultaneously mirrored groups.

    func testExtraTargetsGivesEachOfTwoMirroredGroupsOnlyItsOwnTarget() {
        let groupA = OutputGroup(name: "A")
        let groupB = OutputGroup(name: "B")
        var settings = ShowSettings()
        settings.outputGroups = [groupA, groupB]
        let mirrored: Set<UUID> = [groupA.id, groupB.id]

        let extraA = EnginePlayerProvider.extraTargets(
            groupID: groupA.id, settings: settings, virtualCameraFeeding: false, stageDisplayProgramGroupIDs: mirrored
        )
        XCTAssertEqual(extraA, [StageDisplayController.programTarget(for: groupA.id)])

        let extraB = EnginePlayerProvider.extraTargets(
            groupID: groupB.id, settings: settings, virtualCameraFeeding: false, stageDisplayProgramGroupIDs: mirrored
        )
        XCTAssertEqual(extraB, [StageDisplayController.programTarget(for: groupB.id)])
    }

    func testExtraTargetsExcludesProgramTargetForAThirdUnmirroredGroupEvenWithTwoOthersMirrored() {
        let groupA = OutputGroup(name: "A")
        let groupB = OutputGroup(name: "B")
        let groupC = OutputGroup(name: "C")
        var settings = ShowSettings()
        settings.outputGroups = [groupA, groupB, groupC]
        let extra = EnginePlayerProvider.extraTargets(
            groupID: groupC.id, settings: settings,
            virtualCameraFeeding: false, stageDisplayProgramGroupIDs: [groupA.id, groupB.id]
        )
        XCTAssertTrue(extra.isEmpty)
    }

    // MARK: - EnginePlayerProvider.floatingTarget (D14 floating-window group routing)

    func testFloatingTargetReturnsPreviewWhenGroupFloats() {
        let group = OutputGroup(name: "Prompter", floatingWindow: true)
        var settings = ShowSettings()
        settings.outputGroups = [group]
        let target = EnginePlayerProvider.floatingTarget(groupID: group.id, settings: settings)
        XCTAssertEqual(target, .preview(id: group.id, title: group.name))
    }

    func testFloatingTargetNilWhenGroupNotFloating() {
        let group = OutputGroup(name: "Main", floatingWindow: false)
        var settings = ShowSettings()
        settings.outputGroups = [group]
        XCTAssertNil(EnginePlayerProvider.floatingTarget(groupID: group.id, settings: settings))
    }

    func testFloatingTargetNilWhenGroupIDIsNil() {
        XCTAssertNil(EnginePlayerProvider.floatingTarget(groupID: nil, settings: ShowSettings()))
    }

    func testFloatingTargetNilWhenGroupDeleted() {
        XCTAssertNil(EnginePlayerProvider.floatingTarget(groupID: UUID(), settings: ShowSettings()))
    }

    // MARK: - StageDisplayController.isActive (pure decision, no window)

    func testIsActiveFalseInEditModeEvenWhenEverythingElseQualifies() {
        let settings = StageDisplaySettings(enabled: true, display: someFingerprint())
        XCTAssertFalse(StageDisplayController.isActive(mode: .edit, settings: settings, displayConnected: true))
    }

    func testIsActiveTrueInShowModeWhenEnabledAndConnected() {
        let settings = StageDisplaySettings(enabled: true, display: someFingerprint())
        XCTAssertTrue(StageDisplayController.isActive(mode: .show, settings: settings, displayConnected: true))
    }

    func testIsActiveTrueInRehearsalModeWhenEnabledAndConnected() {
        let settings = StageDisplaySettings(enabled: true, display: someFingerprint())
        XCTAssertTrue(StageDisplayController.isActive(mode: .rehearsal, settings: settings, displayConnected: true))
    }

    func testIsActiveFalseWhenDisplayDisconnected() {
        let settings = StageDisplaySettings(enabled: true, display: someFingerprint())
        XCTAssertFalse(StageDisplayController.isActive(mode: .show, settings: settings, displayConnected: false))
    }

    func testIsActiveFalseWhenNotEnabled() {
        let settings = StageDisplaySettings(enabled: false, display: someFingerprint())
        XCTAssertFalse(StageDisplayController.isActive(mode: .show, settings: settings, displayConnected: true))
    }

    // D14: Rehearsal's floating window needs no display at all — it doubles
    // as a layout preview while rigging. Show mode still requires one.
    func testIsActiveTrueInRehearsalModeWithNoDisplayChosen() {
        let settings = StageDisplaySettings(enabled: true, display: nil)
        XCTAssertTrue(StageDisplayController.isActive(mode: .rehearsal, settings: settings, displayConnected: false))
    }

    func testIsActiveFalseInShowModeWithNoDisplayChosen() {
        let settings = StageDisplaySettings(enabled: true, display: nil)
        XCTAssertFalse(StageDisplayController.isActive(mode: .show, settings: settings, displayConnected: false))
    }

    func testIsActiveFalseInRehearsalModeWhenNotEnabledEvenWithNoDisplay() {
        let settings = StageDisplaySettings(enabled: false, display: nil)
        XCTAssertFalse(StageDisplayController.isActive(mode: .rehearsal, settings: settings, displayConnected: false))
    }

    private func someFingerprint() -> DisplayFingerprint {
        DisplayFingerprint(name: "Test Display", pixelWidth: 1920, pixelHeight: 1080)
    }

    // MARK: - StageDisplayFormat.wallClock

    func testWallClockFormatsZeroPaddedHHMMSS() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 8, day: 29, hour: 9, minute: 5, second: 3))!
        XCTAssertEqual(StageDisplayFormat.wallClock(date, calendar: calendar), "09:05:03")
    }

    func testWallClockFormatsMidday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 8, day: 29, hour: 23, minute: 59, second: 59))!
        XCTAssertEqual(StageDisplayFormat.wallClock(date, calendar: calendar), "23:59:59")
    }

    // MARK: - StageDisplayFormat.elapsed (show timer)

    func testElapsedFormatsZeroAtStart() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(StageDisplayFormat.elapsed(from: start, to: start), "00:00:00")
    }

    func testElapsedFormatsHoursMinutesSeconds() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let now = start.addingTimeInterval(2 * 3600 + 5 * 60 + 9)
        XCTAssertEqual(StageDisplayFormat.elapsed(from: start, to: now), "02:05:09")
    }

    func testElapsedClampsNegativeToZero() {
        // `now` before `start` shouldn't happen, but must not go negative.
        let start = Date(timeIntervalSince1970: 1_000_000)
        let now = start.addingTimeInterval(-5)
        XCTAssertEqual(StageDisplayFormat.elapsed(from: start, to: now), "00:00:00")
    }

    // MARK: - StageDisplayFormat.remaining (mm:ss vs infinity)

    func testRemainingReturnsInfinityForNilDuration() {
        XCTAssertEqual(StageDisplayFormat.remaining(duration: nil, elapsed: 0, infiniteLoop: false), "∞")
    }

    func testRemainingReturnsInfinityForInfiniteLoopEvenWithKnownDuration() {
        XCTAssertEqual(StageDisplayFormat.remaining(duration: 30, elapsed: 5, infiniteLoop: true), "∞")
    }

    func testRemainingFormatsMinutesAndSeconds() {
        XCTAssertEqual(StageDisplayFormat.remaining(duration: 125, elapsed: 5, infiniteLoop: false), "2:00")
    }

    func testRemainingFormatsUnderOneMinuteWithZeroMinutes() {
        XCTAssertEqual(StageDisplayFormat.remaining(duration: 30, elapsed: 12, infiniteLoop: false), "0:18")
    }

    func testRemainingClampsToZeroPastDuration() {
        XCTAssertEqual(StageDisplayFormat.remaining(duration: 10, elapsed: 15, infiniteLoop: false), "0:00")
    }

    func testRemainingTreatsNilElapsedAsZero() {
        XCTAssertEqual(StageDisplayFormat.remaining(duration: 65, elapsed: nil, infiniteLoop: false), "1:05")
    }

    // MARK: - StageDisplayFormat.isInfiniteLoop

    func testIsInfiniteLoopTrueForLoopingAudio() {
        let cue = Cue(number: "1", body: .audio(AudioBody(media: MediaReference(absolutePath: "/fake/1.wav"), infiniteLoop: true)))
        XCTAssertTrue(StageDisplayFormat.isInfiniteLoop(cue))
    }

    func testIsInfiniteLoopFalseForNonLoopingAudio() {
        let cue = Cue(number: "1", body: .audio(AudioBody(media: MediaReference(absolutePath: "/fake/1.wav"), infiniteLoop: false)))
        XCTAssertFalse(StageDisplayFormat.isInfiniteLoop(cue))
    }

    func testIsInfiniteLoopTrueForLoopingVideo() {
        let cue = Cue(number: "1", body: .video(VideoBody(media: MediaReference(absolutePath: "/fake/1.mov"), infiniteLoop: true)))
        XCTAssertTrue(StageDisplayFormat.isInfiniteLoop(cue))
    }

    func testIsInfiniteLoopFalseForOtherCueTypes() {
        let cue = Cue(number: "1", body: .stop(StopBody()))
        XCTAssertFalse(StageDisplayFormat.isInfiniteLoop(cue))
    }

    // MARK: - TransportController.isPlayheadPastEnd

    func testIsPlayheadPastEndFalseWithEmptyShow() {
        let app = AppModel()
        XCTAssertFalse(app.transport.isPlayheadPastEnd)
        XCTAssertNil(app.transport.standingByCue, "no cues at all: nothing standing by, but NOT past-end")
    }

    func testIsPlayheadPastEndTrueAfterGoingPastTheLastCue() {
        let app = AppModel()
        let cue = Cue(number: "1", body: .audio(AudioBody(media: MediaReference(absolutePath: "/fake/1.wav"))))
        app.document.mutate { $0.cues = [cue] }
        app.transport.setPlayhead(cue.id)
        app.transport.go()
        app.transport.go()   // past the last cue: GO goes dead
        XCTAssertTrue(app.transport.isPlayheadPastEnd)
        XCTAssertNil(app.transport.standingByCue)
    }

    // MARK: - AppModel wiring: syncStageDisplay via updateStageDisplay

    func testUpdateStageDisplayPersistsSettingsIntoTheDocument() {
        let app = AppModel()
        let fingerprint = someFingerprint()
        app.updateStageDisplay { settings in
            settings.enabled = true
            settings.display = fingerprint
            if let idx = settings.panes.firstIndex(where: { $0.kind == .notes }) {
                settings.panes[idx].enabled = false
            }
        }
        XCTAssertTrue(app.document.show.settings.stageDisplay.enabled)
        XCTAssertEqual(app.document.show.settings.stageDisplay.display, fingerprint)
        XCTAssertFalse(app.document.show.settings.stageDisplay.pane(.notes).enabled)
    }

    // MARK: - D17: CueBody.outputGroupID (single extraction point for the live-mirror diff)

    func testCueBodyOutputGroupIDForEveryVisualKind() {
        let groupID = UUID()
        XCTAssertEqual(CueBody.video(VideoBody(media: MediaReference(absolutePath: "/f.mov"), outputGroupID: groupID)).outputGroupID, groupID)
        XCTAssertEqual(CueBody.camera(CameraBody(outputGroupID: groupID)).outputGroupID, groupID)
        XCTAssertEqual(CueBody.image(ImageBody(media: MediaReference(absolutePath: "/f.png"), outputGroupID: groupID)).outputGroupID, groupID)
        XCTAssertEqual(CueBody.text(TextBody(rtf: Data(), outputGroupID: groupID)).outputGroupID, groupID)
        XCTAssertEqual(CueBody.slide(SlideBody(media: MediaReference(absolutePath: "/f.png"), outputGroupID: groupID)).outputGroupID, groupID)
    }

    func testCueBodyOutputGroupIDNilForEveryNonVisualKindAndUnassignedVisualCues() {
        XCTAssertNil(CueBody.audio(AudioBody(media: MediaReference(absolutePath: "/f.wav"))).outputGroupID)
        XCTAssertNil(CueBody.fade(FadeBody()).outputGroupID)
        XCTAssertNil(CueBody.stop(StopBody()).outputGroupID)
        XCTAssertNil(CueBody.group(GroupBody()).outputGroupID)
        XCTAssertNil(CueBody.broken(BrokenBody(originalType: "hologram")).outputGroupID)
        // A visual cue with no group assigned yet — nil, not a crash.
        XCTAssertNil(CueBody.video(VideoBody(media: MediaReference(absolutePath: "/f.mov"))).outputGroupID)
    }

    // MARK: - D17: AppModel.mirrorAttachDiff (pure live mirror attach/detach decision)

    func testMirrorAttachDiffAttachesCandidatesOfAGroupThatEnteredTheSet() {
        let group = UUID()
        let instance = UUID()
        let diff = AppModel.mirrorAttachDiff(
            previousGroupIDs: [],
            currentGroupIDs: [group],
            candidates: [AppModel.MirrorCandidate(instanceID: instance, groupID: group)]
        )
        XCTAssertEqual(diff.attach, [AppModel.MirrorCandidate(instanceID: instance, groupID: group)])
        XCTAssertTrue(diff.detach.isEmpty)
    }

    func testMirrorAttachDiffDetachesCandidatesOfAGroupThatLeftTheSet() {
        let group = UUID()
        let instance = UUID()
        let diff = AppModel.mirrorAttachDiff(
            previousGroupIDs: [group],
            currentGroupIDs: [],
            candidates: [AppModel.MirrorCandidate(instanceID: instance, groupID: group)]
        )
        XCTAssertTrue(diff.attach.isEmpty)
        XCTAssertEqual(diff.detach, [AppModel.MirrorCandidate(instanceID: instance, groupID: group)])
    }

    func testMirrorAttachDiffIgnoresAGroupPresentInBothSets() {
        // The mirrored set is unchanged (e.g. a program pane's rect-only
        // drag) — no churn even though a candidate exists on that group.
        let group = UUID()
        let instance = UUID()
        let diff = AppModel.mirrorAttachDiff(
            previousGroupIDs: [group],
            currentGroupIDs: [group],
            candidates: [AppModel.MirrorCandidate(instanceID: instance, groupID: group)]
        )
        XCTAssertTrue(diff.attach.isEmpty)
        XCTAssertTrue(diff.detach.isEmpty)
    }

    func testMirrorAttachDiffIgnoresCandidatesOfAnUnrelatedGroup() {
        // groupA enters the set, but the only running candidate is on groupB.
        let groupA = UUID()
        let groupB = UUID()
        let instance = UUID()
        let diff = AppModel.mirrorAttachDiff(
            previousGroupIDs: [],
            currentGroupIDs: [groupA],
            candidates: [AppModel.MirrorCandidate(instanceID: instance, groupID: groupB)]
        )
        XCTAssertTrue(diff.attach.isEmpty)
        XCTAssertTrue(diff.detach.isEmpty)
    }

    func testMirrorAttachDiffHandlesSeveralGroupsChangingAtOnceIndependently() {
        let entering = UUID()
        let leaving = UUID()
        let unrelated = UUID()
        let enteringInstance = UUID()
        let leavingInstance = UUID()
        let unrelatedInstance = UUID()
        let diff = AppModel.mirrorAttachDiff(
            previousGroupIDs: [leaving, unrelated],
            currentGroupIDs: [entering, unrelated],
            candidates: [
                AppModel.MirrorCandidate(instanceID: enteringInstance, groupID: entering),
                AppModel.MirrorCandidate(instanceID: leavingInstance, groupID: leaving),
                AppModel.MirrorCandidate(instanceID: unrelatedInstance, groupID: unrelated),
            ]
        )
        XCTAssertEqual(diff.attach, [AppModel.MirrorCandidate(instanceID: enteringInstance, groupID: entering)])
        XCTAssertEqual(diff.detach, [AppModel.MirrorCandidate(instanceID: leavingInstance, groupID: leaving)])
    }

    func testMirrorAttachDiffNoOpWhenSetsAreIdentical() {
        // Stage-display close-then-immediately-reopen with nothing mirrored,
        // or any resync where nothing actually changed.
        let diff = AppModel.mirrorAttachDiff(previousGroupIDs: [], currentGroupIDs: [], candidates: [])
        XCTAssertTrue(diff.attach.isEmpty)
        XCTAssertTrue(diff.detach.isEmpty)
    }

    func testMirrorAttachDiffDetachesEveryMirroredGroupOnStageDisplayClose() {
        // `syncMirrorAttachments` calls this with an EMPTY current set on
        // close — every group that was mirrored must detach.
        let groupA = UUID()
        let groupB = UUID()
        let instanceA = UUID()
        let instanceB = UUID()
        let diff = AppModel.mirrorAttachDiff(
            previousGroupIDs: [groupA, groupB],
            currentGroupIDs: [],
            candidates: [
                AppModel.MirrorCandidate(instanceID: instanceA, groupID: groupA),
                AppModel.MirrorCandidate(instanceID: instanceB, groupID: groupB),
            ]
        )
        XCTAssertTrue(diff.attach.isEmpty)
        XCTAssertEqual(Set(diff.detach), Set([
            AppModel.MirrorCandidate(instanceID: instanceA, groupID: groupA),
            AppModel.MirrorCandidate(instanceID: instanceB, groupID: groupB),
        ]))
    }

    // MARK: - D17: StageDisplayController.fullscreenCoversOperatorScreen

    func testFullscreenCoversOperatorScreenTrueWhenIDsMatch() {
        XCTAssertTrue(StageDisplayController.fullscreenCoversOperatorScreen(matchedDisplayID: 42, operatorScreenDisplayID: 42))
    }

    func testFullscreenCoversOperatorScreenFalseWhenIDsDiffer() {
        XCTAssertFalse(StageDisplayController.fullscreenCoversOperatorScreen(matchedDisplayID: 42, operatorScreenDisplayID: 7))
    }

    func testFullscreenCoversOperatorScreenFalseWhenEitherIDIsNil() {
        XCTAssertFalse(StageDisplayController.fullscreenCoversOperatorScreen(matchedDisplayID: nil, operatorScreenDisplayID: 42))
        XCTAssertFalse(StageDisplayController.fullscreenCoversOperatorScreen(matchedDisplayID: 42, operatorScreenDisplayID: nil))
        XCTAssertFalse(StageDisplayController.fullscreenCoversOperatorScreen(matchedDisplayID: nil, operatorScreenDisplayID: nil))
    }

    // MARK: - D18 (FIX 1): StageDisplayController.presentationStyle

    func testPresentationStyleShowModeOtherScreenIsFullscreen() {
        XCTAssertEqual(
            StageDisplayController.presentationStyle(mode: .show, matchedScreenIsOperatorScreen: false, operatorScreenKnown: true),
            .fullscreen
        )
    }

    func testPresentationStyleShowModeOperatorScreenIsFloating() {
        XCTAssertEqual(
            StageDisplayController.presentationStyle(mode: .show, matchedScreenIsOperatorScreen: true, operatorScreenKnown: true),
            .floating
        )
    }

    func testPresentationStyleShowModeUnknownOperatorScreenIsFloating() {
        // D18: the exact launch-restore trap — at launch, the main window
        // may not exist yet when `sync` first runs, so the operator screen
        // can't be resolved. The safe default is floating, never fullscreen.
        XCTAssertEqual(
            StageDisplayController.presentationStyle(mode: .show, matchedScreenIsOperatorScreen: false, operatorScreenKnown: false),
            .floating
        )
    }

    func testPresentationStyleShowModeOperatorScreenAndUnknownTogetherIsFloating() {
        XCTAssertEqual(
            StageDisplayController.presentationStyle(mode: .show, matchedScreenIsOperatorScreen: true, operatorScreenKnown: false),
            .floating
        )
    }

    func testPresentationStyleRehearsalIsAlwaysFloatingRegardlessOfOperatorScreen() {
        for matched in [true, false] {
            for known in [true, false] {
                XCTAssertEqual(
                    StageDisplayController.presentationStyle(mode: .rehearsal, matchedScreenIsOperatorScreen: matched, operatorScreenKnown: known),
                    .floating,
                    "rehearsal is unconditionally floating (matched: \(matched), known: \(known))"
                )
            }
        }
    }

    // MARK: - D19: content container is layer-backed synchronously at construction (suspect 1)

    /// Pins the invariant `syncProgramPanes`' registration guard depends on:
    /// the container's backing layer must already exist the instant
    /// `makeContentContainer` returns — no window, no display pass. If this
    /// invariant were ever lost, `syncProgramPanes` would hit its nil-layer
    /// guard on EVERY sync, register no external host for any program pane,
    /// forever, with no visible error — exactly what the D19 bug report
    /// described (program panes showing only their placeholder). Calling
    /// with `appModel: nil` deliberately builds no SwiftUI content, so this
    /// stays a pure, dependency-free check with still no window shown —
    /// consistent with this file's "creates no windows" rule above.
    func testContentContainerIsLayerBackedImmediatelyAtConstruction() {
        let (container, panicLayer) = StageDisplayController.makeContentContainer(
            size: CGSize(width: 400, height: 300), appModel: nil
        )
        XCTAssertTrue(container.wantsLayer, "wantsLayer must be set at construction, before any sync can run")
        XCTAssertNotNil(container.layer, "backing layer must exist synchronously — no window, no display pass")
        XCTAssertNil(panicLayer, "no appModel passed in => no SwiftUI content/panic overlay built")
    }
}
