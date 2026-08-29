import XCTest
@testable import StageWizard

/// Phase D4: cue markers on audio/video + FollowAction.autoContinueAtMarker.
@MainActor
final class MarkerTests: XCTestCase {
    private var show = ShowFile()
    private var provider = MockProvider()
    private var transport: TransportController!

    override func setUp() async throws {
        show = ShowFile()
        provider = MockProvider()
        transport = TransportController(
            provider: provider,
            show: { [unowned self] in self.show },
            showFolder: { nil }
        )
    }

    private func wait(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    // MARK: - CueMarker / markers[] model round trips

    func testCueMarkerAndMarkersRoundTripOnAudioAndVideoBodies() throws {
        let m1 = CueMarker(time: 1.5, name: "Verse")
        let m2 = CueMarker(time: 4.25, name: "Chorus")

        let audio = AudioBody(media: MediaReference(absolutePath: "/fake/a.wav"), markers: [m1, m2])
        let decodedAudio = try JSONDecoder().decode(AudioBody.self, from: JSONEncoder().encode(audio))
        XCTAssertEqual(decodedAudio.markers, [m1, m2])

        let video = VideoBody(media: MediaReference(absolutePath: "/fake/v.mov"), markers: [m1])
        let decodedVideo = try JSONDecoder().decode(VideoBody.self, from: JSONEncoder().encode(video))
        XCTAssertEqual(decodedVideo.markers, [m1])
    }

    func testMarkersDefaultToEmptyWhenKeyMissingFromOlderFiles() throws {
        let markedAudio = AudioBody(
            media: MediaReference(absolutePath: "/fake/a.wav"),
            markers: [CueMarker(time: 1, name: "x")]
        )
        var audioJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(markedAudio)) as! [String: Any]
        audioJSON.removeValue(forKey: "markers")
        let decodedAudio = try JSONDecoder().decode(AudioBody.self, from: JSONSerialization.data(withJSONObject: audioJSON))
        XCTAssertEqual(decodedAudio.markers, [], "pre-D4 audio bodies predate markers")

        let markedVideo = VideoBody(
            media: MediaReference(absolutePath: "/fake/v.mov"),
            markers: [CueMarker(time: 1, name: "x")]
        )
        var videoJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(markedVideo)) as! [String: Any]
        videoJSON.removeValue(forKey: "markers")
        let decodedVideo = try JSONDecoder().decode(VideoBody.self, from: JSONSerialization.data(withJSONObject: videoJSON))
        XCTAssertEqual(decodedVideo.markers, [], "pre-D4 video bodies predate markers")
    }

    // MARK: - FollowAction.autoContinueAtMarker model round trip

    func testAutoContinueAtMarkerRoundTrip() throws {
        let markerID = UUID()
        let cue = Cue(number: "1", follow: .autoContinueAtMarker(markerID: markerID), body: .stop(StopBody()))
        let decoded = try JSONDecoder().decode(Cue.self, from: JSONEncoder().encode(cue))
        XCTAssertEqual(decoded.follow, .autoContinueAtMarker(markerID: markerID))
    }

    // MARK: - Format version: v4 bump (FollowAction gained a new discriminator case)

    func testV3TaggedFileStillLoads() throws {
        let show = ShowFile(formatVersion: 3, cues: [Cue(number: "1", body: .stop(StopBody()))])
        let loaded = try ShowFile.load(from: try show.encoded())
        XCTAssertEqual(loaded.formatVersion, ShowFile.currentFormatVersion)
        XCTAssertEqual(loaded.cues.count, 1)
    }

    func testCurrentFormatVersionIsFour() throws {
        let json = """
        {"formatVersion": 4, "settings": {"panicDuration": 3, "doubleGOProtection": 0, "armAheadCount": 3, "keyBindings": {}}, "cues": []}
        """
        let loaded = try ShowFile.load(from: Data(json.utf8))
        XCTAssertEqual(loaded.formatVersion, 4)
    }

    func testNewerThanV4FormatRefusesToLoad() {
        let json = """
        {"formatVersion": 5, "settings": {"panicDuration": 3, "doubleGOProtection": 0, "armAheadCount": 3, "keyBindings": {}}, "cues": []}
        """
        XCTAssertThrowsError(try ShowFile.load(from: Data(json.utf8))) { error in
            guard case ShowFileError.newerFormat(5) = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    // MARK: - Runtime: marker-anchored follow

    /// delay = preWait + max(0, marker.time - startTime) / rate.
    /// marker at t=2, startTime=1, rate=2 → media offset 0.5s; preWait 0.1s → 0.6s total.
    func testMarkerFollowFiresAtComputedDelayNotBeforeOrLong() async {
        let markerID = UUID()
        let marker = CueMarker(id: markerID, time: 2, name: "Drop")
        let a = Cue(
            number: "1",
            preWait: 0.1,
            follow: .autoContinueAtMarker(markerID: markerID),
            body: .audio(AudioBody(
                media: MediaReference(absolutePath: "/fake/1.wav"),
                startTime: 1,
                rate: 2,
                markers: [marker]
            ))
        )
        provider.durations[a.id] = 5   // long-playing so the follow is clearly independent of a's duration
        let b = Cue(number: "2", body: .audio(AudioBody(media: MediaReference(absolutePath: "/fake/2.wav"))))
        provider.durations[b.id] = 0.2
        show.cues = [a, b]

        transport.go()
        await wait(0.35)
        XCTAssertNil(provider.players[b.id], "b must not fire before the marker delay elapses")
        await wait(0.45)   // total ~0.8s, comfortably past the 0.6s delay
        XCTAssertNotNil(provider.players[b.id], "b fires once playback reaches the marker")
    }

    func testDeletedMarkerNeverArmsFollow() async {
        // No marker on the body carries this id — e.g. it was deleted after
        // the follow was configured. Per spec this must NOT arm a follow at
        // all (no surprise fire later), not fall back to firing at cue start.
        let missingMarkerID = UUID()
        let a = Cue(
            number: "1",
            follow: .autoContinueAtMarker(markerID: missingMarkerID),
            body: .audio(AudioBody(media: MediaReference(absolutePath: "/fake/1.wav")))
        )
        provider.durations[a.id] = 0.2
        let b = Cue(number: "2", body: .audio(AudioBody(media: MediaReference(absolutePath: "/fake/2.wav"))))
        provider.durations[b.id] = 0.2
        show.cues = [a, b]

        transport.go()
        await wait(0.5)
        XCTAssertNil(provider.players[b.id], "an unresolved marker id must not arm any follow")
    }

    /// A marker past the trimmed OUT point would fire its follow after the
    /// cue already ended (playback never reaches it). Per spec this must
    /// NOT arm a follow at all — same silent no-arm as a deleted marker, no
    /// clamping to the out-point.
    func testMarkerBeyondOutTrimNeverArmsFollow() async {
        let markerID = UUID()
        let marker = CueMarker(id: markerID, time: 4, name: "Past the trim")
        let a = Cue(
            number: "1",
            follow: .autoContinueAtMarker(markerID: markerID),
            body: .audio(AudioBody(
                media: MediaReference(absolutePath: "/fake/1.wav"),
                endTime: 3,   // trims the cue's playable range to [0, 3]
                markers: [marker]
            ))
        )
        provider.durations[a.id] = 0.2
        let b = Cue(number: "2", body: .audio(AudioBody(media: MediaReference(absolutePath: "/fake/2.wav"))))
        provider.durations[b.id] = 0.2
        show.cues = [a, b]

        transport.go()
        await wait(0.5)
        XCTAssertNil(provider.players[b.id], "a marker past the OUT trim must not arm any follow")
    }

    func testStopAllCancelsPendingMarkerFollow() async {
        let markerID = UUID()
        let marker = CueMarker(id: markerID, time: 2, name: "Drop")
        let a = Cue(
            number: "1",
            follow: .autoContinueAtMarker(markerID: markerID),
            body: .audio(AudioBody(
                media: MediaReference(absolutePath: "/fake/1.wav"),
                startTime: 1,
                rate: 2,
                markers: [marker]
            ))
        )
        provider.durations[a.id] = 5
        let b = Cue(number: "2", body: .audio(AudioBody(media: MediaReference(absolutePath: "/fake/2.wav"))))
        provider.durations[b.id] = 0.2
        show.cues = [a, b]

        transport.go()
        await wait(0.1)
        transport.stopAll()
        await wait(0.6)   // well past the 0.5s marker delay
        XCTAssertNil(provider.players[b.id], "stopAll must cancel the pending marker follow")
    }

    /// Stopping the SOURCE cue alone (not Stop All / panic) must NOT cancel
    /// its own pending follow — mirrors existing autoContinue semantics
    /// exactly (TransportController only cancels pendingFollows from
    /// stopAll/panic; CueInstance.stop() never touches them).
    func testStoppingSourceCueAloneDoesNotCancelMarkerFollow() async {
        let markerID = UUID()
        let marker = CueMarker(id: markerID, time: 0.2, name: "Drop")
        let a = Cue(
            number: "1",
            follow: .autoContinueAtMarker(markerID: markerID),
            body: .audio(AudioBody(media: MediaReference(absolutePath: "/fake/1.wav"), markers: [marker]))
        )
        provider.durations[a.id] = 5
        let b = Cue(number: "2", body: .audio(AudioBody(media: MediaReference(absolutePath: "/fake/2.wav"))))
        provider.durations[b.id] = 0.2
        show.cues = [a, b]

        transport.go()
        await wait(0.05)
        transport.registry.instances.first { $0.cue.id == a.id }?.stop()
        await wait(0.35)
        XCTAssertNotNil(provider.players[b.id], "stopping only the source cue must not cancel its pending marker follow")
    }
}
