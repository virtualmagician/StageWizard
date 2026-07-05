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

    private struct Entry {
        let window: NSWindow
        var leaseCount: Int
        /// Preview windows persist while rehearsal mode is on, even at 0 leases.
        var pinned: Bool
        /// True when created with a test frame override — display-change
        /// handling then leaves the frame alone.
        let usesFrameOverride: Bool
    }

    private var entries: [OutputTarget: Entry] = [:]

    /// Fired after a rehearsal preview re-lays-out (resize) — the app uses it
    /// to re-apply stage-relative geometry to running players.
    public var onPreviewResized: (@MainActor () -> Void)?

    private init() {}

    // MARK: - Leasing

    /// Layer to which a video/camera cue attaches its output layer. Creates
    /// and shows the target's window lazily; each call takes one lease.
    ///
    /// - Parameter frameOverride: global-coordinates window frame for unit
    ///   tests (e.g. 320x180) instead of covering the whole screen. Ignored
    ///   when the target's window already exists.
    public func hostLayer(for target: OutputTarget, frameOverride: CGRect? = nil) throws -> CALayer {
        if var entry = entries[target] {
            guard let layer = entry.window.contentView?.layer else {
                throw VideoEngineError.windowUnavailable
            }
            entry.leaseCount += 1
            entries[target] = entry
            return layer
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
            window: window,
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
    /// when the last video layer is gone; pinned previews stay open.
    public func releaseLayer(for target: OutputTarget) {
        guard var entry = entries[target] else { return }
        entry.leaseCount -= 1
        if entry.leaseCount <= 0 && !entry.pinned {
            entry.window.orderOut(nil)
            entry.window.close()
            entries[target] = nil
        } else {
            entries[target] = entry
        }
    }

    public func releaseLayer(for displayID: CGDirectDisplayID) {
        releaseLayer(for: .display(displayID))
    }

    // MARK: - Rehearsal previews

    /// Open (or keep) a pinned preview window for an output group — one per
    /// assigned video output while rehearsal mode is active.
    public func openPreview(id: UUID, title: String) {
        let target = OutputTarget.preview(id: id, title: title)
        if var entry = entries[target] {
            entry.pinned = true
            entries[target] = entry
            entry.window.orderFront(nil)
            return
        }
        let window = Self.makePreviewWindow(id: id, title: title, frameOverride: nil)
        entries[target] = Entry(window: window, leaseCount: 0, pinned: true, usesFrameOverride: false)
    }

    /// Close every preview window (leaving rehearsal mode). Players still
    /// holding leases have been stopped by the mode switch; their later
    /// releaseLayer calls no-op harmlessly.
    public func closeAllPreviews() {
        for (target, entry) in entries {
            if case .preview = target {
                entry.window.orderOut(nil)
                entry.window.close()
                entries[target] = nil
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
        let connectedIDs = Set(connected.map(\.displayID))
        for (target, entry) in entries {
            guard let displayID = target.displayID else { continue }
            if !connectedIDs.contains(displayID) {
                entry.window.orderOut(nil)
                entry.window.close()
                entries[target] = nil
            }
        }
        for display in connected {
            if let entry = entries[.display(display.displayID)], !entry.usesFrameOverride {
                entry.window.setFrame(display.screen.frame, display: true)
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
