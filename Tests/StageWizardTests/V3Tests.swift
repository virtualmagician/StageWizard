import XCTest
@testable import StageWizard

@MainActor
final class V3Tests: XCTestCase {

    // MARK: - Output groups: model + migration

    func testOutputGroupRoundTripAndLegacySettingsDecode() throws {
        var show = ShowFile()
        let group = OutputGroup(name: "Prompter", displays: [
            DisplayFingerprint(name: "Built-in", pixelWidth: 2560, pixelHeight: 1600),
            DisplayFingerprint(name: "Sidecar", pixelWidth: 2360, pixelHeight: 1640),
        ])
        show.settings.outputGroups = [group]
        show.cues = [Cue(number: "1", body: .video(VideoBody(
            media: MediaReference(absolutePath: "/x.mov"),
            outputGroupID: group.id
        )))]
        let decoded = try ShowFile.load(from: show.encoded())
        XCTAssertEqual(decoded.settings.outputGroups, [group])
        guard case .video(let body) = decoded.cues[0].body else { return XCTFail() }
        XCTAssertEqual(body.outputGroupID, group.id)

        // v1/v2 settings JSON without outputGroups must decode to [].
        let legacy = """
        {"panicDuration": 3, "doubleGOProtection": 0, "armAheadCount": 3, "keyBindings": {}}
        """
        let settings = try JSONDecoder().decode(ShowSettings.self, from: Data(legacy.utf8))
        XCTAssertEqual(settings.outputGroups, [])
    }

    func testV1MigrationCreatesGroupsFromDirectDisplays() throws {
        // Two cues on the same display share one migrated group.
        let projector = DisplayFingerprint(vendorNumber: 42, name: "Projector", pixelWidth: 1920, pixelHeight: 1080)
        var show = ShowFile(formatVersion: 1)
        show.cues = [
            Cue(number: "1", body: .video(VideoBody(media: MediaReference(absolutePath: "/a.mov"), display: projector))),
            Cue(number: "2", body: .video(VideoBody(media: MediaReference(absolutePath: "/b.mov"), display: projector))),
            Cue(number: "3", body: .camera(CameraBody(display: projector))),
        ]
        var data = try JSONSerialization.jsonObject(with: show.encoded()) as! [String: Any]
        data["formatVersion"] = 1   // force the pre-groups version
        let migrated = try ShowFile.load(from: JSONSerialization.data(withJSONObject: data))

        XCTAssertEqual(migrated.settings.outputGroups.count, 1, "same display → one shared group")
        let group = migrated.settings.outputGroups[0]
        XCTAssertEqual(group.name, "Projector")
        XCTAssertEqual(group.displays, [projector])
        for cue in migrated.cues {
            switch cue.body {
            case .video(let body): XCTAssertEqual(body.outputGroupID, group.id)
            case .camera(let body): XCTAssertEqual(body.outputGroupID, group.id)
            default: XCTFail()
            }
        }
        XCTAssertEqual(migrated.formatVersion, ShowFile.currentFormatVersion)
    }

    // MARK: - Copy/paste remapping

    func testPasteRemapsInternalReferencesOnly() {
        let document = ShowDocumentController()
        let group = Cue(number: "10", body: .group(GroupBody(mode: .timeline)))
        var child = Cue(number: "10.1", body: .audio(AudioBody(media: MediaReference(absolutePath: "/a.wav"))))
        child.parentID = group.id
        var groupBody = GroupBody(mode: .timeline, childOffsets: [child.id: 2.5])
        var groupCue = group
        groupCue.body = .group(groupBody)
        let fadeInside = Cue(number: "11", body: .fade(FadeBody(targetID: child.id)))
        let outsider = Cue(number: "1", body: .audio(AudioBody(media: MediaReference(absolutePath: "/b.wav"))))
        let fadeOutside = Cue(number: "12", body: .fade(FadeBody(targetID: outsider.id)))

        document.mutate { $0.cues = [outsider, groupCue, child, fadeInside, fadeOutside] }
        document.selection = [groupCue.id, fadeInside.id, fadeOutside.id]   // child implied via group

        let copied = CueFactory.copyableCues(in: document)
        XCTAssertEqual(copied.count, 4, "children of selected groups ride along")

        CueFactory.pasteCues(copied, into: document)
        let all = document.show.cues
        XCTAssertEqual(all.count, 9)

        let pastedIDs = document.selection
        let pasted = all.filter { pastedIDs.contains($0.id) }
        XCTAssertEqual(pasted.count, 4)

        let newGroup = pasted.first { if case .group = $0.body { return true }; return false }!
        let newChild = pasted.first { $0.parentID != nil }!
        XCTAssertEqual(newChild.parentID, newGroup.id, "parentID remapped to the new group")
        XCTAssertNotEqual(newGroup.id, groupCue.id)

        guard case .group(let newGroupBody) = newGroup.body else { return XCTFail() }
        XCTAssertEqual(newGroupBody.childOffsets[newChild.id], 2.5, "timeline offset keys remapped")

        let newFades = pasted.compactMap { cue -> FadeBody? in
            if case .fade(let body) = cue.body { return body }
            return nil
        }
        XCTAssertEqual(newFades.count, 2)
        XCTAssertTrue(newFades.contains { $0.targetID == newChild.id },
                      "fade targeting a copied cue points at the NEW copy")
        XCTAssertTrue(newFades.contains { $0.targetID == outsider.id },
                      "fade targeting an uncopied cue keeps the original target")
    }

    func testPasteChildWithoutItsGroupBecomesTopLevel() {
        let document = ShowDocumentController()
        let group = Cue(number: "10", body: .group(GroupBody()))
        var child = Cue(number: "10.1", body: .stop(StopBody()))
        child.parentID = group.id
        document.mutate { $0.cues = [group, child] }

        CueFactory.pasteCues([child], into: document)
        let pastedID = document.selection.first!
        XCTAssertNil(document.show.cue(withID: pastedID)?.parentID)
    }

    // MARK: - Rehearsal previews

    func testVideoPlaysIntoPreviewTargetWithoutDisplay() async throws {
        let mediaDir = IntegrationTests.mediaDir
        let url = mediaDir.appendingPathComponent("ident-5s.mov")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "TestMedia missing")

        let groupID = UUID()
        let target = OutputTarget.preview(id: groupID, title: "Test Preview")
        let body = VideoBody(
            media: MediaReference(absolutePath: url.path),
            startTime: 1.0, endTime: 1.6, volumeDB: -50
        )
        let player = try await VideoCuePlayer.arm(body: body, fileURL: url, targets: [target])
        XCTAssertNotNil(OutputWindowManager.shared.window(for: target), "preview window created at arm")
        XCTAssertEqual(OutputWindowManager.shared.leaseCount(for: target), 1)
        XCTAssertTrue(player.displayIDs.isEmpty, "preview targets are invisible to the unplug sweep")

        let finished = expectation(description: "plays to the out-point in the preview")
        player.onFinished = { reason in
            if case .natural = reason { finished.fulfill() }
        }
        player.start()
        await fulfillment(of: [finished], timeout: 4)
        player.stop()
        XCTAssertNil(OutputWindowManager.shared.window(for: target),
                     "unpinned preview closes with its last lease")
    }

    func testPinnedPreviewSurvivesLeaseReleaseUntilClosed() throws {
        let id = UUID()
        OutputWindowManager.shared.openPreview(id: id, title: "Prompter")
        let target = OutputTarget.preview(id: id, title: "Prompter")
        let window = OutputWindowManager.shared.window(for: target)
        XCTAssertNotNil(window)
        XCTAssertEqual(window?.title, "Rehearsal: Prompter")
        XCTAssertTrue(window?.styleMask.contains(.resizable) ?? false)
        XCTAssertEqual(window?.level, .floating)

        _ = try OutputWindowManager.shared.hostLayer(for: target)
        OutputWindowManager.shared.releaseLayer(for: target)
        XCTAssertNotNil(OutputWindowManager.shared.window(for: target),
                        "pinned preview survives its leases")

        OutputWindowManager.shared.closeAllPreviews()
        XCTAssertNil(OutputWindowManager.shared.window(for: target))
    }

    // MARK: - Show mode invariants

    func testShowModeDefaultsToEditAndToggles() {
        let app = AppModel()
        XCTAssertFalse(app.isShowMode, "always launch editable")
        app.setMode(.show)
        XCTAssertTrue(app.isShowMode)
        XCTAssertEqual(app.document.show.settings.workspaceMode, .show, "mode persists into the show file")
        app.setMode(.edit)
        XCTAssertEqual(app.mode, .edit)
    }

    func testWorkspaceModeRoundTripAndLegacyDefault() throws {
        var show = ShowFile()
        show.settings.workspaceMode = .rehearsal
        let decoded = try ShowFile.load(from: show.encoded())
        XCTAssertEqual(decoded.settings.workspaceMode, .rehearsal)

        let legacy = """
        {"panicDuration": 3, "doubleGOProtection": 0, "armAheadCount": 3, "keyBindings": {}}
        """
        let settings = try JSONDecoder().decode(ShowSettings.self, from: Data(legacy.utf8))
        XCTAssertEqual(settings.workspaceMode, .edit, "pre-v3 files open in Edit")
    }
}
