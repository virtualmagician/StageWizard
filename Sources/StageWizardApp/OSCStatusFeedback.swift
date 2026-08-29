import Foundation

/// D21: pure OSC status feedback logic — turns show/transport state into the
/// exact outbound wire messages a StageWand hardware controller expects
/// (see CLAUDE.md's D21 wire contract). No I/O, no actor isolation: every
/// entry point here is a `static func` over value types, so it's directly
/// unit-testable with no server, socket, or AppModel involved. AppModel owns
/// the ACTUAL polling (a 10 Hz MainActor tick — see `AppModel.oscFeedbackTick`)
/// and calls into this type to decide what changed.
enum OSCStatusFeedback {
    /// Every P1+P2 status field EXCEPT elapsed/duration, which ride a
    /// separate faster tick and are deliberately excluded here (see
    /// `elapsedMessage` below) — they change on every tick by definition, so
    /// folding them into a diffed snapshot would defeat the point of diffing.
    struct Snapshot: Equatable {
        var standingByNumber: String
        var standingByName: String
        var notes: String
        var runningCount: Int
        var panic: Bool
        var showMode: Bool
        var windowIndex: Int
        var windowTotal: Int
        var prevNum: String
        var prevName: String
        var nextNum: String
        var nextName: String
    }

    /// Neighbors of the standing-by cue within the GO sequence — pure helper
    /// factored out so it's testable independent of TransportController.
    /// `standingByID` nil (empty show, or the playhead has run past the end)
    /// yields index -1 and empty prev/next, matching the wire contract's
    /// "-1 when nothing stands by" / "empty strings at the ends" rules.
    /// `total` is always `goSequence.count`, regardless of whether anything
    /// currently stands by.
    struct WindowInfo: Equatable {
        var index: Int
        var total: Int
        var prevNum: String
        var prevName: String
        var nextNum: String
        var nextName: String
    }

    static func windowInfo(goSequence: [Cue], standingByID: UUID?) -> WindowInfo {
        let total = goSequence.count
        guard let standingByID, let index = goSequence.firstIndex(where: { $0.id == standingByID }) else {
            return WindowInfo(index: -1, total: total, prevNum: "", prevName: "", nextNum: "", nextName: "")
        }
        let prev = index > 0 ? goSequence[index - 1] : nil
        let next = index + 1 < goSequence.count ? goSequence[index + 1] : nil
        return WindowInfo(
            index: index, total: total,
            prevNum: prev?.number ?? "", prevName: prev?.displayName ?? "",
            nextNum: next?.number ?? "", nextName: next?.displayName ?? ""
        )
    }

    /// Which addresses changed between `old` and `new`. `old == nil` means
    /// "everything" — a new subscriber's full refresh (see
    /// `OSCServer.fullRefreshProvider`) — otherwise exactly one message per
    /// address whose backing field(s) differ. The four window fields
    /// (`windowIndex`/`windowTotal`/prev/next) share ONE address
    /// (`/stagewizard/status/window`) per the wire contract, so they're
    /// diffed as a group: any one of them changing re-sends all four
    /// together in a single message, never split across several.
    static func changedMessages(old: Snapshot?, new: Snapshot) -> [OSCMessage] {
        var messages: [OSCMessage] = []

        if old == nil || old!.standingByNumber != new.standingByNumber || old!.standingByName != new.standingByName {
            messages.append(OSCMessage(address: "/stagewizard/status/standingby", arguments: [
                .string(new.standingByNumber), .string(new.standingByName),
            ]))
        }
        if old == nil || old!.runningCount != new.runningCount {
            messages.append(OSCMessage(address: "/stagewizard/status/running", arguments: [
                .int32(Int32(new.runningCount)),
            ]))
        }
        if old == nil || old!.panic != new.panic {
            messages.append(OSCMessage(address: "/stagewizard/status/panic", arguments: [
                .int32(new.panic ? 1 : 0),
            ]))
        }
        if old == nil || old!.showMode != new.showMode {
            messages.append(OSCMessage(address: "/stagewizard/status/showmode", arguments: [
                .int32(new.showMode ? 1 : 0),
            ]))
        }
        if old == nil
            || old!.windowIndex != new.windowIndex || old!.windowTotal != new.windowTotal
            || old!.prevNum != new.prevNum || old!.prevName != new.prevName
            || old!.nextNum != new.nextNum || old!.nextName != new.nextName {
            messages.append(OSCMessage(address: "/stagewizard/status/window", arguments: [
                .int32(Int32(new.windowIndex)), .int32(Int32(new.windowTotal)),
                .string(new.prevNum), .string(new.prevName),
                .string(new.nextNum), .string(new.nextName),
            ]))
        }
        if old == nil || old!.notes != new.notes {
            messages.append(OSCMessage(address: "/stagewizard/status/notes", arguments: [
                .string(new.notes),
            ]))
        }
        return messages
    }

    /// The `/stagewizard/status/elapsed` message — computed OUTSIDE the
    /// snapshot/diff above (see the type's header). `duration` nil
    /// (indefinite — camera/text/slide/still cues, or an audio/video cue
    /// whose player hasn't reported one) or `<= 0` both mean "indefinite" on
    /// the wire; nil encodes as -1.
    static func elapsedMessage(elapsed: TimeInterval, duration: TimeInterval?) -> OSCMessage {
        OSCMessage(address: "/stagewizard/status/elapsed", arguments: [
            .float32(Float(elapsed)), .float32(Float(duration ?? -1)),
        ])
    }
}
