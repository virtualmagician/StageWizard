import XCTest
import AppKit
import QuartzCore
import AVFoundation
@testable import StageWizard

/// D19: proves the stage-display PROGRAM-pane mirroring chain end to end
/// through the REAL engine, and separately pins the real-window z-order
/// invariant that made the reported bug possible in the first place —
/// program panes rendered only their "PROGRAM · <group>" placeholder,
/// FOREVER, in both Show and Rehearsal, with no error anywhere. Two
/// suspects were fixed in `StageDisplayWindow.swift`:
///
///   1. `syncProgramPanes`' nil-layer guard (was silent, now
///      assertion-backed) — verified NOT actually live: `makeContentContainer`
///      already set `wantsLayer = true` before this bug was diagnosed, and
///      `NSView.layer` is created synchronously the instant `wantsLayer`
///      flips true (confirmed directly). Hardened anyway per the fix plan,
///      so a future regression here trips loudly instead of silently
///      disabling mirroring forever.
///   2. Z-order: manually inserting a raw `CALayer` as a sibling of a
///      layer-backed view's OWN subview layers is timing-dependent —
///      AppKit syncs `content`'s and `panic`'s layers into the container's
///      `sublayers` array LAZILY, on the window's next real display pass,
///      not synchronously on `addSubview`. `syncProgramPanes` runs
///      synchronously, before that sync happens, so its `insertSublayer(_:below:)`
///      call silently falls back to an append (the `below:` reference isn't
///      a member of `sublayers` yet) — and when AppKit's own sync runs
///      later, it APPENDS `content` and `panic` after what's already there.
///      Confirmed directly, reproducing the EXACT production call order
///      (`makeContentContainer` → `window.contentView = …` →
///      `window.orderFront(nil)` → `syncProgramPanes`): the array settles
///      as `[program, content, panic]`, burying the video under `content`'s
///      opaque black background — invisible, no error, forever. THIS was
///      the live bug. Fixed with explicit `zPosition` (program = 100,
///      panic = 1000, ordinary panes stay at the CALayer default, 0), which
///      makes paint order immune to whatever array order AppKit settles on.
///
/// Mirrors `IntegrationTests.swift`'s pattern (TestMedia via `#filePath` +
/// `XCTSkipUnless`, a real `EnginePlayerProvider`/`TransportController`) and
/// `V7Tests.swift`'s D17 headless-external-host pattern.
@MainActor
final class MirrorIntegrationTests: XCTestCase {
    static let mediaDir: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MirrorIntegrationTests.swift -> StageWizardTests/
            .deletingLastPathComponent()   // -> Tests/
            .deletingLastPathComponent()   // -> repo root
            .appendingPathComponent("TestMedia")
    }()

    private func wait(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    // MARK: - Attach chain: a real video cue mirrors onto a registered external host

    /// Registers a plain `CALayer` as the stage display's PROGRAM-pane
    /// external host for a group — exactly how `StageDisplayController`
    /// registers one for real (`syncProgramPanes`), minus the real window —
    /// then fires a REAL video cue targeting that group through a REAL
    /// `TransportController`, and proves the mirrored `AVPlayerLayer`
    /// actually lands on it with a real, nonzero frame. The group has NO
    /// displays assigned, so `EngineBridge.resolveTargets` routes the cue
    /// through nothing BUT this external host — isolating exactly the arm →
    /// resolveTargets → attach path that a dead `mirroredProgramGroupIDs`
    /// (suspect 1's failure mode) would have skipped entirely.
    func testVideoCueMirrorsOntoRegisteredStageDisplayExternalHost() async throws {
        let videoURL = Self.mediaDir.appendingPathComponent("ident-5s.mov")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: videoURL.path),
            "TestMedia missing — run: swift Tools/make-test-media.swift TestMedia"
        )

        let groupID = UUID()
        let group = OutputGroup(id: groupID, name: "Mirror Group")   // no displays assigned
        var show = ShowFile()
        show.settings.outputGroups = [group]
        show.cues = [Cue(number: "M1", body: .video(VideoBody(
            media: MediaReference(relativePath: "ident-5s.mov", absolutePath: videoURL.path),
            startTime: 0, endTime: nil, volumeDB: -50,
            outputGroupID: groupID
        )))]

        let hostLayer = CALayer()
        hostLayer.frame = CGRect(x: 0, y: 0, width: 320, height: 180)
        let programTarget = StageDisplayController.programTarget(for: groupID)
        OutputWindowManager.shared.registerExternalHost(hostLayer, for: programTarget)
        defer { OutputWindowManager.shared.unregisterExternalHost(for: programTarget) }

        let provider = EnginePlayerProvider()
        provider.settings = { show.settings }
        // Stands in for `StageDisplayController.mirroredProgramGroupIDs` —
        // this group's program pane is "registered and mirroring". `Set(...)`
        // spelled out (not a bare `{ [groupID] }`) since a closure body
        // starting with `[` is parsed as a capture list, not a literal.
        provider.stageDisplayProgramGroupIDs = { Set([groupID]) }

        let transport = TransportController(
            provider: provider,
            show: { show },
            showFolder: { Self.mediaDir }
        )

        transport.go()

        // `CueInstance.executeAction()` sets `state = .running` SYNCHRONOUSLY
        // at fire time (before any preWait, immediately for a zero-preWait
        // cue like this one) — well before the actual arm, which happens in
        // a detached `Task` (`CueInstance.runMediaAction`) that awaits
        // `armPlayer` (asset load + preroll) and only assigns `player` once
        // that completes. So `.running` alone is NOT proof the mirror
        // attached yet — poll on `player != nil` instead, which flips only
        // after `armPlayer` returns (by which point `VideoCuePlayer.init`
        // has already synchronously leased the host and added its layer).
        let started = ContinuousClock.now
        while transport.registry.instances.first?.player == nil,
              !(transport.registry.instances.first?.state.isTerminal ?? false),
              started.duration(to: .now).seconds < 5 {
            await wait(0.05)
        }
        XCTAssertNotNil(transport.registry.instances.first?.player, "cue armed and attached")
        XCTAssertEqual(transport.registry.instances.first?.state, .running, "cue reached playing")

        XCTAssertEqual(hostLayer.sublayers?.count, 1, "exactly one player layer mirrored onto the external host")
        let mirroredLayer = try XCTUnwrap(hostLayer.sublayers?.first)
        XCTAssertTrue(mirroredLayer is AVPlayerLayer, "the mirrored sublayer is a real AVPlayerLayer")
        XCTAssertEqual(mirroredLayer.frame, hostLayer.bounds, "sized to fill the host")
        XCTAssertGreaterThan(mirroredLayer.frame.width, 0, "a real, nonzero frame")
        XCTAssertGreaterThan(mirroredLayer.frame.height, 0, "a real, nonzero frame")

        transport.stopAll()
        XCTAssertNil(hostLayer.sublayers, "sublayer removed on stop, lease released")

        let stopStarted = ContinuousClock.now
        while !transport.registry.isEmpty, stopStarted.duration(to: .now).seconds < 3 {
            await wait(0.1)
        }
        XCTAssertTrue(transport.registry.isEmpty, "instance deregistered")
    }

    // MARK: - Z-order: PROGRAM must win over the opaque black content layer, and lose to PANIC

    /// Drives the REAL window-construction path
    /// (`StageDisplayController.sync` → `makeContentContainer` →
    /// `syncProgramPanes`) and pins the D19 z-order invariant against the
    /// REAL layer tree, forcing the same deferred AppKit sync that made the
    /// bug possible (see `debugContainerLayer`) so the assertions reflect
    /// what actually gets painted, not just what was inserted first.
    func testProgramLayerZPositionWinsOverContentAndLosesToPanicInTheRealWindow() throws {
        let app = AppModel()
        let controller = StageDisplayController()
        controller.appModel = app

        let groupID = UUID()
        let group = OutputGroup(id: groupID, name: "Z-Order Group")
        app.document.mutate { $0.settings.outputGroups = [group] }

        var settings = StageDisplaySettings(enabled: true)
        settings.panes.append(StageDisplayPane(
            kind: .program, enabled: true, rect: StageDisplayPane.defaultRect(for: .program), programGroupID: groupID
        ))

        controller.sync(
            settings: settings, outputGroups: [group], active: true, mode: .rehearsal, operatorScreenDisplayID: nil
        )
        defer {
            // Close the real floating window this test opened.
            controller.sync(
                settings: StageDisplaySettings(), outputGroups: [], active: false, mode: .edit, operatorScreenDisplayID: nil
            )
        }

        XCTAssertEqual(controller.mirroredProgramGroupIDs, Set([groupID]), "the program pane actually registered — suspect 1 would have left this empty")

        let containerLayer = try XCTUnwrap(controller.debugContainerLayer, "the real window's container must be layer-backed")
        let sublayers = try XCTUnwrap(containerLayer.sublayers, "AppKit must have synced its own subview layers by now")
        XCTAssertEqual(sublayers.count, 3, "content (ordinary panes) + program + panic, exactly")

        let panicLayers = sublayers.filter { $0.zPosition == StageDisplayController.panicLayerZPosition }
        let programLayers = sublayers.filter { $0.zPosition == StageDisplayController.programLayerZPosition }
        let contentLayers = sublayers.filter { $0.zPosition == 0 }
        XCTAssertEqual(panicLayers.count, 1, "exactly one layer at the PANIC zPosition (1000)")
        XCTAssertEqual(programLayers.count, 1, "exactly one layer at the PROGRAM zPosition (100)")
        XCTAssertEqual(contentLayers.count, 1, "exactly one layer (the ordinary panes' content view) at the default zPosition (0)")

        // The whole point of the fix: effective PAINT order (by zPosition,
        // ties broken by array index) must have PROGRAM strictly between
        // CONTENT and PANIC — regardless of what array index AppKit
        // actually settled on (reproduced directly while diagnosing D19:
        // pre-fix, the array itself comes out [program, content, panic],
        // which — with everything at the same default zPosition — paints
        // PROGRAM first and CONTENT's opaque black straight on top of it).
        let paintOrder = sublayers.enumerated()
            .sorted { a, b in a.element.zPosition == b.element.zPosition ? a.offset < b.offset : a.element.zPosition < b.element.zPosition }
            .map(\.element)
        XCTAssertTrue(paintOrder[0] === contentLayers[0], "content paints first (bottom)")
        XCTAssertTrue(paintOrder[1] === programLayers[0], "program paints second — above content, below panic")
        XCTAssertTrue(paintOrder[2] === panicLayers[0], "panic paints last (top) — always wins")
    }

    // MARK: - D20: mirrored content tracks program-pane frame changes (the scaling bug)

    /// Drives the REAL `syncProgramPanes` re-frame branch (a live pane-rect
    /// edit while a cue is already mirroring — exactly what the layout
    /// editor's drag gesture triggers) and proves the mirrored
    /// `AVPlayerLayer`'s frame tracks the pane's NEW size. Before the D20
    /// fix, `syncProgramPanes` re-framed only the HOST layer; the player's
    /// own sublayer kept whatever frame it got at attach time, so it went
    /// stale (misplaced/mis-scaled) the moment the pane was resized —
    /// exactly Marco's "content doesn't scale when resizing" report.
    func testMirroredVideoContentTracksProgramPaneRectEditWhileRunning() async throws {
        let videoURL = Self.mediaDir.appendingPathComponent("ident-5s.mov")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: videoURL.path),
            "TestMedia missing — run: swift Tools/make-test-media.swift TestMedia"
        )

        let app = AppModel()
        let controller = StageDisplayController()
        controller.appModel = app

        let groupID = UUID()
        let group = OutputGroup(id: groupID, name: "Resize Mirror Group")
        app.document.mutate { $0.settings.outputGroups = [group] }

        let initialRect = StageRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3)
        var settings = StageDisplaySettings(enabled: true)
        settings.panes.append(StageDisplayPane(kind: .program, enabled: true, rect: initialRect, programGroupID: groupID))
        controller.sync(settings: settings, outputGroups: [group], active: true, mode: .rehearsal, operatorScreenDisplayID: nil)
        defer {
            controller.sync(settings: StageDisplaySettings(), outputGroups: [], active: false, mode: .edit, operatorScreenDisplayID: nil)
        }
        XCTAssertEqual(controller.mirroredProgramGroupIDs, Set([groupID]))

        // Arm a real video cue targeting the program pane directly (the
        // pane is already mirroring, exactly like D19's existing test) —
        // this is an ARM-TIME attach, sized to whatever the host's bounds
        // were the instant it leased the layer.
        let programTarget = StageDisplayController.programTarget(for: groupID)
        let player = try await VideoCuePlayer.arm(
            body: VideoBody(
                media: MediaReference(relativePath: "ident-5s.mov", absolutePath: videoURL.path),
                startTime: 0, endTime: nil, volumeDB: -50, outputGroupID: groupID
            ),
            fileURL: videoURL,
            targets: [programTarget]
        )
        defer { player.stop() }

        let hostBefore = try XCTUnwrap(controller.debugProgramHostLayer(for: groupID))
        let mirroredBefore = try XCTUnwrap(hostBefore.sublayers?.first)
        XCTAssertEqual(mirroredBefore.frame, hostBefore.bounds, "attach seeds the sublayer's frame to the host's bounds")
        // Snapshot VALUES (CGRect/CGSize are structs) before mutating the
        // SAME CALayer objects below — reading `hostBefore.bounds` again
        // afterward would report the layer's CURRENT (post-resize) state,
        // since `hostBefore`/`mirroredBefore` are references to the very
        // layers `syncProgramPanes` reuses and re-frames in place.
        let beforeHostSize = hostBefore.bounds.size
        let beforeMirroredWidth = mirroredBefore.frame.width

        // Live pane-rect edit while the cue is still running/mirroring —
        // exactly what dragging the box in the layout editor does.
        var resized = settings
        let idx = try XCTUnwrap(resized.panes.firstIndex { $0.programGroupID == groupID })
        resized.panes[idx].rect = StageRect(x: 0.05, y: 0.05, width: 0.6, height: 0.6)
        controller.sync(settings: resized, outputGroups: [group], active: true, mode: .rehearsal, operatorScreenDisplayID: nil)

        let hostAfter = try XCTUnwrap(controller.debugProgramHostLayer(for: groupID))
        let mirroredAfter = try XCTUnwrap(hostAfter.sublayers?.first)
        XCTAssertNotEqual(hostAfter.bounds.size, beforeHostSize, "the pane actually got bigger")
        XCTAssertEqual(mirroredAfter.frame, hostAfter.bounds, "mirrored content tracks the resized pane frame")
        XCTAssertGreaterThan(mirroredAfter.frame.width, beforeMirroredWidth, "visibly bigger, not stale")
    }

    /// Same fix, the OTHER call site: a real floating-window RESIZE (the
    /// resize observer path, `repositionProgramPanes`) — this is the exact
    /// scenario Marco reported ("scale properly when sizing the floating
    /// window").
    func testMirroredVideoContentTracksFloatingWindowResize() async throws {
        let videoURL = Self.mediaDir.appendingPathComponent("ident-5s.mov")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: videoURL.path),
            "TestMedia missing — run: swift Tools/make-test-media.swift TestMedia"
        )

        let app = AppModel()
        let controller = StageDisplayController()
        controller.appModel = app

        let groupID = UUID()
        let group = OutputGroup(id: groupID, name: "Window Resize Mirror Group")
        app.document.mutate { $0.settings.outputGroups = [group] }

        var settings = StageDisplaySettings(enabled: true)
        settings.panes.append(StageDisplayPane(
            kind: .program, enabled: true, rect: StageDisplayPane.defaultRect(for: .program), programGroupID: groupID
        ))
        controller.sync(settings: settings, outputGroups: [group], active: true, mode: .rehearsal, operatorScreenDisplayID: nil)
        defer {
            controller.sync(settings: StageDisplaySettings(), outputGroups: [], active: false, mode: .edit, operatorScreenDisplayID: nil)
        }

        let programTarget = StageDisplayController.programTarget(for: groupID)
        let player = try await VideoCuePlayer.arm(
            body: VideoBody(
                media: MediaReference(relativePath: "ident-5s.mov", absolutePath: videoURL.path),
                startTime: 0, endTime: nil, volumeDB: -50, outputGroupID: groupID
            ),
            fileURL: videoURL,
            targets: [programTarget]
        )
        defer { player.stop() }

        let hostBeforeResize = try XCTUnwrap(controller.debugProgramHostLayer(for: groupID))
        // Snapshot the VALUE (CGSize is a struct) before resizing — the same
        // CALayer gets re-framed in place, so re-reading `.bounds` on it
        // later would report the NEW size, not this baseline.
        let sizeBeforeResize = hostBeforeResize.bounds.size

        let window = try XCTUnwrap(controller.debugWindow, "the floating presentation must have a real window")
        var newFrame = window.frame
        newFrame.size = CGSize(width: newFrame.width + 220, height: newFrame.height + 160)
        window.setFrame(newFrame, display: true)

        // `repositionProgramPanes` hops off the resize notification via a
        // `Task { @MainActor in … }` — poll until it has ACTUALLY run (the
        // host layer's size changed from the baseline above), not just
        // until the mirrored sublayer happens to agree with a still-stale
        // host (which would be true trivially, before the fix runs at all).
        let started = ContinuousClock.now
        var hostLayer: CALayer?
        var mirroredLayer: CALayer?
        while started.duration(to: .now).seconds < 3 {
            hostLayer = controller.debugProgramHostLayer(for: groupID)
            mirroredLayer = hostLayer?.sublayers?.first
            if let mirroredLayer, let hostLayer,
               hostLayer.bounds.size != sizeBeforeResize, mirroredLayer.frame == hostLayer.bounds {
                break
            }
            await wait(0.05)
        }
        let finalHost = try XCTUnwrap(hostLayer)
        let finalMirrored = try XCTUnwrap(mirroredLayer)
        XCTAssertNotEqual(finalHost.bounds.size, sizeBeforeResize, "the window resize actually reached the program pane")
        XCTAssertEqual(finalMirrored.frame, finalHost.bounds, "mirrored content tracks the resized floating window")
        XCTAssertGreaterThan(finalHost.bounds.width, 0)
    }
}
