import AppKit
import CoreGraphics
import Observation

/// A physical display currently attached to the system.
///
/// `CGDirectDisplayID` is unstable across reconnects/reboots, so cues persist
/// a `DisplayFingerprint` and re-resolve it against `ConnectedDisplay`s at
/// arm time. Holds an `NSScreen`, so this type is MainActor-confined.
public struct ConnectedDisplay {
    public let screen: NSScreen
    public let displayID: CGDirectDisplayID
    public let fingerprint: DisplayFingerprint
}

/// Enumerates attached displays and re-resolves persisted fingerprints.
///
/// Hot-plug is observed via `NSApplication.didChangeScreenParametersNotification`
/// ONLY — `CGDisplayRegisterReconfigurationCallback` has a Tahoe regression and
/// must not be used. Reconfiguration storms (a projector negotiating EDID posts
/// several notifications) are debounced before re-enumerating.
@MainActor
@Observable
public final class DisplayManager {
    public static let shared = DisplayManager()

    /// Debounce window for screen-parameter change storms.
    static let hotPlugDebounce: TimeInterval = 0.75

    /// Attached displays in `NSScreen.screens` order (first = main display).
    public private(set) var displays: [ConnectedDisplay] = []

    /// Invoked on the MainActor after every debounced re-enumeration.
    /// The runtime uses this to re-evaluate broken-display cue states.
    @ObservationIgnored public var onDisplaysChanged: (([ConnectedDisplay]) -> Void)?

    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var observerToken: (any NSObjectProtocol)?

    private init() {
        displays = Self.enumerate()
        // AppKit posts this notification on the main thread; queue: .main makes
        // that explicit, so assumeIsolated is a checked no-op hop (it traps if
        // the invariant is ever violated rather than racing silently).
        observerToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                DisplayManager.shared.scheduleRefresh()
            }
        }
    }

    // MARK: - Enumeration

    /// Force an immediate re-enumeration (also the debounce target).
    public func refreshNow() {
        debounceTask?.cancel()
        debounceTask = nil
        displays = Self.enumerate()
        // Close orphaned output windows FIRST — the window server would
        // otherwise silently migrate them onto the operator's screen.
        OutputWindowManager.shared.handleDisplaysChanged(connected: displays)
        onDisplaysChanged?(displays)
    }

    private func scheduleRefresh() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.hotPlugDebounce))
            guard !Task.isCancelled else { return }
            self?.refreshNow()
        }
    }

    static func enumerate() -> [ConnectedDisplay] {
        NSScreen.screens.compactMap(connectedDisplay(for:))
    }

    static func connectedDisplay(for screen: NSScreen) -> ConnectedDisplay? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        let displayID = CGDirectDisplayID(number.uint32Value)
        return ConnectedDisplay(
            screen: screen,
            displayID: displayID,
            fingerprint: fingerprint(for: screen, displayID: displayID)
        )
    }

    /// Hardware attributes + name + pixel size; matches DisplayFingerprint's
    /// scoring fields (serial is often 0 on projectors — the score handles it).
    public static func fingerprint(for screen: NSScreen, displayID: CGDirectDisplayID) -> DisplayFingerprint {
        DisplayFingerprint(
            vendorNumber: CGDisplayVendorNumber(displayID),
            modelNumber: CGDisplayModelNumber(displayID),
            serialNumber: CGDisplaySerialNumber(displayID),
            name: screen.localizedName,
            pixelWidth: CGDisplayPixelsWide(displayID),
            pixelHeight: CGDisplayPixelsHigh(displayID)
        )
    }

    // MARK: - Matching

    /// Best-scoring connected display for a persisted fingerprint, or nil when
    /// nothing plausibly matches (score 0) — the cue is then display-broken.
    public func match(_ fingerprint: DisplayFingerprint) -> ConnectedDisplay? {
        displays
            .map { (display: $0, score: fingerprint.matchScore(against: $0.fingerprint)) }
            .filter { $0.score > 0 }
            .max { $0.score < $1.score }?
            .display
    }
}
