import XCTest
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
        XCTAssertNil(settings.programGroupID)
        XCTAssertEqual(settings.panes.count, StageDisplayPaneKind.allCases.count)
        XCTAssertTrue(settings.pane(.clock).enabled)
        XCTAssertTrue(settings.pane(.showTimer).enabled)
        XCTAssertTrue(settings.pane(.standingBy).enabled)
        XCTAssertTrue(settings.pane(.notes).enabled)
        XCTAssertTrue(settings.pane(.running).enabled)
        XCTAssertFalse(settings.pane(.program).enabled, "program view is off by default — no group chosen yet")
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
        XCTAssertEqual(decoded.settings.stageDisplay.panes.count, StageDisplayPaneKind.allCases.count)
        XCTAssertTrue(decoded.settings.stageDisplay.pane(.clock).enabled)
        XCTAssertTrue(decoded.settings.stageDisplay.pane(.showTimer).enabled)
        XCTAssertTrue(decoded.settings.stageDisplay.pane(.standingBy).enabled)
        XCTAssertTrue(decoded.settings.stageDisplay.pane(.notes).enabled)
        XCTAssertTrue(decoded.settings.stageDisplay.pane(.running).enabled)
        XCTAssertFalse(decoded.settings.stageDisplay.pane(.program).enabled, "program view is brand new — off by default")
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
        XCTAssertEqual(s.panes.count, StageDisplayPaneKind.allCases.count, "every kind present exactly once")
        XCTAssertFalse(s.pane(.clock).enabled)
        XCTAssertEqual(s.pane(.clock).rect, StageRect(x: 0, y: 0, width: 0.2, height: 0.1))
        XCTAssertTrue(s.pane(.showTimer).enabled, "missing kind filled in with its default")
        XCTAssertEqual(s.pane(.showTimer).rect, StageDisplayPane.defaultRect(for: .showTimer))
        XCTAssertFalse(s.pane(.program).enabled)
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
        if let idx = settings.panes.firstIndex(where: { $0.kind == .program }) {
            settings.panes[idx].enabled = true
            settings.panes[idx].rect = StageRect(x: 0.1, y: 0.2, width: 0.3, height: 0.25)
        }
        let groupID = UUID()
        settings.programGroupID = groupID
        show.settings.stageDisplay = settings

        let decoded = try ShowFile.load(from: show.encoded())
        XCTAssertEqual(decoded.settings.stageDisplay.panes.count, StageDisplayPaneKind.allCases.count)
        XCTAssertTrue(decoded.settings.stageDisplay.pane(.program).enabled)
        XCTAssertEqual(decoded.settings.stageDisplay.pane(.program).rect, StageRect(x: 0.1, y: 0.2, width: 0.3, height: 0.25))
        XCTAssertEqual(decoded.settings.stageDisplay.programGroupID, groupID)
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

    // MARK: - EnginePlayerProvider.extraTargets (D13 program-target injection)

    func testExtraTargetsIncludesProgramTargetWhenGroupMatchesStageDisplayProgramGroup() {
        let group = OutputGroup(name: "Main")
        var settings = ShowSettings()
        settings.outputGroups = [group]
        let extra = EnginePlayerProvider.extraTargets(
            groupID: group.id, settings: settings,
            virtualCameraFeeding: false, stageDisplayProgramGroupID: group.id
        )
        XCTAssertTrue(extra.contains(StageDisplayController.programTarget))
    }

    func testExtraTargetsExcludesProgramTargetForADifferentGroup() {
        let group = OutputGroup(name: "Main")
        let other = OutputGroup(name: "Other")
        var settings = ShowSettings()
        settings.outputGroups = [group, other]
        let extra = EnginePlayerProvider.extraTargets(
            groupID: group.id, settings: settings,
            virtualCameraFeeding: false, stageDisplayProgramGroupID: other.id
        )
        XCTAssertFalse(extra.contains(StageDisplayController.programTarget))
    }

    func testExtraTargetsExcludesProgramTargetWhenStageDisplayProgramGroupIDIsNil() {
        let group = OutputGroup(name: "Main")
        var settings = ShowSettings()
        settings.outputGroups = [group]
        let extra = EnginePlayerProvider.extraTargets(
            groupID: group.id, settings: settings,
            virtualCameraFeeding: false, stageDisplayProgramGroupID: nil
        )
        XCTAssertTrue(extra.isEmpty)
    }

    func testExtraTargetsExcludesProgramTargetWhenCueHasNoGroup() {
        let extra = EnginePlayerProvider.extraTargets(
            groupID: nil, settings: ShowSettings(),
            virtualCameraFeeding: false, stageDisplayProgramGroupID: UUID()
        )
        XCTAssertTrue(extra.isEmpty)
    }

    func testExtraTargetsCanIncludeBothVirtualCameraAndProgramTargetTogether() {
        let group = OutputGroup(name: "Main", virtualCamera: true)
        var settings = ShowSettings()
        settings.outputGroups = [group]
        let extra = EnginePlayerProvider.extraTargets(
            groupID: group.id, settings: settings,
            virtualCameraFeeding: true, stageDisplayProgramGroupID: group.id
        )
        XCTAssertTrue(extra.contains(VirtualCameraManager.monitorTarget))
        XCTAssertTrue(extra.contains(StageDisplayController.programTarget))
        XCTAssertEqual(extra.count, 2)
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
}
