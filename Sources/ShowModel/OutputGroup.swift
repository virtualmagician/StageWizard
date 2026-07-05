import Foundation

/// A named virtual video output ("Internal", "External 1", "Prompter") that
/// cues target instead of raw displays ("stages"). Reassigning the
/// displays in one group re-routes every cue that uses it, and a group may
/// span SEVERAL displays (the same video mirrors onto all of them).
public struct OutputGroup: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var displays: [DisplayFingerprint]
    /// Also mirror this output into the virtual webcam ("StageWizard
    /// Camera") when it's active.
    public var virtualCamera: Bool

    public init(id: UUID = UUID(), name: String, displays: [DisplayFingerprint] = [], virtualCamera: Bool = false) {
        self.id = id
        self.name = name
        self.displays = displays
        self.virtualCamera = virtualCamera
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, displays, virtualCamera
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        displays = try c.decode([DisplayFingerprint].self, forKey: .displays)
        virtualCamera = try c.decodeIfPresent(Bool.self, forKey: .virtualCamera) ?? false
    }
}
