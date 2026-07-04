import AppKit

/// Operator-facing names for recorded shortcuts ("⌘⇧K", "Space", "F5").
extension KeyBinding {
    public var displayName: String {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        var parts = ""
        if flags.contains(.control) { parts += "⌃" }
        if flags.contains(.option) { parts += "⌥" }
        if flags.contains(.shift) { parts += "⇧" }
        if flags.contains(.command) { parts += "⌘" }
        return parts + KeyBinding.keyName(for: keyCode)
    }

    /// US-physical-layout names; keyCode identity means the physical
    /// key stays stable even if the layout changes.
    public static func keyName(for keyCode: UInt16) -> String {
        if let special = specialKeys[keyCode] { return special }
        return "Key \(keyCode)"
    }

    private static let specialKeys: [UInt16: String] = [
        49: "Space", 53: "Esc", 36: "Return", 76: "Enter", 48: "Tab", 51: "⌫", 117: "⌦",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        // Letters/digits/punctuation (ANSI positions)
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I",
        38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P", 12: "Q",
        15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
        27: "-", 24: "=", 33: "[", 30: "]", 41: ";", 39: "'", 43: ",", 47: ".", 44: "/", 42: "\\", 50: "`",
        82: "Num 0", 83: "Num 1", 84: "Num 2", 85: "Num 3", 86: "Num 4",
        87: "Num 5", 88: "Num 6", 89: "Num 7", 91: "Num 8", 92: "Num 9",
        65: "Num .", 67: "Num *", 69: "Num +", 75: "Num /", 78: "Num -", 81: "Num =",
    ]
}
