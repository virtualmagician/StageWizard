import Foundation

/// A recorded MIDI trigger — either a specific note or a controller number on
/// a specific channel. Captured via MIDI-Learn, matched against incoming
/// MIDI 1.0 channel-voice messages at dispatch time (see MIDIController).
public struct MIDIBinding: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case noteOn
        case controlChange
    }

    public var kind: Kind
    /// 0-15.
    public var channel: UInt8
    /// Note number or CC number, 0-127.
    public var number: UInt8

    public init(kind: Kind, channel: UInt8, number: UInt8) {
        self.kind = kind
        self.channel = channel
        self.number = number
    }
}

/// One MIDI-Learn assignment: a captured trigger mapped to a transport action.
/// An array (not a dictionary keyed by action) so the shape matches how the
/// Remote settings tab edits it — one row per bindable action, at most one
/// binding each in v1, replaced wholesale by re-learning.
public struct MIDIBindingEntry: Codable, Hashable, Sendable {
    public var binding: MIDIBinding
    public var action: ShortcutAction

    public init(binding: MIDIBinding, action: ShortcutAction) {
        self.binding = binding
        self.action = action
    }
}
