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
}
