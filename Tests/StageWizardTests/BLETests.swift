import XCTest
@testable import StageWizard

/// D28: the StageWand BLE fallback tunnel's pure surfaces — wire framing
/// (`BLEWandFraming.frame`), stateful reassembly (`FrameReassembler`), and
/// the feedback fan-out seam (`OSCFeedbackFanout`) that lets both the UDP
/// and BLE sinks receive identical outbound messages.
///
/// Deliberately does NOT touch CoreBluetooth (no CBCentralManager, no real
/// or simulated peripheral) — same discipline as OSCTests.swift/
/// OSCFeedbackTests.swift not binding a real UDP socket. `BLEWandLink`
/// itself is untested here for exactly that reason; everything it depends
/// on for correctness (framing, reassembly, fan-out) is pure and covered.
@MainActor
final class BLETests: XCTestCase {

    // MARK: - Framing: u16 BE length prefix + payload

    /// Hand-built vector pinning big-endian byte order: 260 (0x0104) must
    /// encode as bytes [0x01, 0x04], NOT little-endian [0x04, 0x01].
    func testFrameByteOrderIsBigEndian() {
        let payload = Data(repeating: 0xAB, count: 260)
        let framed = BLEWandFraming.frame(payload)
        XCTAssertEqual(Array(framed.prefix(2)), [0x01, 0x04])
        XCTAssertEqual(framed.count, 2 + 260)
    }

    /// A second, smaller hand-built vector at the other end of the byte
    /// range — length 3 must encode as [0x00, 0x03].
    func testFrameByteOrderSmallLength() {
        let framed = BLEWandFraming.frame(Data([0x11, 0x22, 0x33]))
        XCTAssertEqual(Array(framed), [0x00, 0x03, 0x11, 0x22, 0x33])
    }

    func testFrameZeroLengthPayload() {
        let framed = BLEWandFraming.frame(Data())
        XCTAssertEqual(Array(framed), [0x00, 0x00])
    }

    // MARK: - Reassembly: round trip, split, coalesce

    func testReassemblerRoundTripsSingleFrame() {
        var reassembler = FrameReassembler()
        let payload = Data("hello wand".utf8)
        let payloads = reassembler.ingest(BLEWandFraming.frame(payload))
        XCTAssertEqual(payloads, [payload])
    }

    func testReassemblerHandlesZeroLengthPayload() {
        var reassembler = FrameReassembler()
        let payloads = reassembler.ingest(BLEWandFraming.frame(Data()))
        XCTAssertEqual(payloads, [Data()])
    }

    /// Two whole frames arriving COALESCED inside a single chunk (as can
    /// happen when several small OSC messages get batched into one BLE
    /// write/notify) must yield both payloads, in order, from one `ingest`
    /// call.
    func testReassemblerSplitsTwoFramesCoalescedInOneChunk() {
        var reassembler = FrameReassembler()
        let first = Data("/stagewizard/go".utf8)
        let second = Data("/stagewizard/status/panic".utf8)
        var chunk = BLEWandFraming.frame(first)
        chunk.append(BLEWandFraming.frame(second))
        XCTAssertEqual(reassembler.ingest(chunk), [first, second])
    }

    /// One frame SPLIT ACROSS three separate chunks (BLE's write MTU is far
    /// smaller than most payloads) must yield nothing until the final
    /// chunk completes the frame, then exactly the one payload.
    func testReassemblerReassemblesFrameSplitAcrossThreeChunks() {
        var reassembler = FrameReassembler()
        let payload = Data("a payload long enough to span several chunks".utf8)
        let framed = BLEWandFraming.frame(payload)
        XCTAssertGreaterThan(framed.count, 6, "test needs a frame with room for 3 uneven pieces")

        let splitA = framed.index(framed.startIndex, offsetBy: 1)   // mid length-prefix
        let splitB = framed.index(framed.startIndex, offsetBy: framed.count / 2)
        let chunk1 = framed.subdata(in: framed.startIndex..<splitA)
        let chunk2 = framed.subdata(in: splitA..<splitB)
        let chunk3 = framed.subdata(in: splitB..<framed.endIndex)

        XCTAssertEqual(reassembler.ingest(chunk1), [])
        XCTAssertEqual(reassembler.ingest(chunk2), [])
        XCTAssertEqual(reassembler.ingest(chunk3), [payload])
    }

    /// A mix: one already-complete frame plus the START of a second, in one
    /// chunk, followed by the REST of the second frame in a later chunk —
    /// exercises coalesce and split in the same buffer.
    func testReassemblerHandlesCoalescePlusSplitTogether() {
        var reassembler = FrameReassembler()
        let first = Data("/stagewizard/next".utf8)
        let second = Data("/stagewizard/status/running".utf8)
        let framedSecond = BLEWandFraming.frame(second)
        let splitPoint = framedSecond.index(framedSecond.startIndex, offsetBy: 3)

        var chunk1 = BLEWandFraming.frame(first)
        chunk1.append(framedSecond.subdata(in: framedSecond.startIndex..<splitPoint))
        let chunk2 = framedSecond.subdata(in: splitPoint..<framedSecond.endIndex)

        XCTAssertEqual(reassembler.ingest(chunk1), [first])
        XCTAssertEqual(reassembler.ingest(chunk2), [second])
    }

    // MARK: - Desync / resync

    /// A declared length over `maxPayloadSize` means desync: the buffer
    /// resets (nothing is returned for that ingest), and this implementation
    /// discards the whole chunk — bytes appended after the bad header in
    /// the SAME `ingest` call are lost too, since there is no resync token
    /// to hunt for the next real frame boundary inside them.
    func testOversizeLengthResetsBuffer() {
        var reassembler = FrameReassembler()
        var oversized = Data([0x02, 0x01]) // 0x0201 = 513, one over the 512 cap
        oversized.append(Data(repeating: 0, count: 20)) // "trailing garbage" also gets dropped
        XCTAssertEqual(reassembler.ingest(oversized), [])
    }

    /// After an oversize-triggered reset, a SUBSEQUENT well-formed frame
    /// (its own separate `ingest` call, starting clean) parses normally —
    /// resync just means "start fresh from the next call", not "wedged
    /// forever".
    func testValidFrameParsesAfterOversizeResync() {
        var reassembler = FrameReassembler()
        let bad = Data([0xFF, 0xFF]) // 65535 — way over the cap
        XCTAssertEqual(reassembler.ingest(bad), [])

        let payload = Data("/stagewizard/panic".utf8)
        XCTAssertEqual(reassembler.ingest(BLEWandFraming.frame(payload)), [payload])
    }

    /// Exactly at the cap (512) must still parse — the guard is `<=`, not `<`.
    func testLengthExactlyAtCapParses() {
        var reassembler = FrameReassembler()
        let payload = Data(repeating: 0x7A, count: BLEWandFraming.maxPayloadSize)
        XCTAssertEqual(reassembler.ingest(BLEWandFraming.frame(payload)), [payload])
    }

    /// One byte over the cap resets even when it's the very next frame
    /// after a run of perfectly good ones — the reset only discards what
    /// was buffered for the bad frame, not a magically-remembered history
    /// of prior successes (there's nothing left to remember; each `ingest`
    /// call only sees the live buffer).
    func testOneByteOverCapResets() {
        var reassembler = FrameReassembler()
        let good = Data("ok".utf8)
        XCTAssertEqual(reassembler.ingest(BLEWandFraming.frame(good)), [good])

        var oversized = Data([0x02, 0x01]) // 513
        oversized.append(Data(repeating: 0, count: 4))
        XCTAssertEqual(reassembler.ingest(oversized), [])

        let recovered = Data("recovered".utf8)
        XCTAssertEqual(reassembler.ingest(BLEWandFraming.frame(recovered)), [recovered])
    }

    // MARK: - Feedback fan-out: every sink gets the same messages

    func testFanoutDeliversIdenticalMessagesToEverySink() {
        let messages = [
            OSCMessage(address: "/stagewizard/status/running", arguments: [.int32(2)]),
            OSCMessage(address: "/stagewizard/status/panic", arguments: [.int32(0)]),
        ]
        var sinkA: [OSCMessage] = []
        var sinkB: [OSCMessage] = []

        OSCFeedbackFanout.broadcast(messages, to: [
            { sinkA.append(contentsOf: $0) },
            { sinkB.append(contentsOf: $0) },
        ])

        XCTAssertEqual(sinkA, messages)
        XCTAssertEqual(sinkB, messages)
    }

    func testFanoutWithNoSinksIsANoOp() {
        // Shouldn't crash or do anything observable with zero sinks.
        OSCFeedbackFanout.broadcast([OSCMessage(address: "/stagewizard/go", arguments: [])], to: [])
    }

    func testFanoutSkipsEmptyMessageBatch() {
        var callCount = 0
        OSCFeedbackFanout.broadcast([], to: [{ _ in callCount += 1 }])
        XCTAssertEqual(callCount, 0, "an empty message batch should never reach a sink")
    }

    func testFanoutPreservesMessageOrderPerSink() {
        let messages = (0..<5).map { OSCMessage(address: "/stagewizard/cuelist/item", arguments: [.int32(Int32($0))]) }
        var received: [OSCMessage] = []
        OSCFeedbackFanout.broadcast(messages, to: [{ received = $0 }])
        XCTAssertEqual(received, messages)
    }
}
