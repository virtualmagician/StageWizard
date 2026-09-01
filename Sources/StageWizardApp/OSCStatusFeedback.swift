import Foundation

/// D21 (+D22): pure OSC status feedback logic — turns show/transport state
/// into the exact outbound wire messages a StageWand hardware controller
/// expects (see CLAUDE.md's StageWand wire-contract bullet). No I/O, no
/// actor isolation: every entry point here is a `static func` over value
/// types, so it's directly unit-testable with no server, socket, or
/// AppModel involved. AppModel owns the ACTUAL polling (a 10 Hz MainActor
/// tick — see `AppModel.oscFeedbackTick`) and calls into this type to decide
/// what changed. D22 added the liveness heartbeat (`shouldSendHeartbeat`)
/// and the chunked full cue-list dump (`cuelistEntries`/`cuelistMessages`).
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
        /// D22: the GO sequence, capped to `maxCuelistEntries` — see
        /// `cuelistEntries`/`cuelistMessages` below.
        var cuelist: [CueListEntry]
    }

    /// D22: one row of the chunked cue-list dump — a cue's number + display
    /// name, nothing else (the wand only needs enough to label a button).
    struct CueListEntry: Equatable {
        var number: String
        var name: String
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
            messages.append(runningMessage(new.runningCount))
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
        // D22: the chunked cue-list burst rides the SAME diff as everything
        // else above (it's just another snapshot field), which is what
        // guarantees it lands AFTER the status messages in both the
        // on-subscribe full refresh (`old: nil`) and a live change — the
        // fixed append order above IS the ordering contract.
        if old == nil || old!.cuelist != new.cuelist {
            messages.append(contentsOf: cuelistMessages(new.cuelist))
        }
        return messages
    }

    /// The `/stagewizard/status/running` message — factored out so the D22
    /// liveness heartbeat (`AppModel.oscFeedbackTick`) sends the exact same
    /// wire shape as a genuine change, without duplicating the address string.
    static func runningMessage(_ count: Int) -> OSCMessage {
        OSCMessage(address: "/stagewizard/status/running", arguments: [.int32(Int32(count))])
    }

    /// D22: liveness heartbeat — every 20th feedback tick (10 Hz ÷ 20 = one
    /// every ~2s) is a heartbeat tick, REGARDLESS of whether anything
    /// changed; this is what lets a quiet-but-alive host stay distinguishable
    /// from a dead one (the wand's own liveness grace window is 10s). Pure
    /// tick-index arithmetic plus the suppress-on-change rule: skip the
    /// heartbeat when this exact tick already emitted a genuine
    /// `/status/running` change via `changedMessages`, so a subscriber never
    /// sees the address twice in one tick.
    static let heartbeatTickDivisor = 20

    static func shouldSendHeartbeat(tickCount: Int, runningAlreadySentThisTick: Bool) -> Bool {
        tickCount % heartbeatTickDivisor == 0 && !runningAlreadySentThisTick
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

    // MARK: - D22: chunked full cue-list dump

    /// Hard cap on how many cues ride the `/stagewizard/cuelist/*` burst —
    /// the wire contract's begin/end self-consistency (they share ONE count)
    /// needs a fixed upper bound, and it keeps the burst's datagram count
    /// bounded regardless of show size.
    static let maxCuelistEntries = 64

    /// GO sequence → capped (number, name) pairs, in order — the exact
    /// content `cuelistMessages` turns into the begin/item*/end burst. Pure
    /// so it's testable without a real TransportController (mirrors
    /// `windowInfo` above). Name matches `windowInfo`'s: `displayName`.
    static func cuelistEntries(goSequence: [Cue]) -> [CueListEntry] {
        goSequence.prefix(maxCuelistEntries).map { CueListEntry(number: $0.number, name: $0.displayName) }
    }

    /// The `/stagewizard/cuelist/begin|item|end` burst for `entries`: one
    /// `begin` (count), one `item` per entry (0-based index, number, name),
    /// one `end` (same count) — each its own message/datagram, in this
    /// order. Caps to `maxCuelistEntries` defensively even if `entries`
    /// arrives larger than that (e.g. called directly, bypassing
    /// `cuelistEntries`'s own cap), so `count` always matches the number of
    /// `item` messages actually produced — the wand's begin→end
    /// double-buffer stays self-consistent no matter the caller.
    static func cuelistMessages(_ entries: [CueListEntry]) -> [OSCMessage] {
        let capped = entries.count > maxCuelistEntries ? Array(entries.prefix(maxCuelistEntries)) : entries
        var messages: [OSCMessage] = [
            OSCMessage(address: "/stagewizard/cuelist/begin", arguments: [.int32(Int32(capped.count))]),
        ]
        for (index, entry) in capped.enumerated() {
            messages.append(OSCMessage(address: "/stagewizard/cuelist/item", arguments: [
                .int32(Int32(index)), .string(entry.number), .string(entry.name),
            ]))
        }
        messages.append(OSCMessage(address: "/stagewizard/cuelist/end", arguments: [.int32(Int32(capped.count))]))
        return messages
    }
}
