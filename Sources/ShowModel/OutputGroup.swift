import Foundation

/// A named virtual video output ("Internal", "External 1", "Prompter") that
/// cues target instead of raw displays ("stages"). Reassigning the
/// displays in one group re-routes every cue that uses it, and a group may
/// span SEVERAL displays (the same video mirrors onto all of them).
public struct OutputGroup: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var displays: [DisplayFingerprint]

    public init(id: UUID = UUID(), name: String, displays: [DisplayFingerprint] = []) {
        self.id = id
        self.name = name
        self.displays = displays
    }
}
