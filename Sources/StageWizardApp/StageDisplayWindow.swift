import AppKit
import QuartzCore
import SwiftUI

// MARK: - Window

/// Borderless, non-activating window for the stage display — same
/// never-steals-focus contract as `OutputWindowManager`'s `OutputWindow`
/// (this type is intentionally separate: the stage display is never leased
/// through `OutputWindowManager`, it's never a cue target).
private final class StageDisplayNSWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// D14: the Rehearsal-mode presentation — floating, titled, resizable, like
/// a rehearsal preview panel (see `OutputWindowManager.PreviewWindow`, which
/// this deliberately does NOT reuse: the stage display is never leased
/// through `OutputWindowManager`, same reasoning as `StageDisplayNSWindow`
/// above being separate from `OutputWindow`). Only `canBecomeMain` is
/// overridden — `becomesKeyOnlyIfNeeded` (set where this is constructed)
/// keeps it from stealing focus on an ordinary click, matching the preview
/// panel convention exactly.
private final class StageDisplayFloatingWindow: NSPanel {
    override var canBecomeMain: Bool { false }
}

/// Owns the performer-facing "confidence monitor" window — clock, show
/// timer, standing-by cue + notes, running cues, and (D13) a live PROGRAM
/// pane mirroring an output group. Show mode presents it borderless
/// fullscreen on a chosen display; Rehearsal (D14) presents it as a
/// floating, resizable window instead — no display required, so it doubles
/// as a layout preview while rigging. Reads transport state only; NEVER a
/// cue target itself, so its own window never touches `OutputWindowManager`
/// — but the program pane's content layer IS registered there (as an
/// EXTERNAL host, see `OutputWindowManager.registerExternalHost`) so video/
/// camera/text/slide players can mirror onto it exactly like any other
/// preview target.
@MainActor
final class StageDisplayController {
    /// One level below `OutputWindowManager`'s real output windows
    /// (`.screenSaver`) — deliberately so a genuine cue output assigned to
    /// the SAME physical display always wins the top of the window stack.
    /// The stage display must never be able to cover real show content.
    static let windowLevel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)

    /// D16: XOR sentinel for deriving each output group's program-target id
    /// — the exact 16-byte constant (0x33 repeated) the single-pane D13
    /// `programTargetID` used verbatim, so the derivation is a strict
    /// generalization of it rather than an unrelated scheme.
    private static let programTargetSentinel: [UInt8] = Array(repeating: 0x33, count: 16)

    /// Pure, deterministic per-group derivation of the mirrored output
    /// target's id: XOR the group UUID's 16 bytes with the sentinel above.
    /// Same group id always derives the same target id (stable across
    /// syncs); XOR-ing with a fixed key is a bijection, so distinct groups
    /// always derive distinct target ids, and — since the sentinel is
    /// non-zero — the derived id can never equal the group id itself.
    static func programTargetID(for groupID: UUID) -> UUID {
        let groupBytes = withUnsafeBytes(of: groupID.uuid) { Array($0) }
        var resultBytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 {
            resultBytes[i] = groupBytes[i] ^ programTargetSentinel[i]
        }
        let tuple = (
            resultBytes[0], resultBytes[1], resultBytes[2], resultBytes[3],
            resultBytes[4], resultBytes[5], resultBytes[6], resultBytes[7],
            resultBytes[8], resultBytes[9], resultBytes[10], resultBytes[11],
            resultBytes[12], resultBytes[13], resultBytes[14], resultBytes[15]
        )
        return UUID(uuid: tuple)
    }

    /// Stable identity for one group's program pane's mirrored output
    /// target — a `.preview` target like `VirtualCameraManager.monitorTarget`,
    /// but hosted directly in this window instead of a separate floating one
    /// (see `OutputWindowManager.registerExternalHost`). D16: one per
    /// mirrored group, replacing D13's single fixed `programTarget`.
    static func programTarget(for groupID: UUID) -> OutputTarget {
        .preview(id: programTargetID(for: groupID), title: "Stage Display")
    }

    /// Set by AppModel right after both are constructed (avoids a
    /// self-before-fully-initialized ordering problem in AppModel.init).
    weak var appModel: AppModel?

    /// D14: which of the two presentations is currently on screen — Show
    /// mode is borderless-fullscreen pinned to a real display; Rehearsal is
    /// a floating resizable panel that needs no display at all. Replaces the
    /// pre-D14 `currentDisplayID` (fullscreen-only) so `sync` can tell
    /// "already showing the right thing" apart from "must tear down and
    /// re-present" in both cases, not just a display change.
    private enum Presentation: Equatable {
        case fullscreen(CGDirectDisplayID)
        case floating
    }

    private var window: NSWindow?
    private var currentPresentation: Presentation?
    /// D16: one live content layer PER MIRRORED GROUP, keyed by group id —
    /// generalizes D13's single `programHostLayer`. Each is registered with
    /// `OutputWindowManager` while present, a sibling of the SwiftUI
    /// content's layer, inserted directly BELOW the panic-overlay layer so
    /// PANIC always covers live program content too.
    private var programHostLayers: [UUID: CALayer] = [:]
    /// D23: one live "chrome" overlay PER MIRRORED GROUP, sibling of that
    /// group's `programHostLayers` entry — the tally border + always-visible
    /// group-name label, painted directly ABOVE the mirrored content
    /// (`programOverlayZPosition`, between `programLayerZPosition` and
    /// `panicLayerZPosition`) so both stay visible over live video. Kept
    /// completely separate from `programHostLayers` — a child of the HOST
    /// layer would corrupt `paneHasContent`'s "any sublayer at all" check
    /// and the D19/D20 tests that pin the host's own `sublayers` contents —
    /// see `ProgramOverlay`'s doc below.
    private var programOverlays: [UUID: ProgramOverlay] = [:]
    /// The always-present (usually invisible) panic-overlay layer, captured
    /// at window-creation time so program layers can be inserted below it.
    private weak var panicLayer: CALayer?
    /// D14: the floating window resizes freely (the fullscreen one never
    /// does), so the manually-positioned program host layers need to be told
    /// to re-lay-out on every resize — this observes exactly that. Nil
    /// whenever the floating presentation isn't the current one.
    private var resizeObserver: NSObjectProtocol?
    /// The settings passed to the most recent `sync` call — kept only so the
    /// resize observer can recompute each program pane's frame without
    /// threading settings through the notification closure.
    private var lastSettings: StageDisplaySettings?

    /// Every output group currently mirrored by an actively-registered
    /// program pane — i.e. the window is open AND that group's pane is
    /// enabled AND the group still exists. `EngineBridge`'s
    /// `stageDisplayProgramGroupIDs` closure reads this (via AppModel) to
    /// decide whether a cue's group should ALSO mirror here. D16 replaces
    /// D13's single `isProgramPaneShowing` Bool. D19: deliberately derived
    /// from `programHostLayers.keys` — the set of groups actually
    /// REGISTERED with `OutputWindowManager` — rather than, say, every
    /// enabled pane in settings. A pane whose registration didn't happen
    /// (the container had no layer, `syncProgramPanes`' guard fired) must
    /// NOT appear here, or `EngineBridge.resolveTargets` would add a
    /// program target that has nowhere to lease a layer from.
    var mirroredProgramGroupIDs: Set<UUID> { Set(programHostLayers.keys) }

    /// D20: whether a group's program pane currently has at least one
    /// mirrored content sublayer actually painting — read by the SwiftUI
    /// placeholder (`StageDisplayContentView.programPane`) so the dim
    /// "PROGRAM · <group>" watermark hides exactly while real content is
    /// there, instead of always painting underneath it (visible through any
    /// gap letterboxing/mis-fit leaves — the reported "stray labels" bug).
    /// A group with no registered host (deleted, or never mirrored) reports
    /// `false`, same as a registered-but-empty one.
    func paneHasContent(groupID: UUID) -> Bool {
        programHostLayers[groupID]?.sublayers?.isEmpty == false
    }

    /// D23: refresh one program pane's above-mirror chrome — tally border +
    /// group-name label — to match its current live state. No-op for a
    /// group with no registered overlay (deleted group, or the window isn't
    /// open). Called from `StageDisplayContentView.programPane`'s existing
    /// 0.5 Hz poll, the SAME cadence `paneHasContent` was already read at
    /// for the D20 "NO SOURCE" watermark — a plain `CALayer` property
    /// write, not a SwiftUI state mutation, so driving it from inside a
    /// `TimelineView` tick doesn't trip SwiftUI's update-during-render
    /// diagnostics (nothing `@Observable` is touched).
    func updateProgramTally(groupID: UUID, label: String, hasContent: Bool) {
        guard let overlay = programOverlays[groupID] else { return }
        Self.applyProgramTally(overlay, label: label, hasContent: hasContent)
    }

    /// Test-only introspection (also handy for future debugging): the
    /// currently-presented window's content container's backing layer, if
    /// any. `internal`, not `public` or `private` — reachable only via
    /// `@testable import` — so a regression test can pin the D19 z-order
    /// invariant (PANIC above PROGRAM above the ordinary panes) against the
    /// REAL, currently-showing window's actual layer tree instead of a
    /// synthetic stand-in. Forces a synchronous display pass first: AppKit
    /// defers syncing a layer-backed view's own subview layers (`content`,
    /// `panic`) into the container's `sublayers` array until the window's
    /// next real display cycle — normally driven by the run loop, which a
    /// synchronous test never spins on its own. Without forcing it here, a
    /// test could read back only the layer this class itself inserted
    /// synchronously (the program pane) and miss the exact append-after
    /// ordering that made suspect 2 possible in the first place. Harmless
    /// to call repeatedly; production code never reads this.
    var debugContainerLayer: CALayer? {
        window?.displayIfNeeded()
        return window?.contentView?.layer
    }

    /// Test-only introspection: the currently-presented window, if any —
    /// lets a regression test drive a REAL resize (`setFrame`) to exercise
    /// the D20 resize-observer reframe path (`repositionProgramPanes`)
    /// exactly like a live operator drag of the floating window would.
    /// `internal`, not `private` — reachable only via `@testable import`.
    var debugWindow: NSWindow? { window }

    /// Test-only introspection: the live content layer registered for one
    /// group's program pane, if any — lets a regression test read back
    /// whatever `attachTarget`/arm-time attached there (D20: pins the
    /// reframe-on-resize fix) without needing a real running window.
    /// `internal`, not `private` — reachable only via `@testable import`.
    func debugProgramHostLayer(for groupID: UUID) -> CALayer? {
        programHostLayers[groupID]
    }

    /// Pure decision: should the stage display window be open right now?
    /// Factored out of `sync` so it's directly testable without creating
    /// any window — edit mode is never active. D14: Rehearsal's floating
    /// window needs no display at all (it doubles as a layout preview with
    /// no rig attached), so only Show mode requires a matched, connected
    /// display.
    static func isActive(mode: WorkspaceMode, settings: StageDisplaySettings, displayConnected: Bool) -> Bool {
        guard settings.enabled else { return false }
        switch mode {
        case .show: return displayConnected
        case .rehearsal: return true
        case .edit: return false
        }
    }

    /// D17: pure "would presenting fullscreen cover the operator's own
    /// window" check — both ids are resolved by the caller (`AppModel`,
    /// which owns the `DisplayManager`/`NSScreen` lookups) so this stays a
    /// plain equality check, directly testable with no window/display
    /// involved. Used both for the Show-mode-entry warning and (via
    /// `AppModel.stageDisplayCoversOperatorScreen`) Preflight.
    static func fullscreenCoversOperatorScreen(
        matchedDisplayID: CGDirectDisplayID?,
        operatorScreenDisplayID: CGDirectDisplayID?
    ) -> Bool {
        guard let matchedDisplayID, let operatorScreenDisplayID else { return false }
        return matchedDisplayID == operatorScreenDisplayID
    }

    /// D18 (FIX 1): which presentation `sync` should use — factored out so
    /// the operator-trap fix (never fullscreen over the operator's own
    /// screen) is a plain, directly-testable decision with no window,
    /// display, or `NSApp` lookups involved.
    enum Style: Equatable {
        case fullscreen
        case floating
    }

    /// Show mode presents fullscreen ONLY when the matched display is
    /// affirmatively known to be a DIFFERENT screen than the operator's own
    /// window. Both failure modes — the matched screen IS the operator
    /// screen, or the operator screen can't be resolved at all (e.g. at
    /// launch, before the main window exists) — fall back to the same
    /// floating presentation Rehearsal already uses. Floating is the safe
    /// default: it never fights the operator for the screen, so there's
    /// nothing that can trap the local key monitor behind an opaque,
    /// click-through, non-activating window. Rehearsal is always floating,
    /// unchanged from D14.
    static func presentationStyle(
        mode: WorkspaceMode, matchedScreenIsOperatorScreen: Bool, operatorScreenKnown: Bool
    ) -> Style {
        switch mode {
        case .show:
            return (!matchedScreenIsOperatorScreen && operatorScreenKnown) ? .fullscreen : .floating
        case .rehearsal, .edit:
            return .floating
        }
    }

    /// Reconcile the window with the current settings, activity state, and
    /// mode. `active` must already fold in mode + `settings.enabled` +
    /// display connectivity (see `isActive`) — callers compute it once
    /// (AppModel's `syncStageDisplay`) and pass it straight through. `mode`
    /// additionally picks WHICH presentation to show while active: Show
    /// prefers borderless-fullscreen on the matched display, falling back to
    /// the same floating presentation Rehearsal uses whenever `presentationStyle`
    /// (D18, FIX 1) says fullscreen would land on the operator's own screen
    /// (or that can't yet be determined) — never leave the operator with no
    /// way to see their own controls. `operatorScreenDisplayID` is resolved
    /// by the caller (`AppModel`) exactly like `fullscreenCoversOperatorScreen`
    /// already required. `outputGroups` (D16) is the show's current
    /// output-group list — needed to tell a live group's program pane apart
    /// from a deleted one (see `syncProgramPanes`).
    func sync(
        settings: StageDisplaySettings, outputGroups: [OutputGroup], active: Bool, mode: WorkspaceMode,
        operatorScreenDisplayID: CGDirectDisplayID?
    ) {
        lastSettings = settings
        guard active else {
            close()
            return
        }
        switch mode {
        case .show:
            guard let fingerprint = settings.display,
                  let matched = DisplayManager.shared.match(fingerprint) else {
                close()
                return
            }
            let matchedIsOperatorScreen = Self.fullscreenCoversOperatorScreen(
                matchedDisplayID: matched.displayID, operatorScreenDisplayID: operatorScreenDisplayID
            )
            let style = Self.presentationStyle(
                mode: mode,
                matchedScreenIsOperatorScreen: matchedIsOperatorScreen,
                operatorScreenKnown: operatorScreenDisplayID != nil
            )
            switch style {
            case .fullscreen:
                presentFullscreen(on: matched, settings: settings, outputGroups: outputGroups)
            case .floating:
                presentFloating(settings: settings, outputGroups: outputGroups)
            }
        case .rehearsal:
            presentFloating(settings: settings, outputGroups: outputGroups)
        case .edit:
            // Unreachable — `isActive` is false in edit mode — but never
            // leave a stale window open if this is ever called anyway.
            close()
        }
    }

    private func presentFullscreen(on matched: ConnectedDisplay, settings: StageDisplaySettings, outputGroups: [OutputGroup]) {
        if let window, currentPresentation == .fullscreen(matched.displayID) {
            // Same display: re-assert the frame so a mode/resolution change
            // (reconfiguration storm) doesn't leave it mis-sized.
            window.setFrame(matched.screen.frame, display: true)
            syncProgramPanes(settings: settings, outputGroups: outputGroups, in: window)
            return
        }
        close()
        let (newWindow, panic) = Self.makeFullscreenWindow(screen: matched.screen, appModel: appModel)
        window = newWindow
        panicLayer = panic
        currentPresentation = .fullscreen(matched.displayID)
        syncProgramPanes(settings: settings, outputGroups: outputGroups, in: newWindow)
    }

    private func presentFloating(settings: StageDisplaySettings, outputGroups: [OutputGroup]) {
        if let window, currentPresentation == .floating {
            syncProgramPanes(settings: settings, outputGroups: outputGroups, in: window)
            return
        }
        close()
        let (newWindow, panic) = Self.makeFloatingWindow(appModel: appModel)
        window = newWindow
        panicLayer = panic
        currentPresentation = .floating
        observeResize(of: newWindow)
        syncProgramPanes(settings: settings, outputGroups: outputGroups, in: newWindow)
    }

    private func close() {
        guard let window else { return }
        teardownAllProgramPanes()
        stopObservingResize()
        window.orderOut(nil)
        window.close()
        self.window = nil
        self.panicLayer = nil
        currentPresentation = nil
    }

    /// D14: re-lay the program pane's host layer on every floating-window
    /// resize — the fullscreen window never resizes by user action so this
    /// is only ever wired up for the floating presentation (see
    /// `presentFloating`/`stopObservingResize`). Mirrors the resize-tracking
    /// idiom `VirtualCameraManager` already uses for its monitor panel: hop
    /// to `@MainActor` explicitly since `NotificationCenter`'s closure
    /// parameter is `@Sendable`, even though `queue: .main` guarantees this
    /// always actually runs on the main thread.
    private func observeResize(of window: NSWindow) {
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.repositionProgramPanes()
            }
        }
    }

    private func stopObservingResize() {
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
            self.resizeObserver = nil
        }
    }

    /// D16: reposition every currently-registered program layer — never
    /// creates or retires one (that only happens in `syncProgramPanes`,
    /// which needs `outputGroups` this resize path doesn't have handy; an
    /// existing layer's group can't have been deleted mid-resize without a
    /// settings change, which already re-enters `sync` on its own).
    private func repositionProgramPanes() {
        guard let window, let container = window.contentView, let settings = lastSettings else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for pane in settings.programPanes where pane.enabled {
            guard let groupID = pane.programGroupID, let layer = programHostLayers[groupID] else { continue }
            let frame = StageDisplayGeometry.appKitFrame(for: pane.rect, in: container.bounds.size)
            layer.frame = frame
            Self.reframeMirroredContent(host: layer)
            if let overlay = programOverlays[groupID] {
                Self.reframeProgramOverlay(overlay, frame: frame)
            }
        }
        CATransaction.commit()
    }

    /// Register/reposition/retire each mirrored group's live content layer
    /// to match `settings.programPanes`. Safe to call every time settings
    /// change while the window is open — that's how live drag-edits from
    /// the layout editor, and toggling a group's mirror checkbox, reach it
    /// (`AppModel.updateStageDisplay` always calls back through `sync`). A
    /// pane whose group no longer exists in `outputGroups` (deleted) is left
    /// registering nothing — the SwiftUI content view alone renders its
    /// "PROGRAM · (deleted)" placeholder; see `StageDisplayContentView`.
    private func syncProgramPanes(settings: StageDisplaySettings, outputGroups: [OutputGroup], in window: NSWindow) {
        guard let container = window.contentView, let containerLayer = container.layer else {
            // D19: this must be unreachable. `makeContentContainer` sets
            // `wantsLayer = true` on the container AT CREATION, before this
            // window is ever handed back to `presentFullscreen`/
            // `presentFloating` — that synchronously materializes
            // `container.layer` (verified: NSView creates its backing layer
            // the instant `wantsLayer` flips true, no display pass needed),
            // so `window.contentView` can never legitimately have a nil
            // layer here. If this guard ever fires it means SOME future
            // change replaced/rebuilt the container without going through
            // `makeContentContainer` — and the consequence is severe and
            // silent: no external host ever registers, `mirroredProgramGroupIDs`
            // stays permanently empty, so every program pane forever shows
            // only its placeholder with no error anywhere (this is exactly
            // what the D19 bug report described). Trip loudly in debug
            // builds; still degrade safely (teardown, no crash) in release.
            assertionFailure(
                "StageDisplayController.syncProgramPanes: content container has no backing layer — " +
                "stage-display mirroring cannot register any program pane. See makeContentContainer."
            )
            teardownAllProgramPanes()
            return
        }

        var liveByGroup: [UUID: StageDisplayPane] = [:]
        for pane in settings.programPanes where pane.enabled {
            guard let groupID = pane.programGroupID else { continue }
            liveByGroup[groupID] = pane
        }

        let staleGroupIDs = programHostLayers.keys.filter { liveByGroup[$0] == nil }
        for groupID in staleGroupIDs {
            teardownProgramPane(for: groupID)
        }

        let liveGroupIDs = Set(outputGroups.map(\.id))
        for (groupID, pane) in liveByGroup {
            let frame = StageDisplayGeometry.appKitFrame(for: pane.rect, in: container.bounds.size)
            if let layer = programHostLayers[groupID] {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.frame = frame
                Self.reframeMirroredContent(host: layer)
                if let overlay = programOverlays[groupID] {
                    Self.reframeProgramOverlay(overlay, frame: frame)
                }
                CATransaction.commit()
                continue
            }
            // A deleted group's pane persists (so the operator can see it
            // and remove/reassign it) but mirrors nothing — no layer, no
            // registration.
            guard liveGroupIDs.contains(groupID) else { continue }

            let layer = CALayer()
            layer.frame = frame
            // D19 (suspect 2): explicit zPosition, NOT array order, is what
            // actually guarantees this layer paints above the ordinary panes
            // and below PANIC. `container` is a layer-backed NSView that
            // ALSO owns two layer-backed subviews (`content`, `panic`) —
            // AppKit inserts each subview's own layer into `containerLayer`
            // LAZILY (on the next display pass), not synchronously when
            // `addSubview` runs. This raw layer is inserted synchronously,
            // right now, via `insertSublayer(below:)` — but at THIS point
            // `panicLayer` (if not yet synced by AppKit) may not actually be
            // a member of `containerLayer.sublayers` yet, so the `below:`
            // reference silently falls back to append-at-end. When AppKit
            // later performs its own sync, it appends `content`'s and
            // `panic`'s layers AFTER whatever is already there — burying
            // this layer under `content`'s opaque black background,
            // permanently invisible, no error anywhere (reproduced directly
            // against a throwaway AppKit window while diagnosing D19: the
            // final sublayers array came out [PROGRAM, CONTENT, PANIC] even
            // though this call inserted PROGRAM "below" PANIC). zPosition
            // sidesteps the whole timing question: CALayer paints by
            // zPosition when set, regardless of array index. Ordinary panes
            // (`content`) stay at the CALayer default, 0.
            layer.zPosition = Self.programLayerZPosition
            // D23: tiny corner radius, matching every other multiview tile
            // — clipped so live mirrored content doesn't square off past the
            // rounded chrome painted around it (see `ProgramOverlay` below).
            layer.cornerRadius = StageDisplayChrome.cornerRadius
            layer.masksToBounds = true
            if let panicLayer {
                containerLayer.insertSublayer(layer, below: panicLayer)
            } else {
                containerLayer.addSublayer(layer)
            }
            programHostLayers[groupID] = layer
            OutputWindowManager.shared.registerExternalHost(layer, for: Self.programTarget(for: groupID))

            // D23: the paired above-mirror chrome — tally border + always-
            // visible group-name label — a SIBLING of `layer`, never a
            // child (see `programOverlays`' doc for why). `outputGroups` is
            // already in hand here so the label starts correct immediately;
            // `updateProgramTally` (driven by the SwiftUI placeholder's
            // existing poll) keeps it live afterward, including group
            // renames and the tally border's on-air/idle color.
            let groupName = outputGroups.first(where: { $0.id == groupID })?.name ?? "(deleted)"
            let overlay = Self.makeProgramOverlay(frame: frame)
            overlay.root.zPosition = Self.programOverlayZPosition
            if let panicLayer {
                containerLayer.insertSublayer(overlay.root, below: panicLayer)
            } else {
                containerLayer.addSublayer(overlay.root)
            }
            Self.applyProgramTally(overlay, label: groupName, hasContent: false)
            programOverlays[groupID] = overlay
        }
    }

    private func teardownProgramPane(for groupID: UUID) {
        guard let layer = programHostLayers[groupID] else { return }
        OutputWindowManager.shared.unregisterExternalHost(for: Self.programTarget(for: groupID))
        layer.removeFromSuperlayer()
        programHostLayers[groupID] = nil
        if let overlay = programOverlays[groupID] {
            overlay.root.removeFromSuperlayer()
            programOverlays[groupID] = nil
        }
    }

    private func teardownAllProgramPanes() {
        for groupID in Array(programHostLayers.keys) {
            teardownProgramPane(for: groupID)
        }
    }

    /// D19: explicit stacking constants used both here and in
    /// `syncProgramPanes` — see the long comment there for WHY array order
    /// alone can't be trusted. Ordinary panes (the SwiftUI content view)
    /// stay at the CALayer default, 0; program panes sit above them; PANIC
    /// sits above everything. `internal`, not `private`, purely so a
    /// regression test can assert against the real constants rather than a
    /// duplicated magic number.
    static let programLayerZPosition: CGFloat = 100
    static let panicLayerZPosition: CGFloat = 1000
    /// D23: the above-mirror chrome (tally border + group-name label) sits
    /// strictly between the mirrored content and PANIC — visible over live
    /// video, but still covered the instant the operator panics.
    static let programOverlayZPosition: CGFloat = 200

    // MARK: - D23: program-pane chrome (tally border + always-visible label)

    /// A program pane's above-mirror chrome — `root` is a SIBLING of that
    /// group's `programHostLayers` entry (same frame, transparent fill,
    /// `programOverlayZPosition`), never a child: `paneHasContent` reads
    /// the host's `sublayers` directly to mean "is a player actually
    /// mirroring here", and `MirrorIntegrationTests` pins the host's
    /// `sublayers` to hold ONLY the mirrored player content (nothing else)
    /// both while attached and after a stop — a label/border living inside
    /// the host would corrupt both. `labelBackground`/`labelText` are kept
    /// as separate layers (rather than baked into one) so `reframeProgramOverlay`
    /// can resize the label strip without touching the border-carrying `root`.
    struct ProgramOverlay {
        let root: CALayer
        let labelBackground: CALayer
        let labelText: CATextLayer
    }

    private static func makeProgramOverlay(frame: CGRect) -> ProgramOverlay {
        let root = CALayer()
        root.backgroundColor = nil   // transparent — only the border ring + label strip paint.
        root.cornerRadius = StageDisplayChrome.cornerRadius
        root.masksToBounds = true    // keeps the label strip's corners clipped to match the tile.

        let labelBackground = CALayer()
        labelBackground.backgroundColor = StageDisplayChrome.labelBackgroundCG
        root.addSublayer(labelBackground)

        let labelText = CATextLayer()
        labelText.alignmentMode = .center
        labelText.truncationMode = .end
        labelText.foregroundColor = StageDisplayChrome.labelTextCG
        labelText.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        labelText.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        labelBackground.addSublayer(labelText)

        let overlay = ProgramOverlay(root: root, labelBackground: labelBackground, labelText: labelText)
        Self.reframeProgramOverlay(overlay, frame: frame)
        return overlay
    }

    /// Re-lay the overlay's own frame AND its label strip's size (which
    /// scales with the tile, like every other pane's label bar) — called
    /// alongside `reframeMirroredContent` everywhere the host's frame
    /// changes: initial creation, a live pane-rect edit, and floating-window
    /// resize.
    private static func reframeProgramOverlay(_ overlay: ProgramOverlay, frame: CGRect) {
        // Unlike `reframeMirroredContent` (which must avoid `.frame` because
        // a MIRRORED player's layer can carry a non-identity transform),
        // this overlay is entirely ours and never transformed — plain
        // `.frame` is correct and simplest.
        overlay.root.frame = frame
        let barHeight = max(14, frame.height * 0.09)
        overlay.labelBackground.frame = CGRect(x: 0, y: 0, width: frame.width, height: barHeight)
        overlay.labelText.frame = overlay.labelBackground.bounds
        overlay.labelText.fontSize = max(9, min(13, barHeight * 0.5))
    }

    /// Push the current tally + group name onto one program pane's overlay.
    /// A plain `CALayer`/`CATextLayer` property write — cheap and safe to
    /// call every poll tick even when nothing actually changed.
    private static func applyProgramTally(_ overlay: ProgramOverlay, label: String, hasContent: Bool) {
        let tally = StageDisplayTally.program(hasContent: hasContent)
        overlay.root.borderWidth = tally.borderWidth
        overlay.root.borderColor = tally.borderColorCG
        // A crude but dependency-free approximation of SwiftUI's `.tracking`
        // letter-spacing — `CATextLayer` has no kerning property for a plain
        // `String`, and reaching for an `NSAttributedString` here would mean
        // re-deriving the font/size/color on every reframe instead of the
        // plain `.fontSize` property `reframeProgramOverlay` already updates.
        let spaced = label.uppercased().map(String.init).joined(separator: "\u{2009}")
        if overlay.labelText.string as? String != spaced {
            overlay.labelText.string = spaced
        }
    }

    /// D20: re-frame every DIRECT sublayer of a program host layer to match
    /// the host's own CURRENT bounds — called right after the host itself is
    /// re-framed, both when the floating window resizes
    /// (`repositionProgramPanes`) and when a pane's rect is edited live while
    /// running (`syncProgramPanes`'s existing-layer branch). Without this, a
    /// mirrored player's content layer (an `AVPlayerLayer` for video, a plain
    /// `CALayer` for text/still, or a camera's container layer) keeps
    /// whatever frame it had at ATTACH time forever — misplaced/mis-scaled
    /// the moment the pane's on-screen size changes (the reported "content
    /// doesn't scale when resizing the floating window" bug).
    ///
    /// Sets `bounds` + `position`, deliberately NOT `frame`: a mirrored
    /// player's layer CAN carry a non-identity `transform` (a video/text/
    /// still cue authored with Custom geometry, mirrored while it happens to
    /// already be arm-time-targeted at this host — see `EngineBridge.
    /// extraTargets`), and Apple's own documentation states `CALayer.frame`
    /// is undefined whenever `transform` isn't the identity transform.
    /// `PreviewContentView.layout()` already hits this exact case for
    /// rehearsal preview windows and uses bounds+position for the same
    /// reason — this mirrors that established convention instead of
    /// reintroducing the bug in a second place.
    ///
    /// Only reframes ONE level deep: a camera cue's mirrored container has
    /// its own preview/content sublayers with `autoresizingMask` already set
    /// RELATIVE TO THE CONTAINER, so changing the container's `bounds` here
    /// makes CALayer's own (built-in, no NSView required) autoresizing
    /// propagate the rest — see `CameraCuePlayer.init`/`attachTarget`.
    ///
    /// `internal`, not `private`, so `MirrorIntegrationTests` can exercise it
    /// directly against a synthetic layer tree. Must run inside the caller's
    /// own `CATransaction` (already disabling implicit actions) — this opens
    /// none of its own.
    static func reframeMirroredContent(host: CALayer) {
        guard let sublayers = host.sublayers else { return }
        for sublayer in sublayers {
            sublayer.bounds = CGRect(origin: .zero, size: host.bounds.size)
            sublayer.position = CGPoint(x: host.bounds.midX, y: host.bounds.midY)
        }
    }

    /// Builds a PLAIN (non-flipped, standard AppKit y-up) container view
    /// hosting two SwiftUI layers — the ordinary panes (bottom) and an
    /// always-present panic overlay (top) — sized to `size`. The live
    /// program-pane layer is inserted directly BETWEEN them once registered
    /// (see `syncProgramPane`), so PANIC always visually wins regardless of
    /// what's playing into the program pane. Using a plain container
    /// (rather than handing the program layer straight to the
    /// NSHostingView's own layer) keeps our raw CALayer out of SwiftUI's
    /// internally-managed layer tree entirely. Shared by both presentations
    /// (D14) — only the enclosing window differs. `internal`, not
    /// `private`, so a test can construct one directly (no window shown) to
    /// pin the D19 container-layer invariant below.
    static func makeContentContainer(size: CGSize, appModel: AppModel?) -> (container: NSView, panicLayer: CALayer?) {
        let container = NSView(frame: CGRect(origin: .zero, size: size))
        // D19 (suspect 1): MUST happen before anything else touches this
        // view, and before this container is ever handed to
        // `syncProgramPanes`. Setting `wantsLayer = true` synchronously
        // materializes the backing CALayer — verified directly: the layer
        // exists the instant this line runs, no window, no display pass, no
        // async delay required. `syncProgramPanes`' registration guard
        // depends entirely on that: without it, `container.layer` would be
        // nil forever, and every program pane would silently register no
        // external host, permanently, with no error anywhere.
        container.wantsLayer = true

        var panicLayer: CALayer?
        if let appModel {
            let content = NSHostingView(
                rootView: StageDisplayContentView()
                    .environment(appModel)
                    .environment(appModel.document)
            )
            content.frame = container.bounds
            content.autoresizingMask = [.width, .height]
            // Ordinary panes stay at the CALayer default zPosition (0) — the
            // baseline every program pane (100) and PANIC (1000) stack above.
            container.addSubview(content)

            let panic = NSHostingView(rootView: StageDisplayPanicOverlay().environment(appModel))
            panic.frame = container.bounds
            panic.autoresizingMask = [.width, .height]
            // D19 (suspect 2): explicit zPosition — see `syncProgramPanes`
            // for why array order can't be trusted to keep this on top.
            panic.layer?.zPosition = Self.panicLayerZPosition
            container.addSubview(panic)
            panicLayer = panic.layer
        }
        return (container, panicLayer)
    }

    /// Show mode: borderless, non-activating, fullscreen on the matched display.
    private static func makeFullscreenWindow(screen: NSScreen, appModel: AppModel?) -> (window: NSWindow, panicLayer: CALayer?) {
        let window = StageDisplayNSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.level = windowLevel
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isOpaque = true
        window.backgroundColor = .black
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.isReleasedWhenClosed = false

        let (container, panicLayer) = makeContentContainer(size: screen.frame.size, appModel: appModel)
        window.contentView = container

        // init(contentRect:screen:) interprets the rect relative to
        // `screen`; normalize to global coordinates like OutputWindowManager.
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        return (window, panicLayer)
    }

    /// D14, Rehearsal mode: floating, titled, resizable — needs no display
    /// at all, matching `OutputWindowManager.makePreviewWindow`'s panel
    /// convention exactly (level, `isFloatingPanel`, `becomesKeyOnlyIfNeeded`,
    /// `hidesOnDeactivate = false`, and — deliberately, like preview windows
    /// — NO `.closable` in the style mask: the user can move/resize it but
    /// not close it, so there's nothing to reopen or flip in settings; it
    /// simply tracks `syncStageDisplay` like any other presentation).
    private static func makeFloatingWindow(appModel: AppModel?) -> (window: NSWindow, panicLayer: CALayer?) {
        let defaultFrame = CGRect(x: 120, y: 120, width: 720, height: 405)
        let window = StageDisplayFloatingWindow(
            contentRect: defaultFrame,
            styleMask: [.titled, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "Stage Display"
        window.level = .floating
        window.isFloatingPanel = true
        window.becomesKeyOnlyIfNeeded = true
        // Panels hide on app deactivate by default — like the rehearsal
        // preview panels, this must stay visible while the operator works
        // in other apps (e.g. checking notes in another window).
        window.hidesOnDeactivate = false
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 320, height: 180)

        let (container, panicLayer) = makeContentContainer(size: defaultFrame.size, appModel: appModel)
        window.contentView = container

        // Remember the operator's arrangement across sessions, exactly like
        // a rehearsal preview panel's per-group autosave name.
        window.setFrameAutosaveName("StageWizard.StageDisplay.rehearsal")
        window.orderFront(nil)
        return (window, panicLayer)
    }
}

/// Convert a normalized, Y-DOWN (top-left origin) `StageRect` — how every
/// stage-display pane is authored, see `StageDisplayPane` — into an AppKit
/// Y-UP (bottom-left origin) point-space frame within a container of the
/// given size. Pure function, factored out for direct unit testing.
enum StageDisplayGeometry {
    static func appKitFrame(for rect: StageRect, in containerSize: CGSize) -> CGRect {
        let width = rect.width * containerSize.width
        let height = rect.height * containerSize.height
        let x = rect.x * containerSize.width
        // The rect's TOP edge is `rect.y * height` down from the container's
        // top; AppKit measures UP from the bottom, so the frame's origin is
        // the container height minus the rect's BOTTOM edge (top + height).
        let y = containerSize.height - (rect.y * containerSize.height) - height
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

// MARK: - Content

/// The stage display's SwiftUI content — PANE-DRIVEN (D13): each enabled
/// pane is positioned at its own normalized rect instead of a fixed
/// top/hero/bottom layout. Reads transport/document state live via the
/// environment, reusing exactly the accessors ActiveCuesPanel /
/// StandingByHeader / TransportSidebar already read — no new runtime
/// queries. Black background, white/gray text, every pane's fonts sized
/// relative to ITS OWN rect so it reads at a glance regardless of how the
/// operator arranges the layout. PANIC is NOT handled here — it's a
/// separate always-on-top overlay (`StageDisplayPanicOverlay`) so it
/// visually wins over the live program pane too, which lives in a raw
/// CALayer outside this view's own tree.
struct StageDisplayContentView: View {
    @Environment(AppModel.self) private var app
    @Environment(ShowDocumentController.self) private var document

    private var settings: StageDisplaySettings { document.show.settings.stageDisplay }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.black
                // Non-program kinds: exactly one pane each, unchanged from D13.
                ForEach(StageDisplayPaneKind.allCases.filter { $0 != .program }, id: \.self) { kind in
                    let pane = settings.pane(kind)
                    if pane.enabled {
                        positioned(pane, in: geo) { size in paneView(kind, size: size) }
                    }
                }
                // D16: zero or more program panes, one per mirrored group —
                // each drawn independently so multiple are tellable apart.
                ForEach(settings.programPanes) { pane in
                    if pane.enabled {
                        positioned(pane, in: geo) { size in programPane(pane, size: size) }
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
    }

    /// Shared sizing/positioning for a pane's content, factored out so both
    /// the single-per-kind loop and the multi-program-pane loop place their
    /// content identically.
    @ViewBuilder
    private func positioned<Content: View>(
        _ pane: StageDisplayPane, in geo: GeometryProxy, @ViewBuilder content: (CGSize) -> Content
    ) -> some View {
        let size = CGSize(
            width: geo.size.width * pane.rect.width,
            height: geo.size.height * pane.rect.height
        )
        content(size)
            .frame(width: size.width, height: size.height)
            .position(
                x: geo.size.width * (pane.rect.x + pane.rect.width / 2),
                y: geo.size.height * (pane.rect.y + pane.rect.height / 2)
            )
    }

    @ViewBuilder
    private func paneView(_ kind: StageDisplayPaneKind, size: CGSize) -> some View {
        switch kind {
        case .clock: clockPane(size: size)
        case .showTimer: showTimerPane(size: size)
        case .standingBy: standingByPane(size: size)
        case .notes: notesPane(size: size)
        case .running: runningPane(size: size)
        case .program: EmptyView() // unreachable — program panes render via the dedicated ForEach above.
        case .gesture: gesturePane(size: size)
        }
    }

    // D23: every non-program pane wears the same "ATEM-style multiview"
    // tile chrome (`MultiviewTile`, see `StageDisplayChrome.swift`) — a
    // near-black background, thin border (tally-colored where the pane
    // calls for one), tiny corner radius, and a bottom-center label bar.
    // A program pane's own tally border + label live in a raw CALayer
    // ABOVE its mirrored content instead (`programPane` below,
    // `StageDisplayController.ProgramOverlay`) since SwiftUI content here
    // paints strictly BELOW that mirror layer — see this file's z-order
    // notes on `StageDisplayController.syncProgramPanes`.

    // MARK: Clock

    private func clockPane(size: CGSize) -> some View {
        MultiviewTile(label: "CLOCK", size: size) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(StageDisplayFormat.wallClock(context.date))
                    .font(.system(size: size.height * 0.6, weight: .heavy, design: .monospaced))
                    .monospacedDigit()
                    .minimumScaleFactor(0.3)
                    .lineLimit(1)
                    .foregroundStyle(.white)
            }
        }
    }

    // MARK: Show timer

    private func showTimerPane(size: CGSize) -> some View {
        MultiviewTile(label: "SHOW TIMER", size: size) {
            if let startedAt = app.showModeEnteredAt {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text(StageDisplayFormat.elapsed(from: startedAt, to: context.date))
                        .font(.system(size: size.height * 0.55, weight: .heavy, design: .monospaced))
                        .monospacedDigit()
                        .minimumScaleFactor(0.3)
                        .lineLimit(1)
                        .foregroundStyle(.white)
                }
            }
        }
    }

    // MARK: Standing by — the hero pane

    private func standingByPane(size: CGSize) -> some View {
        let tally = StageDisplayTally.standingBy(hasStandingByCue: app.transport.standingByCue != nil)
        return MultiviewTile(label: "STANDING BY", tally: tally, size: size) {
            VStack(spacing: size.height * 0.04) {
                if let cue = app.transport.standingByCue {
                    // D20: the cue number moves LEFT of the name on the same
                    // baseline row, and grows to roughly half the name's size
                    // (was a small caption-sized line above it) — everything
                    // about how the NAME itself is sized (`minimumScaleFactor`,
                    // `lineLimit`, alignment) is unchanged.
                    HStack(alignment: .firstTextBaseline, spacing: size.width * 0.03) {
                        Text(cue.number)
                            .font(.system(size: size.height * 0.25, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.gray)
                            .lineLimit(1)
                        Text(cue.displayName)
                            .font(.system(size: size.height * 0.5, weight: .bold))
                            .minimumScaleFactor(0.15)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)
                    }
                } else if app.transport.isPlayheadPastEnd {
                    Text("END OF SHOW")
                        .font(.system(size: size.height * 0.22, weight: .bold))
                        .foregroundStyle(.gray)
                } else {
                    Text("—")
                        .font(.system(size: size.height * 0.3, weight: .bold))
                        .foregroundStyle(.gray)
                }
            }
        }
    }

    // MARK: Notes — the standing-by cue's notes, its own pane

    private func notesPane(size: CGSize) -> some View {
        let notes = app.transport.standingByCue.flatMap { document.cue(withID: $0.id)?.notes } ?? ""
        return MultiviewTile(label: "NOTES", size: size) {
            if !notes.isEmpty {
                Text(notes)
                    .font(.system(size: size.height * 0.3))
                    .minimumScaleFactor(0.4)
                    .lineLimit(4)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.gray)
                    .padding(.horizontal, size.width * 0.05)
            }
        }
    }

    // MARK: Running cues

    private func runningPane(size: CGSize) -> some View {
        MultiviewTile(label: "RUNNING", size: size) {
            if !app.transport.registry.isEmpty {
                TimelineView(.periodic(from: .now, by: 0.1)) { context in
                    VStack(alignment: .leading, spacing: size.height * 0.04) {
                        ForEach(app.transport.registry.instances) { instance in
                            StageDisplayRunningRow(
                                instance: instance,
                                rowFontSize: size.height * 0.14,
                                now: context.date
                            )
                        }
                    }
                    .padding(size.width * 0.04)
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
                }
            }
        }
    }

    // MARK: Program — placeholder; the LIVE layer (and its tally border +
    // label) are hosted outside SwiftUI entirely.

    /// Multiview tile background + a very dim centered "NO SOURCE"
    /// watermark, shown only while idle. D23: the tile's tally border (red
    /// while on air) and its bottom-center GROUP-NAME label — the two
    /// things that must stay visible even when a live video mirror is
    /// filling this exact rect — are NOT drawn here. They're painted by
    /// `StageDisplayController.ProgramOverlay`, a raw CALayer sibling of
    /// the mirror layer sitting strictly ABOVE it (`programOverlayZPosition`
    /// between `programLayerZPosition` and `panicLayerZPosition`); anything
    /// drawn in THIS SwiftUI view paints at the ordinary-content zPosition
    /// (0), strictly BELOW the mirror (100), so it would be invisible the
    /// instant the group goes live. `updateProgramTally` below pushes this
    /// same `hasContent` read (and the live group name) onto that overlay
    /// every tick, so both halves of the chrome stay in lockstep despite
    /// living in two different rendering systems.
    private func programPane(_ pane: StageDisplayPane, size: CGSize) -> some View {
        let groupName = pane.programGroupID.flatMap { document.show.settings.group(withID: $0)?.name } ?? "(deleted)"
        let groupID = pane.programGroupID
        // D20: the watermark must stop painting the instant real content is
        // mirrored, or it shows through any gap letterboxing/mis-fit leaves
        // (the reported "stray labels from video sources" bug). Polled at
        // ~2 Hz like the other periodically-updating panes rather than
        // driving new state on every layer-tree change.
        return TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let hasContent = groupID.map { app.stageDisplayController.paneHasContent(groupID: $0) } ?? false
            // A plain `let` declaration (not an `if` statement) so this
            // side-effecting CALayer push never has to type-check as View
            // content under `@ViewBuilder` — matches the well-known
            // `let _ = …` idiom for running non-View code inside a
            // ViewBuilder closure.
            let _ = groupID.map { app.stageDisplayController.updateProgramTally(groupID: $0, label: groupName, hasContent: hasContent) }
            ZStack {
                StageDisplayChrome.tileBackground
                if !hasContent {
                    Text("NO SOURCE")
                        .font(.system(size: size.height * 0.14, weight: .semibold, design: .monospaced))
                        .tracking(2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.4)
                        .foregroundStyle(.white.opacity(0.12))
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: StageDisplayChrome.cornerRadius, style: .continuous))
        }
    }

    // MARK: Gesture (D15) — live gesture-GO readout: the pre-warm timer.

    /// `app.gestureReadout` already arrives throttled to ~10 Hz from the
    /// capture pipeline (see `CameraFrameProcessor.deliverReadoutIfDue`), so
    /// this pane reads it directly (like `standingByPane`/`notesPane`)
    /// rather than driving its own `TimelineView` tick.
    private func gesturePane(size: CGSize) -> some View {
        MultiviewTile(label: "GESTURE", size: size) {
            if let readout = app.gestureReadout {
                VStack(alignment: .leading, spacing: size.height * 0.06) {
                    HStack(spacing: size.width * 0.05) {
                        Image(systemName: readout.goGesture.symbolName)
                            .font(.system(size: size.height * 0.30, weight: .semibold))
                        Text(readout.goGesture.label.uppercased())
                            .font(.system(size: size.height * 0.13, weight: .semibold, design: .monospaced))
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                        Spacer(minLength: 0)
                    }
                    GeometryReader { barGeo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Color.white.opacity(0.15))
                            Rectangle()
                                .fill(Theme.accent)
                                .frame(width: barGeo.size.width * readout.holdProgress)
                        }
                    }
                    .frame(height: max(3, size.height * 0.09))
                    .clipShape(Capsule())
                    HStack(spacing: size.width * 0.05) {
                        if readout.cooldownRemaining > 0 {
                            Text(String(format: "COOLDOWN %.1f s", readout.cooldownRemaining))
                                .font(.system(size: size.height * 0.11, design: .monospaced))
                                .foregroundStyle(.gray)
                        }
                        let others = readout.detected.filter { $0 != readout.goGesture }
                        ForEach(others, id: \.self) { gesture in
                            Image(systemName: gesture.symbolName)
                                .font(.system(size: size.height * 0.13))
                                .foregroundStyle(.gray)
                        }
                    }
                }
                .foregroundStyle(.white)
                .padding(size.width * 0.05)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
            }
        }
    }
}

/// Always-present, full-screen, on-top-of-everything panic indicator —
/// including the program pane's live CALayer, which is NOT part of this
/// view's own SwiftUI tree and would otherwise sit above it. Renders
/// nothing while not panicking (a transparent NSHostingView), so it never
/// steals visibility from the ordinary panes.
struct StageDisplayPanicOverlay: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        GeometryReader { geo in
            if app.transport.isPanicking {
                ZStack {
                    Theme.panic
                    Text("PANIC")
                        .font(.system(size: geo.size.height * 0.12, weight: .black, design: .monospaced))
                        .tracking(4)
                        .foregroundStyle(.white)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// One running-cue row: number, name, remaining time, thin progress bar.
/// A dedicated `View` (not a helper function) so the stored `now` property
/// forces SwiftUI to re-read `instance.duration`/`elapsed` every 10 Hz tick
/// — mirrors ActiveCuesPanel's `ActiveCueRow`, same reasoning documented there.
///
/// D23: the bar is styled as a broadcast METER, not a pill — a thin
/// rectangular bright-on-dark track (no capsule clip), turning red in the
/// final stretch like a countdown running low, with a hairline rule
/// separating each row from the next.
private struct StageDisplayRunningRow: View {
    let instance: CueInstance
    let rowFontSize: CGFloat
    /// Timeline tick — unused directly, but its change forces re-render.
    let now: Date

    var body: some View {
        let duration = instance.duration
        let elapsed = instance.elapsed
        let infinite = StageDisplayFormat.isInfiniteLoop(instance.cue)
        let fraction: Double? = duration.flatMap { d in
            (d > 0 && !infinite) ? min(max((elapsed ?? 0) / d, 0), 1) : nil
        }
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(instance.cue.number)
                    .font(.system(size: rowFontSize, weight: .bold, design: .monospaced))
                Text(instance.cue.displayName)
                    .font(.system(size: rowFontSize))
                    .lineLimit(1)
                Spacer()
                Text(StageDisplayFormat.remaining(duration: duration, elapsed: elapsed, infiniteLoop: infinite))
                    .font(.system(size: rowFontSize, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
            }
            .foregroundStyle(.white)
            GeometryReader { barGeo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.white.opacity(0.1))
                    if let fraction {
                        Rectangle()
                            .fill(fraction > 0.85 ? Theme.panic : Color.white)
                            .frame(width: barGeo.size.width * fraction)
                    }
                }
            }
            .frame(height: max(3, rowFontSize * 0.22))
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
                .padding(.top, 2)
        }
    }
}

// MARK: - Pure formatting / decision helpers (unit-tested directly)

enum StageDisplayFormat {
    /// "HH:MM:SS" 24-hour wall clock — always zero-padded base-10, never
    /// locale-dependent; a stage clock must read the same for every operator.
    static func wallClock(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    /// Elapsed "HH:MM:SS" between two dates — the show timer readout.
    static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }

    /// A running cue's remaining-time readout: "∞" for indefinite/looping
    /// playback (no knowable end), else "M:SS" counting down to zero.
    static func remaining(duration: TimeInterval?, elapsed: TimeInterval?, infiniteLoop: Bool) -> String {
        guard !infiniteLoop, let duration else { return "∞" }
        let remainingSeconds = max(0, Int((duration - (elapsed ?? 0)).rounded(.up)))
        return String(format: "%d:%02d", remainingSeconds / 60, remainingSeconds % 60)
    }

    /// Audio/video cues set to loop forever have no knowable end even though
    /// `CueInstance.duration` reports a single pass's length — camera/text/
    /// still cues already report `duration == nil` and are caught by
    /// `remaining`'s own nil check, so only audio/video need checking here.
    static func isInfiniteLoop(_ cue: Cue) -> Bool {
        switch cue.body {
        case .audio(let body): return body.infiniteLoop
        case .video(let body): return body.infiniteLoop
        default: return false
        }
    }
}
