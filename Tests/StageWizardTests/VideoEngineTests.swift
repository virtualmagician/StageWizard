import XCTest
import AVFoundation
import AppKit
@testable import StageWizard

/// Video engine tests run against real AVFoundation playback in the hosted
/// test app (the host provides the main run loop). Output windows use a small
/// frame override instead of covering the operator's screen, and all audible
/// cues play at -50 dB — a real signal path, barely audible.
@MainActor
final class VideoEngineTests: XCTestCase {

    private static let identURL = URL(fileURLWithPath:
        "/Users/marcotempest/Library/CloudStorage/Dropbox-Newmagic/Marco Tempest/StageWizard/TestMedia/ident-5s.mov")

    private static let smallFrame = CGRect(x: 60, y: 60, width: 320, height: 180)
    private static let quietDB: Double = -50

    private var mainDisplayID: CGDirectDisplayID { CGMainDisplayID() }

    private func videoBody(
        startTime: TimeInterval = 0,
        endTime: TimeInterval? = nil,
        playCount: Int = 1,
        endBehavior: VideoEndBehavior = .stopAndUnload
    ) -> VideoBody {
        VideoBody(
            media: MediaReference(absolutePath: Self.identURL.path),
            startTime: startTime,
            endTime: endTime,
            playCount: playCount,
            volumeDB: Self.quietDB,
            endBehavior: endBehavior
        )
    }

    // MARK: - DisplayManager

    func testDisplayEnumerationAndSelfMatch() {
        let displays = DisplayManager.shared.displays
        XCTAssertGreaterThanOrEqual(displays.count, 1, "at least the built-in display must enumerate")
        for display in displays {
            XCTAssertNotEqual(display.displayID, 0)
            XCTAssertGreaterThan(display.fingerprint.pixelWidth, 0)
            XCTAssertGreaterThan(display.fingerprint.pixelHeight, 0)
            let matched = DisplayManager.shared.match(display.fingerprint)
            XCTAssertEqual(matched?.displayID, display.displayID,
                           "every fingerprint must match itself back to its own display")
        }
    }

    // MARK: - Arm + natural end (hold last frame)

    func testArmedTrimPlaysToNaturalEndAndHoldsLastFrame() async throws {
        let player = try await VideoCuePlayer.arm(
            body: videoBody(startTime: 1.0, endTime: 2.0, endBehavior: .holdLastFrame),
            fileURL: Self.identURL,
            displayID: mainDisplayID,
            windowFrameOverride: Self.smallFrame
        )
        XCTAssertEqual(player.player.currentItem?.status, .readyToPlay, "armed player must be readyToPlay")
        XCTAssertEqual(player.duration ?? -1, 1.0, accuracy: 0.05, "duration is the trimmed single pass")
        XCTAssertEqual(player.currentTime, 1.0, accuracy: 0.1, "armed player is seeked to the in-point")

        let finished = expectation(description: "natural end")
        finished.assertForOverFulfill = true
        var endReason: PlaybackEndReason?
        player.onFinished = { reason in
            endReason = reason
            finished.fulfill()
        }

        let startedAt = Date()
        player.start()
        await fulfillment(of: [finished], timeout: 6)
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertEqual(elapsed, 1.0, accuracy: 0.5, "trimmed 1.0–2.0 s pass should take ~1 s")
        guard case .natural = endReason else {
            return XCTFail("expected .natural, got \(String(describing: endReason))")
        }

        // holdLastFrame: onFinished fired but the layer is still on the output.
        XCTAssertNotNil(player.playerLayers.first?.superlayer, "holdLastFrame must keep the layer attached")
        XCTAssertNotNil(OutputWindowManager.shared.window(for: mainDisplayID))

        player.stop()
        XCTAssertNil(player.playerLayers.first?.superlayer, "stop() removes the held layer")
        XCTAssertNil(OutputWindowManager.shared.window(for: mainDisplayID), "last lease closes the window")
    }

    // MARK: - Loops

    func testPlayCountTwoDoublesPlayTime() async throws {
        let player = try await VideoCuePlayer.arm(
            body: videoBody(startTime: 1.0, endTime: 2.0, playCount: 2, endBehavior: .stopAndUnload),
            fileURL: Self.identURL,
            displayID: mainDisplayID,
            windowFrameOverride: Self.smallFrame
        )
        XCTAssertEqual(player.player.currentItem?.status, .readyToPlay)

        let finished = expectation(description: "natural end after two passes")
        finished.assertForOverFulfill = true
        var endReason: PlaybackEndReason?
        player.onFinished = { reason in
            endReason = reason
            finished.fulfill()
        }

        let startedAt = Date()
        player.start()
        await fulfillment(of: [finished], timeout: 8)
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertEqual(elapsed, 2.0, accuracy: 0.6, "playCount 2 must double the ~1 s pass")
        guard case .natural = endReason else {
            return XCTFail("expected .natural, got \(String(describing: endReason))")
        }
        XCTAssertNil(player.playerLayers.first?.superlayer, "stopAndUnload removes the layer at the natural end")
        XCTAssertNil(OutputWindowManager.shared.window(for: mainDisplayID))

        // Late idempotent stop must not double-report (assertForOverFulfill).
        player.stop()
        try await Task.sleep(for: .milliseconds(200))
    }

    // MARK: - Stop

    func testStopMidPlayReportsStoppedExactlyOnce() async throws {
        let player = try await VideoCuePlayer.arm(
            body: videoBody(), // full 5 s file
            fileURL: Self.identURL,
            displayID: mainDisplayID,
            windowFrameOverride: Self.smallFrame
        )

        let finished = expectation(description: "stopped")
        finished.assertForOverFulfill = true
        var reasons: [PlaybackEndReason] = []
        player.onFinished = { reason in
            reasons.append(reason)
            finished.fulfill()
        }

        player.start()
        try await Task.sleep(for: .milliseconds(300))
        player.stop()
        player.stop() // double-stop must be safe

        await fulfillment(of: [finished], timeout: 2)
        try await Task.sleep(for: .milliseconds(300)) // let any stray late callback trip the expectation

        XCTAssertEqual(reasons.count, 1, "onFinished must fire exactly once")
        guard case .stopped = reasons.first else {
            return XCTFail("expected .stopped, got \(String(describing: reasons.first))")
        }
        XCTAssertNil(player.playerLayers.first?.superlayer)
        XCTAssertNil(OutputWindowManager.shared.window(for: mainDisplayID))
    }

    // MARK: - Output window spec

    func testOutputWindowSpecAndCloseOnLastRelease() throws {
        let layer = try OutputWindowManager.shared.hostLayer(for: mainDisplayID, frameOverride: Self.smallFrame)
        let window = try XCTUnwrap(OutputWindowManager.shared.window(for: mainDisplayID))

        XCTAssertEqual(window.level, .screenSaver)
        XCTAssertTrue(window.collectionBehavior.isSuperset(of:
            [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]))
        XCTAssertTrue(window.ignoresMouseEvents)
        XCTAssertFalse(window.canBecomeKey, "output windows must never steal key focus")
        XCTAssertFalse(window.canBecomeMain)
        XCTAssertTrue(window.isOpaque)
        XCTAssertFalse(window.hasShadow)
        XCTAssertEqual(window.backgroundColor, .black)
        XCTAssertEqual(window.styleMask, [.borderless])
        XCTAssertEqual(window.frame, Self.smallFrame)
        XCTAssertTrue(window.isVisible, "shown via orderFrontRegardless")
        XCTAssertNotNil(window.contentView?.layer)
        XCTAssertTrue(layer === window.contentView?.layer)

        // Second lease on the same display reuses the window.
        let secondLayer = try OutputWindowManager.shared.hostLayer(for: mainDisplayID)
        XCTAssertTrue(secondLayer === layer)
        XCTAssertEqual(OutputWindowManager.shared.leaseCount(for: mainDisplayID), 2)

        OutputWindowManager.shared.releaseLayer(for: mainDisplayID)
        XCTAssertNotNil(OutputWindowManager.shared.window(for: mainDisplayID),
                        "window stays while a video layer remains")

        OutputWindowManager.shared.releaseLayer(for: mainDisplayID)
        XCTAssertNil(OutputWindowManager.shared.window(for: mainDisplayID),
                     "releasing the last layer closes the window")
    }
}
