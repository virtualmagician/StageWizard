import SwiftUI

/// One place to tune the dark show-control look. The app runs with a locked
/// darkAqua appearance (set in AppDelegate), so these are dark-only values.
enum Theme {
    // Surfaces
    static let listBackground = Color(red: 0.13, green: 0.13, blue: 0.14)
    static let headerBackground = Color(red: 0.17, green: 0.17, blue: 0.18)
    static let panelBackground = Color(red: 0.15, green: 0.15, blue: 0.16)
    static let insetBackground = Color(red: 0.10, green: 0.10, blue: 0.11)

    // Rows
    static let groupRowBackground = Color.white.opacity(0.06)
    static let selectionOverlay = Color.accentColor.opacity(0.28)

    // Signals
    static let standby = Color(red: 0.35, green: 0.85, blue: 0.35)   // standby green
    static let go = Color(red: 0.30, green: 0.75, blue: 0.30)
    static let panic = Color(red: 0.90, green: 0.30, blue: 0.20)
    static let hold = Color(red: 0.35, green: 0.60, blue: 0.95)

    static let standbyBorder = standby.opacity(0.8)
}
