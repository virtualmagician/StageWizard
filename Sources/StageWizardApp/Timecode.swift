import Foundation

/// Display/parse helper for operator-facing times: "1:23.50" or "12.75".
enum Timecode {
    static func format(_ seconds: TimeInterval, showFraction: Bool = true) -> String {
        let clamped = max(0, seconds)
        let minutes = Int(clamped) / 60
        let secs = clamped - Double(minutes * 60)
        if minutes > 0 {
            return showFraction
                ? String(format: "%d:%06.3f", minutes, secs)   // millisecond precision
                : String(format: "%d:%02.0f", minutes, secs)
        }
        return showFraction
            ? String(format: "%.3f", secs)
            : String(format: "%.0f", secs)
    }

    /// Accepts "83.5", "1:23.5", "01:02:03.25". Returns nil for garbage.
    static func parse(_ text: String) -> TimeInterval? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":").map(String.init)
        guard parts.count <= 3 else { return nil }
        var total: TimeInterval = 0
        for part in parts {
            guard let value = Double(part), value >= 0 else { return nil }
            total = total * 60 + value
        }
        return total
    }
}
