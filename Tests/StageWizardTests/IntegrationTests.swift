import XCTest
@testable import StageWizard

/// Full-stack tests: real TransportController → EnginePlayerProvider →
/// AVAudioEngine/AVQueuePlayer, playing the generated TestMedia files.
/// Everything runs at -50 dB and (video) in a small corner window.
@MainActor
final class IntegrationTests: XCTestCase {
    static let mediaDir = URL(
        fileURLWithPath: "/Users/marcotempest/Library/CloudStorage/Dropbox-Newmagic/Marco Tempest/StageWizard/TestMedia"
    )

    private var show = ShowFile()
    private var transport: TransportController!

    override func setUp() async throws {
        let toneURL = Self.mediaDir.appendingPathComponent("tone-440-10s.wav")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: toneURL.path),
            "TestMedia missing — run: swift Tools/make-test-media.swift TestMedia"
        )
        show = ShowFile()
        show.settings.panicDuration = 0.3
        transport = TransportController(
            provider: EnginePlayerProvider(),
            show: { [unowned self] in self.show },
            showFolder: { Self.mediaDir }
        )
    }

    private func audioCue(_ number: String, file: String, start: TimeInterval, end: TimeInterval?, follow: FollowAction = .none) -> Cue {
        Cue(
            number: number,
            follow: follow,
            body: .audio(AudioBody(
                media: MediaReference(relativePath: file, absolutePath: Self.mediaDir.appendingPathComponent(file).path),
                startTime: start,
                endTime: end,
                volumeDB: -50
            ))
        )
    }

    private func wait(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// GO an audio cue trimmed to 1 s: it must appear in the registry, play,
    /// finish naturally on time, and leave the registry.
    func testAudioCuePlaysTrimmedThroughRealEngine() async throws {
        show.cues = [audioCue("1", file: "tone-440-10s.wav", start: 1.0, end: 2.0)]
        let started = ContinuousClock.now
        transport.go()
        await wait(0.3)
        XCTAssertEqual(transport.registry.instances.count, 1, "instance registered and playing")

        // Poll until the registry drains (natural finish), max 3 s.
        var elapsed: TimeInterval = 0
        while !transport.registry.isEmpty, started.duration(to: .now).seconds < 3 {
            await wait(0.1)
        }
        elapsed = started.duration(to: .now).seconds
        XCTAssertTrue(transport.registry.isEmpty, "cue finished and deregistered")
        XCTAssertEqual(elapsed, 1.0, accuracy: 0.6, "trimmed 1s cue ends on time")
    }

    /// Auto-follow chain through the real engine: audio (0.5 s trim) → audio.
    func testAutoFollowChainsAcrossRealCues() async throws {
        var first = audioCue("1", file: "count-60s.wav", start: 0, end: 0.5, follow: .autoFollow)
        first.name = "first"
        let second = audioCue("2", file: "tone-440-10s.wav", start: 0, end: 0.5)
        show.cues = [first, second]
        transport.go()
        await wait(0.25)
        XCTAssertEqual(transport.registry.instances.count, 1)
        XCTAssertEqual(transport.registry.instances.first?.cue.number, "1")
        await wait(0.6)
        // First ended → second fired by auto-follow.
        XCTAssertEqual(transport.registry.instances.first?.cue.number, "2", "auto-follow fired the second cue")
        await wait(0.8)
        XCTAssertTrue(transport.registry.isEmpty)
    }

    /// Panic mid-play must silence and drain everything, fast.
    func testPanicDrainsRealPlayback() async throws {
        show.cues = [audioCue("1", file: "tone-440-10s.wav", start: 0, end: nil)]
        transport.go()
        await wait(0.3)
        XCTAssertFalse(transport.registry.isEmpty)
        transport.panic()
        await wait(1.0)   // panicDuration 0.3 + settle
        XCTAssertTrue(transport.registry.isEmpty, "panic drained the registry")
        XCTAssertFalse(transport.isPanicking)
    }

    /// Video cue through the real engine in a corner window: arm, play 1 s
    /// trim, hold last frame, then stop on command.
    func testVideoCueHoldsLastFrameThenStops() async throws {
        var cue = Cue(
            number: "V1",
            body: .video(VideoBody(
                media: MediaReference(
                    relativePath: "ident-5s.mov",
                    absolutePath: Self.mediaDir.appendingPathComponent("ident-5s.mov").path
                ),
                startTime: 1.0,
                endTime: 2.0,
                volumeDB: -50,
                endBehavior: .holdLastFrame
            ))
        )
        cue.name = "hold test"
        show.cues = [cue]

        // Arm directly (not via GO) so we can use the small test window.
        guard case .video(let body) = cue.body else { return XCTFail() }
        let url = Self.mediaDir.appendingPathComponent("ident-5s.mov")
        let player = try await VideoCuePlayer.arm(
            body: body, fileURL: url,
            displayID: CGMainDisplayID(),
            windowFrameOverride: CGRect(x: 40, y: 40, width: 320, height: 180)
        )
        let finished = expectation(description: "natural finish at out-point")
        player.onFinished = { reason in
            if case .natural = reason { finished.fulfill() }
        }
        player.start()
        await fulfillment(of: [finished], timeout: 4)
        // Hold: player still alive after natural end until stop().
        player.stop()
    }
}
