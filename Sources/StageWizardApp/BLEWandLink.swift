import CoreBluetooth
import Foundation
import Observation

// MARK: - D28: Sendable escape hatches for CoreBluetooth's un-annotated ObjC
// types
//
// CBCentralManager/CBPeripheral/CBCharacteristic/CBService aren't marked
// Sendable in this SDK, which is what forces every
// CBCentralManagerDelegate/CBPeripheralDelegate requirement below to jump
// through `nonisolated` + `MainActor.assumeIsolated` in the first place —
// the parameters have to cross from the (statically) unknown-isolation
// delegate callback into the MainActor closure, and Swift's region checker
// refuses to do that for a non-Sendable type without proof ("Sending 'x'
// risks causing data races"). `@unchecked Sendable` is the standard,
// Apple-acknowledged escape hatch for exactly this situation: these
// objects are ALWAYS touched from the same serial queue in this class's
// usage (CoreBluetooth's own "queue: nil → main queue" contract — see
// `BLEWandLink`'s header), so there is no actual concurrent access for
// Swift to protect against here, only a static annotation CoreBluetooth
// hasn't added yet.
extension CBCentralManager: @retroactive @unchecked Sendable {}
extension CBPeripheral: @retroactive @unchecked Sendable {}
extension CBCharacteristic: @retroactive @unchecked Sendable {}
extension CBService: @retroactive @unchecked Sendable {}

// MARK: - D28: pure framing/reassembly (no CoreBluetooth involved — directly
// unit-testable, see BLETests.swift)

/// Wire framing shared by both directions of the BLE fallback tunnel: a u16
/// BIG-ENDIAN length prefix followed by the OSC payload — the exact same
/// OSC 1.0 bytes `OSCServer.encode`/`.parse` already use for UDP. Framing
/// exists only because a BLE write/notify has no inherent datagram boundary
/// the way a UDP packet does (see `FrameReassembler` below).
enum BLEWandFraming {
    /// Hard cap on a single framed payload's length field — comfortably
    /// above every message this app actually sends (status/cuelist rows
    /// are tiny strings/numbers) and small enough to bound
    /// `FrameReassembler`'s buffer growth against a hostile or desynced
    /// peer. Fixed by the wand-team wire contract, not tunable.
    static let maxPayloadSize = 512

    /// `payload` framed for the wire: 2-byte big-endian length + bytes,
    /// ready to be chunked to the peripheral's write MTU and queued.
    static func frame(_ payload: Data) -> Data {
        let length = UInt16(clamping: payload.count)
        var framed = Data([UInt8(length >> 8), UInt8(length & 0x00FF)])
        framed.append(payload)
        return framed
    }
}

/// Stateful reassembly of framed BLE bytes back into whole OSC payloads.
/// Frames may SPLIT ACROSS several writes/notifies (BLE's write MTU is far
/// smaller than 512 B) or COALESCE WITHIN a single one (several small
/// messages batched into one write/notify) — `ingest` buffers arriving
/// bytes and peels off every complete frame it can find, in arrival order,
/// leaving any trailing partial frame buffered for the next call.
///
/// A declared length greater than `BLEWandFraming.maxPayloadSize` means
/// desync — a corrupt peer, a dropped byte, framing drift — and this wire
/// format carries no resync token to hunt for the next real frame boundary
/// inside the garbage that follows. So RESET means exactly this: the
/// entire buffer is discarded — the bad length prefix, anything else
/// already appended during this `ingest` call, and any previously-buffered
/// trailing partial frame. Whatever bytes were lost stay lost; the type
/// simply starts framing fresh from the very next byte handed to a later
/// `ingest` call, so a subsequent well-formed frame parses normally once
/// the peer's next write/notify lands cleanly on a frame boundary.
///
/// Pure value type, no I/O — the whole reason this codec is factored out
/// of `BLEWandLink`.
struct FrameReassembler {
    private var buffer = Data()

    /// Feed newly arrived bytes; returns zero or more complete payloads
    /// extracted this call, in the order their frames completed.
    @discardableResult
    mutating func ingest(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var payloads: [Data] = []
        while buffer.count >= 2 {
            let hi = Int(buffer[buffer.startIndex])
            let lo = Int(buffer[buffer.startIndex + 1])
            let length = (hi << 8) | lo
            guard length <= BLEWandFraming.maxPayloadSize else {
                // Desync — see the type header above. Drop everything
                // buffered (this frame's bad header included) and stop;
                // nothing after an untrustworthy length can be trusted.
                buffer.removeAll()
                return payloads
            }
            let frameEnd = buffer.startIndex + 2 + length
            guard buffer.endIndex >= frameEnd else { break } // frame not fully arrived yet
            let payloadStart = buffer.startIndex + 2
            payloads.append(buffer.subdata(in: payloadStart..<frameEnd))
            buffer.removeSubrange(buffer.startIndex..<frameEnd)
        }
        return payloads
    }
}

// MARK: - D28: BLE fallback tunnel for the StageWand hardware remote

/// When a StageWand's show Wi-Fi link drops it falls back to advertising a
/// BLE GATT service, and StageWizard tunnels the EXACT same OSC 1.0 wire
/// contract UDP uses (`OSCServer`/`OSCStatusFeedback`) over it — see
/// CLAUDE.md's StageWand-contract bullet. This class is the host (central)
/// side: standing scan, connect, discover, subscribe, reassemble inbound
/// frames into `OSCMessage`s, and frame+chunk outbound feedback. The wand
/// hardware doesn't exist yet — this is built to spec for testing against a
/// dev board or a GATT tool (e.g. LightBlue) acting as the peripheral.
///
/// GATT shape (fixed by the wand team's spec):
///   Service     `8B0F4F44-5A5B-4EC1-A0E9-77616E640001`
///   Char `…0002`  writable (Write Without Response preferred, Write
///                 accepted) — the HOST writes here.
///   Char `…0003`  notify                              — the HOST
///                 subscribes here.
///
/// NOTE ON THE WAND DOC'S DIRECTION LABELS: the wand team's spec table
/// calls `…0002` "commands" (central→wand) and `…0003` "feedback"
/// (wand→central) — but GATT mechanics only let the central (StageWizard)
/// WRITE to `…0002` and RECEIVE notifies from `…0003`, and logically
/// commands ORIGINATE at the wand (a button press) while feedback
/// ORIGINATES at the host (status/cuelist). So concretely: commands travel
/// wand→host as notifies on `…0003`, and feedback travels host→wand as
/// writes to `…0002` — the doc's column headers name the data's logical
/// source, not which GATT operation carries it, and read backwards if you
/// assume "the commands characteristic is what the host writes commands
/// to". This class implements the symmetric tunnel GATT actually demands:
/// `onInboundMessages` fires for bytes reassembled from `…0003` notifies
/// (wand commands + `/stagewand/ping`), `broadcast(_:)` writes framed bytes
/// to `…0002` (host feedback). Flag this back to the wand team so the two
/// columns in their doc get swapped.
///
/// Concurrency: `@MainActor`. `CBCentralManager` is created with
/// `queue: nil`, which per CoreBluetooth's documented contract dispatches
/// EVERY delegate callback on the main dispatch queue — unlike CoreMIDI or
/// Network.framework (see `MIDIController`/`OSCServer`'s headers), there is
/// no separate background queue in play here. That guarantee is real, but
/// it's a RUNTIME fact, not something Swift 6's static isolated-conformance
/// check can see: `CBCentralManagerDelegate`/`CBPeripheralDelegate` are
/// plain (non-actor-isolated) ObjC protocols, so a MainActor-isolated
/// method can't satisfy their requirements directly — the compiler rejects
/// that as "crosses into main actor-isolated code and can cause data
/// races", regardless of what CoreBluetooth actually promises at runtime.
/// The pattern here (see the two `CBCentralManagerDelegate`/
/// `CBPeripheralDelegate` extensions below) is therefore: every protocol
/// requirement is a thin `nonisolated` shim that calls
/// `MainActor.assumeIsolated { … }` before forwarding to an ordinary
/// MainActor-isolated private handler — `assumeIsolated` is sound
/// specifically because `queue: nil` really does put us on the main queue
/// already, so it's asserting a known fact rather than gambling on one.
/// This is DELIBERATELY `MainActor.assumeIsolated`, not
/// `Task { @MainActor in … }`: a `Task` hop would defer the actual work to
/// a later main-queue turn for no reason (reordering delivery relative to
/// other main-queue work) when we already know synchronously that we're on
/// the right queue. Contrast `MIDIController`'s `@Sendable` + explicit
/// `Task` hop and `VirtualCameraManager`'s `nonisolated` + `Task` hop for
/// `OSSystemExtensionRequestDelegate` — both of THOSE use `Task` because
/// their frameworks deliver callbacks off-main with no such guarantee, so
/// `assumeIsolated` there would be unsound (and would trap).
@MainActor
@Observable
final class BLEWandLink: NSObject {
    static let serviceUUID = CBUUID(string: "8B0F4F44-5A5B-4EC1-A0E9-77616E640001")
    /// The host WRITES feedback here — see the direction note above.
    static let writeCharUUID = CBUUID(string: "8B0F4F44-5A5B-4EC1-A0E9-77616E640002")
    /// The host RECEIVES commands (as notifies) here — see the direction note above.
    static let notifyCharUUID = CBUUID(string: "8B0F4F44-5A5B-4EC1-A0E9-77616E640003")

    /// Number of wands currently past setup (services/characteristics
    /// discovered, notify subscribed, full refresh sent) — feeds the Remote
    /// settings tab's "BLE: n wand(s) connected" line. UI-facing.
    private(set) var connectedWandCount = 0

    /// Inbound OSC messages reassembled from ANY connected wand's `…0003`
    /// notifies. AppModel resolves each to an `OSCCommand` via the exact
    /// same `OSCServer.command(for:)` routing table the UDP path uses, and
    /// dispatches through the exact same handler — see
    /// `AppModel.handleOSCCommand`. `/stagewand/ping` arrives here too and
    /// is silently accepted (it resolves to no command).
    var onInboundMessages: (([OSCMessage]) -> Void)?
    /// Called once per newly-live wand (connect + notify-subscribe) — must
    /// return the FULL current status feed, exactly like
    /// `OSCServer.fullRefreshProvider`. Connection IS the subscription for
    /// BLE: there's no 5 s liveness window the way UDP's
    /// `OSCSubscriberRegistry` has — connected means live, disconnected
    /// means gone — so this is the only "new subscriber" trigger.
    var fullRefreshProvider: (() -> [OSCMessage])?

    /// Per-connected-peripheral bookkeeping.
    private final class WandConnection {
        let peripheral: CBPeripheral
        var writeChar: CBCharacteristic?
        var writeType: CBCharacteristicWriteType = .withoutResponse
        var notifyChar: CBCharacteristic?
        var reassembler = FrameReassembler()
        /// Outbound frame chunks not yet written — refilled by
        /// `enqueue(_:to:)`, drained by `flush(_:writeChar:)` as the
        /// peripheral reports capacity (`canSendWriteWithoutResponse` /
        /// `peripheralIsReady(toSendWriteWithoutResponse:)`, or the
        /// matching `didWriteValueFor` when using `.withResponse`).
        var outbox: [Data] = []
        var awaitingWriteResponse = false
        /// True once notify is subscribed and the full refresh has been
        /// sent — the point at which this wand counts toward
        /// `connectedWandCount` and starts receiving `broadcast(_:)`.
        var isLive = false

        init(peripheral: CBPeripheral) {
            self.peripheral = peripheral
        }
    }

    @ObservationIgnored private var manager: CBCentralManager?
    @ObservationIgnored private var connections: [ObjectIdentifier: WandConnection] = [:]
    /// The wanted state — true between `start()` and `stop()`. Distinct
    /// from `manager != nil` only during the brief window before the first
    /// `centralManagerDidUpdateState` callback (scanning is deferred until
    /// that callback reports `.poweredOn`).
    @ObservationIgnored private var isEnabled = false
    /// Separate token from AppModel's playback `activityToken` (D9) — this
    /// one covers "the BLE scan/link is active", not "a cue is running".
    /// `.background` (deliberately NOT `.idleSystemSleepDisabled`/
    /// `.idleDisplaySleepDisabled`) is the point: exempt the standing scan
    /// from App Nap throttling without keeping an otherwise-idle Mac awake
    /// just because OSC+BLE fallback is armed with no wand around — actual
    /// sleep prevention while a show is running is already covered by the
    /// playback token.
    @ObservationIgnored private var activityToken: NSObjectProtocol?

    override init() {
        super.init()
    }

    // MARK: - Lifecycle (owned by AppModel.applyOSCSettings, alongside the
    // UDP listener — BLE rides `oscEnabled`, no setting of its own; the
    // Bluetooth permission prompt fires on first scan, which is why nothing
    // above ever constructs a `CBCentralManager` until `start()` is called)

    func start() {
        guard !isEnabled else { return }
        isEnabled = true
        updateActivityAssertion()
        manager = CBCentralManager(
            delegate: self, queue: nil,
            options: [CBCentralManagerOptionShowPowerAlertKey: false]
        )
    }

    func stop() {
        isEnabled = false
        if let manager {
            manager.stopScan()
            for connection in connections.values {
                manager.cancelPeripheralConnection(connection.peripheral)
            }
        }
        connections.removeAll()
        connectedWandCount = 0
        manager = nil
        updateActivityAssertion()
    }

    private func updateActivityAssertion() {
        if isEnabled, activityToken == nil {
            activityToken = ProcessInfo.processInfo.beginActivity(
                options: [.background], reason: "BLE StageWand link"
            )
        } else if !isEnabled, let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
    }

    // MARK: - Outbound feedback (host → wand, written to `…0002`)

    /// Frame + chunk + write `messages` to every currently-live wand — the
    /// BLE half of the fan-out AppModel drives alongside
    /// `oscServer.broadcast` (see `OSCFeedbackFanout` in
    /// OSCStatusFeedback.swift). No-op while disabled or with nothing
    /// live, mirroring `OSCServer.broadcast`'s own guards.
    func broadcast(_ messages: [OSCMessage]) {
        guard isEnabled, !messages.isEmpty else { return }
        for connection in connections.values where connection.isLive {
            enqueue(messages, to: connection)
        }
    }

    /// Frame every message, chunk each frame to the peripheral's current
    /// write MTU, and append the chunks to `connection`'s outbox before
    /// draining whatever the link currently has capacity for.
    private func enqueue(_ messages: [OSCMessage], to connection: WandConnection) {
        guard let writeChar = connection.writeChar else { return }
        let mtu = max(connection.peripheral.maximumWriteValueLength(for: connection.writeType), 1)
        for message in messages {
            let payload = OSCServer.encode(address: message.address, arguments: message.arguments)
            let framed = BLEWandFraming.frame(payload)
            var offset = framed.startIndex
            while offset < framed.endIndex {
                let end = min(offset + mtu, framed.endIndex)
                connection.outbox.append(framed.subdata(in: offset..<end))
                offset = end
            }
        }
        flush(connection, writeChar: writeChar)
    }

    /// Drain `connection`'s outbox as far as the link currently allows.
    /// `.withoutResponse` (preferred) is gated by `canSendWriteWithoutResponse`
    /// and resumes from `peripheralIsReady(toSendWriteWithoutResponse:)`;
    /// `.withResponse` (fallback, only if the wand doesn't expose
    /// `.writeWithoutResponse`) sends one chunk at a time and resumes from
    /// `didWriteValueFor`.
    private func flush(_ connection: WandConnection, writeChar: CBCharacteristic) {
        while !connection.outbox.isEmpty {
            if connection.writeType == .withoutResponse {
                guard connection.peripheral.canSendWriteWithoutResponse else { return }
            } else if connection.awaitingWriteResponse {
                return
            }
            let chunk = connection.outbox.removeFirst()
            connection.peripheral.writeValue(chunk, for: writeChar, type: connection.writeType)
            if connection.writeType == .withResponse {
                connection.awaitingWriteResponse = true
            }
        }
    }

    /// A wand's notify subscription just confirmed — it's live. Update the
    /// connected count and send the full status/cuelist burst to this wand
    /// alone (see `fullRefreshProvider`'s doc comment).
    private func markLive(_ connection: WandConnection) {
        guard !connection.isLive else { return }
        connection.isLive = true
        recomputeConnectedCount()
        guard let fullRefreshProvider else { return }
        enqueue(fullRefreshProvider(), to: connection)
    }

    private func recomputeConnectedCount() {
        connectedWandCount = connections.values.filter { $0.isLive }.count
    }

    /// Re-issue a connect for a peripheral we still want — CoreBluetooth
    /// connect requests never time out on their own, which is exactly what
    /// makes this the whole standing-reconnect mechanism: call it after
    /// every disconnect and every failed connect attempt, unconditionally,
    /// for as long as the link is enabled.
    private func reconnect(_ peripheral: CBPeripheral) {
        guard isEnabled, let manager, manager.state == .poweredOn else { return }
        manager.connect(peripheral, options: nil)
    }
}

// MARK: - CBCentralManagerDelegate
//
// Every requirement here is `nonisolated` — CBCentralManagerDelegate is a
// plain (non-actor-isolated) ObjC protocol, so a MainActor-isolated method
// can't satisfy it directly (Swift 6's isolated-conformance check rejects
// that: "crosses into main actor-isolated code and can cause data races").
// Each requirement is therefore a thin `nonisolated` shim that immediately
// calls `MainActor.assumeIsolated { … }` before touching any actor state —
// sound specifically because `queue: nil` (see the class header) is
// CoreBluetooth's own guarantee that this callback is ALREADY running on
// the main queue, so `assumeIsolated` is asserting a fact rather than
// hoping for one. This is deliberately `MainActor.assumeIsolated`, not
// `Task { @MainActor in … }`: a `Task` hop would defer the actual work to
// a later main-queue turn for no reason, reordering delivery relative to
// other main-queue work with zero benefit, since we already know we're on
// the right queue synchronously. All the real logic stays in ordinary
// MainActor-isolated private methods below, which is also what keeps this
// forwarding layer trivially easy to audit for "did I remember to hop".

extension BLEWandLink: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            self.handleCentralManagerDidUpdateState(central)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            self.handleDidDiscover(peripheral, central: central)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            self.handleDidConnect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            self.reconnect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            self.handleDidDisconnect(peripheral)
        }
    }
}

private extension BLEWandLink {
    func handleCentralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            guard isEnabled else { return }
            // Standing scan — never stopped while enabled (not even once a
            // wand connects), so additional wands keep being discoverable.
            central.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)
        default:
            // .poweredOff/.unauthorized/.unsupported/.resetting/.unknown —
            // every existing peripheral reference is invalid once the radio
            // resets; forget them. A later transition back to `.poweredOn`
            // re-scans and rediscovers/reconnects from scratch.
            connections.removeAll()
            connectedWandCount = 0
        }
    }

    func handleDidDiscover(_ peripheral: CBPeripheral, central: CBCentralManager) {
        let key = ObjectIdentifier(peripheral)
        guard connections[key] == nil else { return } // already tracked (connecting/connected)
        let connection = WandConnection(peripheral: peripheral)
        connections[key] = connection
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    func handleDidConnect(_ peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.serviceUUID])
    }

    func handleDidDisconnect(_ peripheral: CBPeripheral) {
        if let connection = connections[ObjectIdentifier(peripheral)] {
            connection.writeChar = nil
            connection.notifyChar = nil
            connection.reassembler = FrameReassembler()
            connection.outbox.removeAll()
            connection.awaitingWriteResponse = false
            if connection.isLive {
                connection.isLive = false
                recomputeConnectedCount()
            }
        }
        reconnect(peripheral)
    }
}

// MARK: - CBPeripheralDelegate (same nonisolated + `MainActor.assumeIsolated`
// shim pattern as CBCentralManagerDelegate above, same justification)

extension BLEWandLink: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            self.handleDidDiscoverServices(peripheral, error: error)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            self.handleDidDiscoverCharacteristics(peripheral, service: service, error: error)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            self.handleDidUpdateNotificationState(peripheral, characteristic: characteristic, error: error)
        }
    }

    /// A notify fired on `…0003` — reassemble and hand any complete
    /// payloads to `onInboundMessages` as parsed `OSCMessage`s. Mirrors
    /// `OSCServer.receiveNext`'s inbound path: parsing is pure, only the
    /// resulting value types leave this callback.
    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            self.handleDidUpdateValue(peripheral, characteristic: characteristic, error: error)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            self.handleDidWriteValue(peripheral, characteristic: characteristic)
        }
    }

    nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            self.handlePeripheralIsReady(peripheral)
        }
    }
}

private extension BLEWandLink {
    func handleDidDiscoverServices(_ peripheral: CBPeripheral, error: Error?) {
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else { return }
        peripheral.discoverCharacteristics([Self.writeCharUUID, Self.notifyCharUUID], for: service)
    }

    func handleDidDiscoverCharacteristics(_ peripheral: CBPeripheral, service: CBService, error: Error?) {
        guard error == nil, let connection = connections[ObjectIdentifier(peripheral)],
              let characteristics = service.characteristics else { return }
        for characteristic in characteristics {
            switch characteristic.uuid {
            case Self.writeCharUUID:
                connection.writeChar = characteristic
                connection.writeType = characteristic.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
            case Self.notifyCharUUID:
                connection.notifyChar = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            default:
                break
            }
        }
    }

    func handleDidUpdateNotificationState(_ peripheral: CBPeripheral, characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.notifyCharUUID, error == nil, characteristic.isNotifying,
              let connection = connections[ObjectIdentifier(peripheral)] else { return }
        markLive(connection)
    }

    func handleDidUpdateValue(_ peripheral: CBPeripheral, characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.notifyCharUUID, error == nil,
              let data = characteristic.value, !data.isEmpty,
              let connection = connections[ObjectIdentifier(peripheral)] else { return }
        let payloads = connection.reassembler.ingest(data)
        guard !payloads.isEmpty else { return }
        let messages = payloads.flatMap { OSCServer.parse($0) }
        guard !messages.isEmpty else { return }
        onInboundMessages?(messages)
    }

    func handleDidWriteValue(_ peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        guard characteristic.uuid == Self.writeCharUUID, let connection = connections[ObjectIdentifier(peripheral)] else { return }
        connection.awaitingWriteResponse = false
        flush(connection, writeChar: characteristic)
    }

    func handlePeripheralIsReady(_ peripheral: CBPeripheral) {
        guard let connection = connections[ObjectIdentifier(peripheral)], let writeChar = connection.writeChar else { return }
        flush(connection, writeChar: writeChar)
    }
}
