import AppKit
import QuartzCore

/// Borderless fullscreen output window. Overrides key/main so the operator's
/// focus NEVER leaves the control window — a video starting mid-show must not
/// steal keyboard focus from the GO button.
final class OutputWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Rehearsal preview: floating, titled, resizable stand-in for an output
/// group. Its content view re-frames every hosted layer on resize (the real
/// output windows never resize; these do).
final class PreviewWindow: NSPanel {
    override var canBecomeMain: Bool { false }
}

final class PreviewContentView: NSView {
    override func layout() {
        super.layout()
        guard let sublayers = layer?.sublayers else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sublayer in sublayers {
            // bounds + position, NOT frame: setting frame is undefined when a
            // custom-geometry transform is active on the layer.
            sublayer.bounds = CGRect(origin: .zero, size: bounds.size)
            sublayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        CATransaction.commit()
        // Stage size changed: transforms hold stage-unit translations, so the
        // app re-pushes geometry to every live player.
        OutputWindowManager.shared.onPreviewResized?()
    }
}

/// Owns one output NSWindow per in-use target: borderless fullscreen windows
/// for real displays, floating resizable panels for rehearsal previews.
/// Video/camera players lease the window's content layer via `hostLayer(for:)`
/// and release it on teardown; display windows close when the last lease is
/// released, preview windows stay pinned open until `closeAllPreviews()`.
///
/// Never uses AppKit's fullscreen API (`toggleFullScreen` creates a Space and
/// animates) and never AVPlayerView — raw windows + AVPlayerLayers only.
@MainActor
public final class OutputWindowManager {
    public static let shared = OutputWindowManager()

    /// `@MainActor` explicitly: nesting inside a global-actor-isolated class
    /// does NOT itself isolate a nested type's own members — without this,
    /// `layer`/`window` below (touching `NSWindow.contentView`/`NSView.layer`,
    /// both MainActor-isolated) fail to typecheck from a nonisolated context.
    @MainActor
    private struct Entry {
        /// Either a real window this manager owns, or a layer some OUTSIDE
        /// owner (the stage display's program pane, D13) registered — see
        /// `registerExternalHost`. External entries are never opened/closed
        /// here; only the external owner's `unregisterExternalHost` retires them.
        enum Host {
            case window(NSWindow)
            case external(CALayer)
        }
        var host: Host
        var leaseCount: Int
        /// Preview windows persist while rehearsal mode is on, even at 0 leases.
        var pinned: Bool
        /// True when created with a test frame override — display-change
        /// handling then leaves the frame alone.
        let usesFrameOverride: Bool

        var layer: CALayer? {
            switch host {
            case .window(let window): window.contentView?.layer
            case .external(let layer): layer
            }
        }

        var window: NSWindow? {
            if case .window(let window) = host { return window }
            return nil
        }

        var isExternal: Bool {
            if case .external = host { return true }
            return false
        }
    }

    private var entries: [OutputTarget: Entry] = [:]

    /// Preview targets an outside owner is hosting directly (D13: the stage
    /// display's program pane) — see `registerExternalHost`. Consulted by
    /// `hostLayer(for:)` BEFORE it would otherwise create a floating window.
    private var externalHosts: [OutputTarget: CALayer] = [:]

    /// Fired after a rehearsal preview re-lays-out (resize) — the app uses it
    /// to re-apply stage-relative geometry to running players.
    public var onPreviewResized: (@MainActor () -> Void)?

    private init() {}

    // MARK: - Leasing

    /// Layer to which a video/camera cue attaches its output layer. Creates
    /// and shows the target's window lazily; each call takes one lease.
    /// A `.preview` target with a registered external host (see
    /// `registerExternalHost`) returns that layer instead of opening a
    /// floating window — one decode, an extra layer, no new window.
    ///
    /// - Parameter frameOverride: global-coordinates window frame for unit
    ///   tests (e.g. 320x180) instead of covering the whole screen. Ignored
    ///   when the target's window already exists.
    public func hostLayer(for target: OutputTarget, frameOverride: CGRect? = nil) throws -> CALayer {
        if var entry = entries[target] {
            guard let layer = entry.layer else {
                throw VideoEngineError.windowUnavailable
            }
            entry.leaseCount += 1
            entries[target] = entry
            return layer
        }

        if let externalLayer = externalHosts[target] {
            entries[target] = Entry(host: .external(externalLayer), leaseCount: 1, pinned: false, usesFrameOverride: false)
            return externalLayer
        }

        let window: NSWindow
        switch target {
        case .display(let displayID):
            window = try Self.makeDisplayWindow(displayID: displayID, frameOverride: frameOverride)
        case .preview(let id, let title):
            window = Self.makePreviewWindow(id: id, title: title, frameOverride: frameOverride)
        }

        guard let layer = window.contentView?.layer else {
            window.close()
            throw VideoEngineError.windowUnavailable
        }
        entries[target] = Entry(
            host: .window(window),
            leaseCount: 1,
            pinned: false,
            usesFrameOverride: frameOverride != nil
        )
        return layer
    }

    /// Convenience for real displays (tests, single-display call sites).
    public func hostLayer(for displayID: CGDirectDisplayID, frameOverride: CGRect? = nil) throws -> CALayer {
        try hostLayer(for: .display(displayID), frameOverride: frameOverride)
    }

    /// Release one lease taken by `hostLayer(for:)`. Display windows close
    /// when the last video layer is gone; pinned previews stay open; an
    /// externally-hosted layer (D13 program pane) is never closed here —
    /// its owner controls its lifetime via `unregisterExternalHost`.
    public func releaseLayer(for target: OutputTarget) {
        guard var entry = entries[target] else { return }
        entry.leaseCount -= 1
        if entry.leaseCount <= 0 && !entry.pinned {
            if case .window(let window) = entry.host {
                window.orderOut(nil)
                window.close()
            }
            entries[target] = nil
        } else {
            entries[target] = entry
        }
    }

    public func releaseLayer(for displayID: CGDirectDisplayID) {
        releaseLayer(for: .display(displayID))
    }

    // MARK: - External hosts (D13: stage display program pane)

    /// Register `layer` as the host for `target` (must be a `.preview`
    /// target) — henceforth `hostLayer(for:)` hands it out directly instead
    /// of opening a floating window; leasing/counting works exactly as it
    /// does for a window-backed target. The caller (StageDisplayController)
    /// owns `layer`'s membership in its own layer tree and its geometry;
    /// this manager only tracks it for leasing.
    public func registerExternalHost(_ layer: CALayer, for target: OutputTarget) {
        externalHosts[target] = layer
    }

    /// Retire an external host: no MORE cues will be routed here (a future
    /// `hostLayer(for:)` for this target falls through to opening an
    /// ordinary floating window, same as any other never-registered
    /// preview). Any player CURRENTLY hosted here keeps playing into
    /// `layer` — it's still part of the caller's view/layer tree until the
    /// caller itself removes it — and its eventual `releaseLayer` call
    /// no-ops harmlessly (same pattern as `closeAllPreviews`' orphaned
    /// leases below): we drop OUR bookkeeping now rather than wait for
    /// leases to drain, because the caller is about to tear down (or has
    /// torn down) the layer itself.
    public func unregisterExternalHost(for target: OutputTarget) {
        externalHosts[target] = nil
        if let entry = entries[target], entry.isExternal {
            entries[target] = nil
        }
    }

    // MARK: - Rehearsal previews

    /// Open (or keep) a pinned preview window for an output group — one per
    /// assigned video output while rehearsal mode is active.
    public func openPreview(id: UUID, title: String) {
        let target = OutputTarget.preview(id: id, title: title)
        if var entry = entries[target], case .window(let window) = entry.host {
            entry.pinned = true
            entries[target] = entry
            window.orderFront(nil)
            return
        }
        let window = Self.makePreviewWindow(id: id, title: title, frameOverride: nil)
        entries[target] = Entry(host: .window(window), leaseCount: 0, pinned: true, usesFrameOverride: false)
    }

    /// Close every preview window (leaving rehearsal mode). Players still
    /// holding leases have been stopped by the mode switch; their later
    /// releaseLayer calls no-op harmlessly. Previews in `keeping` survive —
    /// the virtual-webcam monitor must outlive mode switches while feeding.
    /// Externally-hosted targets (D13 program pane) are never touched here —
    /// rehearsal preview lifecycle has nothing to do with the stage display.
    public func closeAllPreviews(keeping: Set<UUID> = []) {
        for (target, entry) in entries {
            guard case .preview(let id, _) = target, !keeping.contains(id),
                  case .window(let window) = entry.host else { continue }
            window.orderOut(nil)
            window.close()
            entries[target] = nil
        }
    }

    /// Close one preview: unpin, and close now unless cues still render
    /// into it (then it closes when the last lease is released). A no-op
    /// for an externally-hosted target — see `unregisterExternalHost`.
    public func closePreview(id: UUID) {
        for (target, var entry) in entries {
            guard case .preview(let previewID, _) = target, previewID == id,
                  case .window(let window) = entry.host else { continue }
            entry.pinned = false
            if entry.leaseCount <= 0 {
                window.orderOut(nil)
                window.close()
                entries[target] = nil
            } else {
                entries[target] = entry
            }
        }
    }

    // MARK: - Window construction

    private static func makeDisplayWindow(displayID: CGDirectDisplayID, frameOverride: CGRect?) throws -> NSWindow {
        guard let screen = screen(for: displayID) else {
            throw VideoEngineError.displayNotConnected(displayID)
        }
        let frame = frameOverride ?? screen.frame
        // Exact spec from the plan — do not deviate.
        let window = OutputWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isOpaque = true
        window.backgroundColor = .black
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.contentView?.wantsLayer = true
        // init(contentRect:screen:) interprets the rect relative to `screen`;
        // normalize to global coordinates so secondary-display frames are exact.
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
        return window
    }

    private static func makePreviewWindow(id: UUID, title: String, frameOverride: CGRect?) -> NSWindow {
        let frame = frameOverride ?? CGRect(x: 120, y: 120, width: 480, height: 270)
        let window = PreviewWindow(
            contentRect: frame,
            styleMask: [.titled, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "Rehearsal: \(title)"
        window.level = .floating
        window.isFloatingPanel = true
        window.becomesKeyOnlyIfNeeded = true
        // Panels hide on app deactivate by default — rehearsal monitors (and
        // the virtual-webcam monitor, which is CAPTURED) must stay visible
        // while the operator works in other apps.
        window.hidesOnDeactivate = false
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.minSize = CGSize(width: 200, height: 120)

        let content = PreviewContentView()
        content.wantsLayer = true
        content.layer?.backgroundColor = .black
        window.contentView = content

        // Remember the operator's arrangement per group across sessions.
        window.setFrameAutosaveName("rehearsal-preview-\(id.uuidString)")
        window.orderFront(nil)
        return window
    }

    // MARK: - Hot-plug

    /// Called by DisplayManager after every debounced re-enumeration.
    /// Preview windows are untouched — they're immune to display hot-plug.
    ///
    /// A vanished display's window is IMMEDIATELY ordered out and closed —
    /// left alone, the window server silently moves it to another screen
    /// (typically the operator's). Surviving displays get their window frame
    /// re-asserted in case the display moved or changed mode; a re-attached
    /// display gets a fresh window (with a fresh frame) on the next
    /// `hostLayer(for:)` call.
    public func handleDisplaysChanged(connected: [ConnectedDisplay]) {
        // `.display` targets are always window-backed in practice (only
        // `.preview` targets are ever externally hosted), so `entry.window`
        // is never nil here — optional-chained defensively regardless.
        let connectedIDs = Set(connected.map(\.displayID))
        for (target, entry) in entries {
            guard let displayID = target.displayID else { continue }
            if !connectedIDs.contains(displayID) {
                entry.window?.orderOut(nil)
                entry.window?.close()
                entries[target] = nil
            }
        }
        for display in connected {
            if let entry = entries[.display(display.displayID)], !entry.usesFrameOverride {
                entry.window?.setFrame(display.screen.frame, display: true)
            }
        }
    }

    // MARK: - Introspection (tests + runtime)

    func window(for target: OutputTarget) -> NSWindow? {
        entries[target]?.window
    }

    func window(for displayID: CGDirectDisplayID) -> NSWindow? {
        entries[.display(displayID)]?.window
    }

    func leaseCount(for target: OutputTarget) -> Int {
        entries[target]?.leaseCount ?? 0
    }

    func leaseCount(for displayID: CGDirectDisplayID) -> Int {
        entries[.display(displayID)]?.leaseCount ?? 0
    }

    static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return CGDirectDisplayID(number.uint32Value) == displayID
        }
    }
}
