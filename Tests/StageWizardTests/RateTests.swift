import AVFoundation
import AppKit
import XCTest
@testable import StageWizard

/// D3: per-cue playback rate (0.25×–4×, default 1) on AudioBody/VideoBody.
/// Covers model round-trip/compat/clamping, the DurationCache wall-clock
/// conversion, and — since duration/currentTime is a computed property, not
/// a stored one — the real engines' wall-clock math, both as an instant
/// post-arm check and as an end-to-end real-time playback timing.
@MainActor
final class RateTests: XCTestCase {

    private static let toneURL = URL(fileURLWithPath:
        "/Users/marcotempest/Library/CloudStorage/Dropbox-Newmagic/Marco Tempest/StageWizard/TestMedia/tone-440-10s.wav")
    private static let identURL = URL(fileURLWithPath:
        "/Users/marcotempest/Library/CloudStorage/Dropbox-Newmagic/Marco Tempest/StageWizard/TestMedia/ident-5s.mov")
    private static let smallFrame = CGRect(x: 60, y: 60, width: 320, height: 180)

    // MARK: - AudioBody.rate

    func testAudioBodyRateRoundTrips() throws {
        let body = AudioBody(media: MediaReference(absolutePath: "/a.wav"), rate: 1.5)
        let decoded = try JSONDecoder().decode(AudioBody.self, from: JSONEncoder().encode(body))
        XCTAssertEqual(decoded.rate, 1.5)
    }

    func testAudioBodyRateClamps() {
        XCTAssertEqual(AudioBody(media: MediaReference(absolutePath: "/a.wav"), rate: 9).rate, 4, "clamped high")
        XCTAssertEqual(AudioBody(media: MediaReference(absolutePath: "/a.wav"), rate: 0.1).rate, 0.25, "clamped low")
    }

    // MARK: - VideoBody.rate

    func testVideoBodyRateRoundTrips() throws {
        let body = VideoBody(media: MediaReference(absolutePath: "/v.mov"), rate: 0.75)
        let decoded = try JSONDecoder().decode(VideoBody.self, from: JSONEncoder().encode(body))
        XCTAssertEqual(decoded.rate, 0.75)
    }

    func testVideoBodyRateClamps() {
        XCTAssertEqual(VideoBody(media: MediaReference(absolutePath: "/v.mov"), rate: 9).rate, 4, "clamped high")
        XCTAssertEqual(VideoBody(media: MediaReference(absolutePath: "/v.mov"), rate: 0.1).rate, 0.25, "clamped low")
    }

    // MARK: - Old-file compatibility (mirrors V7Tests' stripped-key pattern)

    func testShowFileWithoutRateKeysDecodesToNormalSpeedForBothBodies() throws {
        var show = ShowFile()
        show.cues = [
            Cue(number: "1", body: .audio(AudioBody(media: MediaReference(absolutePath: "/a.wav")))),
            Cue(number: "2", body: .video(VideoBody(media: MediaReference(absolutePath: "/v.mov")))),
        ]
        var json = try JSONSerialization.jsonObject(with: show.encoded()) as! [String: Any]
        var cues = json["cues"] as! [[String: Any]]
        for index in cues.indices {
            var body = cues[index]["body"] as! [String: Any]
            body.removeValue(forKey: "rate")
            cues[index]["body"] = body
        }
        json["cues"] = cues
        let stripped = try JSONSerialization.data(withJSONObject: json)
        let decoded = try ShowFile.load(from: stripped)

        guard case .audio(let audio) = decoded.cues[0].body else { return XCTFail("expected .audio") }
        XCTAssertEqual(audio.rate, 1, "older files predate rate — must land on normal speed")
        guard case .video(let video) = decoded.cues[1].body else { return XCTFail("expected .video") }
        XCTAssertEqual(video.rate, 1, "older files predate rate — must land on normal speed")
    }

    // MARK: - DurationCache: the Duration column shows wall-clock time

    func testDurationCacheDividesTrimmedVideoDurationByRate() {
        let body = VideoBody(
            media: MediaReference(absolutePath: "/nonexistent.mov"),
            startTime: 0, endTime: 10,
            rate: 2
        )
        var show = ShowFile()
        let cue = Cue(number: "1", body: .video(body))
        show.cues = [cue]
        let effective = DurationCache.shared.effectiveDuration(of: cue, in: show, showFolder: nil)
        XCTAssertEqual(effective ?? -1, 5, accuracy: 0.0001, "10s trim at 2x rate shows 5s wall-clock")
    }

    func testDurationCacheDividesTrimmedAudioDurationByRate() {
        let body = AudioBody(
            media: MediaReference(absolutePath: "/nonexistent.wav"),
            startTime: 0, endTime: 10,
            rate: 4
        )
        var show = ShowFile()
        let cue = Cue(number: "1", body: .audio(body))
        show.cues = [cue]
        let effective = DurationCache.shared.effectiveDuration(of: cue, in: show, showFolder: nil)
        XCTAssertEqual(effective ?? -1, 2.5, accuracy: 0.0001, "10s trim at 4x rate shows 2.5s wall-clock")
    }

    func testDurationCacheWallClockHelper() {
        XCTAssertEqual(DurationCache.wallClock(10, rate: 2), 5)
        XCTAssertEqual(DurationCache.wallClock(10, rate: 1), 10)
        XCTAssertEqual(DurationCache.wallClock(10, rate: 0.25), 40)
    }

    // MARK: - Engines: duration is reported wall-clock (instant, no waiting)

    func testAudioCuePlayerReportsWallClockDurationAtDoubleRate() async throws {
        let body = AudioBody(
            media: MediaReference(absolutePath: Self.toneURL.path),
            startTime: 0, endTime: 2.0,
            volumeDB: -50,
            rate: 2
        )
        let player = try await AudioCuePlayer.arm(body: body, fileURL: Self.toneURL)
        defer { player.stop() }
        XCTAssertEqual(player.duration ?? -1, 1.0, accuracy: 0.01, "2s media pass at 2x plays back in 1s wall-clock")
    }

    func testVideoCuePlayerReportsWallClockDurationAtDoubleRate() async throws {
        let body = VideoBody(
            media: MediaReference(absolutePath: Self.identURL.path),
            startTime: 1.0, endTime: 2.0,
            volumeDB: -50,
            rate: 2
        )
        let player = try await VideoCuePlayer.arm(
            body: body, fileURL: Self.identURL, displayID: CGMainDisplayID(),
            windowFrameOverride: Self.smallFrame
        )
        defer { player.stop() }
        XCTAssertEqual(player.duration ?? -1, 0.5, accuracy: 0.01, "1s media pass at 2x plays back in 0.5s wall-clock")
    }

    // MARK: - Engine: rate actually changes real playback speed end-to-end

    func testAudioCuePlayerAtDoubleRateFinishesInHalfWallClockTime() async throws {
        let body = AudioBody(
            media: MediaReference(absolutePath: Self.toneURL.path),
            startTime: 0, endTime: 2.0,
            volumeDB: -50,
            rate: 2
        )
        let player = try await AudioCuePlayer.arm(body: body, fileURL: Self.toneURL)

        let finishExpectation = expectation(description: "natural finish at 2x")
        var reason: PlaybackEndReason?
        player.onFinished = { r in
            reason = r
            finishExpectation.fulfill()
        }

        let startedAt = Date()
        player.start()
        await fulfillment(of: [finishExpectation], timeout: 10)
        let elapsed = Date().timeIntervalSince(startedAt)

        if case .natural = reason {} else {
            XCTFail("expected .natural, got \(String(describing: reason))")
        }
        XCTAssertEqual(elapsed, 1.0, accuracy: 0.35, "2s media pass at 2x should take ~1s wall-clock, took \(elapsed)s")
    }
}
