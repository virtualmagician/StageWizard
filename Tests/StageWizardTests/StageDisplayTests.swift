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
        XCTAssertTrue(settings.showsClock)
        XCTAssertTrue(settings.showsShowTimer)
        XCTAssertTrue(settings.showsNotes)
        XCTAssertTrue(settings.showsRunning)
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
        show.settings.stageDisplay.showsNotes = false
        var json = try JSONSerialization.jsonObject(with: show.encoded()) as! [String: Any]
        var settings = json["settings"] as! [String: Any]
        settings.removeValue(forKey: "stageDisplay")
        json["settings"] = settings
        let stripped = try JSONSerialization.data(withJSONObject: json)

        let decoded = try ShowFile.load(from: stripped)
        XCTAssertFalse(decoded.settings.stageDisplay.enabled, "pre-D9 files predate the stage display")
        XCTAssertTrue(decoded.settings.stageDisplay.showsClock)
        XCTAssertTrue(decoded.settings.stageDisplay.showsShowTimer)
        XCTAssertTrue(decoded.settings.stageDisplay.showsNotes)
        XCTAssertTrue(decoded.settings.stageDisplay.showsRunning)
    }

    func testStageDisplaySettingsWithPartialKeysFillsMissingFieldsWithDefaults() throws {
        // Simulates a hand-edited/older-minor-version file that has the
        // `stageDisplay` object but predates one of its inner fields.
        var show = ShowFile()
        show.settings.stageDisplay.enabled = true
        var json = try JSONSerialization.jsonObject(with: show.encoded()) as! [String: Any]
        var settings = json["settings"] as! [String: Any]
        var stageDisplay = settings["stageDisplay"] as! [String: Any]
        stageDisplay.removeValue(forKey: "showsRunning")
        settings["stageDisplay"] = stageDisplay
        json["settings"] = settings
        let data = try JSONSerialization.data(withJSONObject: json)

        let decoded = try ShowFile.load(from: data)
        XCTAssertTrue(decoded.settings.stageDisplay.enabled)
        XCTAssertTrue(decoded.settings.stageDisplay.showsRunning, "missing inner key defaults to true")
    }

    // MARK: - Codable: full round-trip with a fingerprint

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
        show.settings.stageDisplay = StageDisplaySettings(
            enabled: true,
            display: fingerprint,
            showsClock: false,
            showsShowTimer: true,
            showsNotes: false,
            showsRunning: true
        )

        let decoded = try ShowFile.load(from: show.encoded())
        XCTAssertEqual(decoded.settings.stageDisplay.enabled, true)
        XCTAssertEqual(decoded.settings.stageDisplay.display, fingerprint)
        XCTAssertEqual(decoded.settings.stageDisplay.showsClock, false)
        XCTAssertEqual(decoded.settings.stageDisplay.showsShowTimer, true)
        XCTAssertEqual(decoded.settings.stageDisplay.showsNotes, false)
        XCTAssertEqual(decoded.settings.stageDisplay.showsRunning, true)
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
            settings.showsNotes = false
        }
        XCTAssertTrue(app.document.show.settings.stageDisplay.enabled)
        XCTAssertEqual(app.document.show.settings.stageDisplay.display, fingerprint)
        XCTAssertFalse(app.document.show.settings.stageDisplay.showsNotes)
    }
}
