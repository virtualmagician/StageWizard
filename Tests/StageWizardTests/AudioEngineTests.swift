import AVFoundation
import XCTest

@testable import StageWizard

/// AudioEngineKit tests. These exercise the REAL signal path (HAL devices,
/// AVAudioEngine, pooled player nodes) on the default output device at -50 dB
/// so runs stay effectively inaudible. All timings use generous tolerances —
/// .dataPlayedBack completions include output-device latency.
@MainActor
final class AudioEngineTests: XCTestCase {

    private static let testMediaDir = URL(
        fileURLWithPath: "/Users/marcotempest/Library/CloudStorage/Dropbox-Newmagic/Marco Tempest/StageWizard/TestMedia"
    )

    private var toneURL: URL {
        Self.testMediaDir.appendingPathComponent("tone-440-10s.wav")
    }

    private func toneBody(
        startTime: TimeInterval = 0,
        endTime: TimeInterval? = nil,
        playCount: Int = 1,
        infiniteLoop: Bool = false,
        volumeDB: Double = -50,
        fadeInDuration: TimeInterval = 0,
        fadeOutDuration: TimeInterval = 0,
        outputDeviceUID: String? = nil
    ) -> AudioBody {
        AudioBody(
            media: MediaReference(absolutePath: toneURL.path),
            startTime: startTime,
            endTime: endTime,
            playCount: playCount,
            infiniteLoop: infiniteLoop,
            volumeDB: volumeDB,
            fadeInDuration: fadeInDuration,
            fadeOutDuration: fadeOutDuration,
            outputDeviceUID: outputDeviceUID
        )
    }

    private func isNatural(_ reason: PlaybackEndReason?) -> Bool {
        if case .natural = reason { return true }
        return false
    }

    private func isStopped(_ reason: PlaybackEndReason?) -> Bool {
        if case .stopped = reason { return true }
        return false
    }

    // MARK: - Device enumeration

    func testDeviceEnumerationAndUIDResolution() {
        let manager = AudioDeviceManager.shared
        XCTAssertGreaterThanOrEqual(manager.outputDevices.count, 1, "no output devices found")
        for device in manager.outputDevices {
            XCTAssertFalse(device.uid.isEmpty)
            XCTAssertFalse(device.name.isEmpty)
            XCTAssertGreaterThan(device.channelCount, 0)
            XCTAssertEqual(
                manager.deviceID(forUID: device.uid), device.deviceID,
                "UID '\(device.uid)' did not round-trip to its AudioDeviceID"
            )
        }
        XCTAssertNotNil(manager.defaultOutputDevice, "no default output device")
        XCTAssertNil(manager.deviceID(forUID: "definitely-not-a-real-device-uid"))
    }

    // MARK: - Trim + natural end

    func testTrimmedPlaybackFinishesNaturallyAfterOneSecond() async throws {
        let body = toneBody(startTime: 1.0, endTime: 2.0)
        let player = try await AudioCuePlayer.arm(body: body, fileURL: toneURL)
        XCTAssertNil(player.routingWarning)
        XCTAssertEqual(player.duration ?? 0, 1.0, accuracy: 0.01)

        let finishExpectation = expectation(description: "natural finish")
        var reason: PlaybackEndReason?
        player.onFinished = { r in
            reason = r
            finishExpectation.fulfill()
        }

        let startedAt = Date()
        player.start()

        // currentTime maps back into media time (trim offset accounted for).
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(player.currentTime, 1.4, accuracy: 0.2)

        await fulfillment(of: [finishExpectation], timeout: 10)
        let elapsed = Date().timeIntervalSince(startedAt)
        XCTAssertTrue(isNatural(reason), "expected .natural, got \(String(describing: reason))")
        XCTAssertEqual(elapsed, 1.0, accuracy: 0.35, "trimmed 1s cue took \(elapsed)s")
    }

    // MARK: - playCount looping

    func testPlayCountTwoFinishesAfterTwoPasses() async throws {
        let body = toneBody(startTime: 1.0, endTime: 1.5, playCount: 2)
        let player = try await AudioCuePlayer.arm(body: body, fileURL: toneURL)

        let finishExpectation = expectation(description: "natural finish after 2 passes")
        var reason: PlaybackEndReason?
        player.onFinished = { r in
            reason = r
            finishExpectation.fulfill()
        }

        let startedAt = Date()
        player.start()
        await fulfillment(of: [finishExpectation], timeout: 10)
        let elapsed = Date().timeIntervalSince(startedAt)
        XCTAssertTrue(isNatural(reason))
        XCTAssertEqual(elapsed, 1.0, accuracy: 0.35, "2 × 0.5s passes took \(elapsed)s")
    }

    // MARK: - exitLoop

    func testExitLoopEndsInfiniteLoopAfterQueuedPasses() async throws {
        let body = toneBody(startTime: 1.0, endTime: 1.5, infiniteLoop: true)
        let player = try await AudioCuePlayer.arm(body: body, fileURL: toneURL)

        let finishExpectation = expectation(description: "loop exit finish")
        var reason: PlaybackEndReason?
        player.onFinished = { r in
            reason = r
            finishExpectation.fulfill()
        }

        let startedAt = Date()
        player.start()
        try await Task.sleep(for: .milliseconds(200))
        player.exitLoop()

        await fulfillment(of: [finishExpectation], timeout: 10)
        let elapsed = Date().timeIntervalSince(startedAt)
        XCTAssertTrue(isNatural(reason), "loop exit should finish naturally")
        // Current pass finishes (0.5s boundary) plus the one pass kept queued
        // ahead for gaplessness → expected end ≈ 1.0s; never immediate.
        XCTAssertGreaterThanOrEqual(elapsed, 0.45, "exitLoop must let the current pass finish")
        XCTAssertLessThanOrEqual(elapsed, 2.0, "exitLoop took too long (\(elapsed)s)")
    }

    // MARK: - stop() idempotency

    func testStopFiresOnFinishedExactlyOnce() async throws {
        let body = toneBody(startTime: 1.0, endTime: 5.0)
        let player = try await AudioCuePlayer.arm(body: body, fileURL: toneURL)

        let finishExpectation = expectation(description: "stopped finish")
        var finishCount = 0
        var reason: PlaybackEndReason?
        player.onFinished = { r in
            finishCount += 1
            reason = r
            finishExpectation.fulfill()
        }

        player.start()
        try await Task.sleep(for: .milliseconds(150))
        player.stop()
        player.stop() // double-stop must be safe
        await fulfillment(of: [finishExpectation], timeout: 2)

        // Grace period: node.stop() flushes scheduled segments and fires their
        // completions — none of them may produce a second onFinished.
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(finishCount, 1)
        XCTAssertTrue(isStopped(reason), "expected .stopped, got \(String(describing: reason))")
    }

    // MARK: - Fade to silence, then stop (no-click invariant)

    func testFadeToSilenceFloorThenStopReachesExactZeroBeforeStop() async throws {
        let body = toneBody(startTime: 0, endTime: 8.0)
        let player = try await AudioCuePlayer.arm(body: body, fileURL: toneURL)
        player.start()
        try await Task.sleep(for: .milliseconds(100))

        let finishExpectation = expectation(description: "fade-out stop")
        var reason: PlaybackEndReason?
        var volumeAtFinish: Float = -1
        var volumeDBAtFinish: Double = .nan
        player.onFinished = { r in
            reason = r
            // finish() has already run: the FadeClock applied exactly the
            // silence floor (amplitude 0.0) BEFORE its completion stopped the
            // node, and nothing may have moved the level since.
            volumeAtFinish = player.node.volume
            volumeDBAtFinish = player.currentVolumeDB
            finishExpectation.fulfill()
        }

        player.fadeVolume(toDB: silenceFloorDB, duration: 0.4, curve: .dbLinear, thenStop: true)
        await fulfillment(of: [finishExpectation], timeout: 5)

        XCTAssertTrue(isStopped(reason), "thenStop fade should end .stopped")
        XCTAssertEqual(volumeAtFinish, 0.0, "node volume must be exactly 0.0 at stop")
        XCTAssertEqual(volumeDBAtFinish, silenceFloorDB, "player must report the silence floor")
    }

    // MARK: - Fade math

    func testSilenceFloorMapsToExactlyZeroAmplitude() {
        XCTAssertEqual(FadeCurve.amplitude(fromDB: silenceFloorDB), 0.0)
        XCTAssertEqual(FadeCurve.amplitude(fromDB: silenceFloorDB - 40), 0.0)
        XCTAssertEqual(FadeCurve.dB(fromAmplitude: 0), silenceFloorDB)
        XCTAssertEqual(FadeCurve.amplitude(fromDB: 0), 1.0, accuracy: 1e-12)
    }

    // MARK: - Edge fades

    func testAuthoredFadeInArmsAtSilenceAndRampsToCueVolume() async throws {
        let body = toneBody(startTime: 1.0, endTime: 2.0, fadeInDuration: 0.3)
        let player = try await AudioCuePlayer.arm(body: body, fileURL: toneURL)
        // Armed at silence: exactly amplitude 0 until GO.
        XCTAssertEqual(player.node.volume, 0.0)
        XCTAssertEqual(player.currentVolumeDB, silenceFloorDB)

        let finishExpectation = expectation(description: "natural finish")
        player.onFinished = { _ in finishExpectation.fulfill() }
        player.start()
        try await Task.sleep(for: .milliseconds(600))
        // Fade-in (0.3s) is over; level should now sit at the cue volume.
        XCTAssertEqual(player.currentVolumeDB, -50, accuracy: 0.5)
        await fulfillment(of: [finishExpectation], timeout: 5)
    }

    func testAuthoredFadeOutReachesSilenceBeforeNaturalEnd() async throws {
        let body = toneBody(startTime: 1.0, endTime: 2.0, fadeOutDuration: 0.4)
        let player = try await AudioCuePlayer.arm(body: body, fileURL: toneURL)

        let finishExpectation = expectation(description: "natural finish")
        var reason: PlaybackEndReason?
        var volumeAtFinish: Float = -1
        player.onFinished = { r in
            reason = r
            volumeAtFinish = player.node.volume
            finishExpectation.fulfill()
        }

        player.start()
        await fulfillment(of: [finishExpectation], timeout: 5)
        XCTAssertTrue(isNatural(reason))
        // The edge fade ramped to the silence floor before the out-point.
        XCTAssertEqual(volumeAtFinish, 0.0, "edge fade-out must land on exactly 0.0")
    }

    // MARK: - Routing fallback

    func testUnresolvableDeviceUIDFallsBackToDefaultWithWarning() async throws {
        let body = toneBody(startTime: 1.0, endTime: 1.2, outputDeviceUID: "ghost-device-uid-42")
        let player = try await AudioCuePlayer.arm(body: body, fileURL: toneURL)
        XCTAssertNotNil(player.routingWarning)
        XCTAssertEqual(player.routingWarning?.requestedUID, "ghost-device-uid-42")
        player.stop() // release the pooled node
    }

    // MARK: - Pause / resume position

    func testPauseFreezesCurrentTimeAndResumeContinues() async throws {
        let body = toneBody(startTime: 1.0, endTime: 3.0)
        let player = try await AudioCuePlayer.arm(body: body, fileURL: toneURL)
        player.start()
        try await Task.sleep(for: .milliseconds(300))

        player.pause()
        XCTAssertTrue(player.isPaused)
        let frozen = player.currentTime
        XCTAssertEqual(frozen, 1.3, accuracy: 0.2)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(player.currentTime, frozen, "currentTime must not advance while paused")

        player.resume()
        XCTAssertFalse(player.isPaused)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertGreaterThan(player.currentTime, frozen + 0.1, "currentTime must advance after resume")
        player.stop()
    }
}
