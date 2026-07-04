import CoreAudio
import Foundation
import Observation

/// A Core Audio output-capable device, described by its *persistent* UID.
/// AudioDeviceID is a transient per-boot handle — show files store only the UID
/// and resolve it back through `AudioDeviceManager.deviceID(forUID:)`.
public struct AudioOutputDevice: Identifiable, Hashable, Sendable {
    public let deviceID: AudioDeviceID
    public let uid: String
    public let name: String
    public let channelCount: Int

    public var id: String { uid }
}

/// Enumerates output devices via the Core Audio HAL and watches for hot-plug.
///
/// Concurrency: @MainActor. HAL property reads are cheap synchronous calls and
/// run on the main actor; the one hardware listener block arrives on a private
/// dispatch queue and immediately hops to the main actor.
@MainActor
@Observable
public final class AudioDeviceManager {
    public static let shared = AudioDeviceManager()

    /// All output-capable devices (≥1 output channel), sorted by name.
    public private(set) var outputDevices: [AudioOutputDevice] = []
    /// The system default output device, if one exists.
    public private(set) var defaultOutputDevice: AudioOutputDevice?
    /// Invoked (on the main actor) after every re-enumeration triggered by a
    /// hardware change. The UI/engine layer can hang banners or re-checks here.
    public var onDevicesChanged: (@MainActor () -> Void)?

    /// Queue the HAL delivers the device-list listener block on.
    private let halListenerQueue = DispatchQueue(label: "com.marcotempest.stagewizard.hal-listener")

    private init() {
        refreshDevices(notify: false)
        installHardwareListener()
    }

    // MARK: - UID resolution

    /// Resolve a persisted device UID to today's AudioDeviceID via
    /// kAudioHardwarePropertyTranslateUIDToDevice. nil = device not connected.
    public func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var cfUID: CFString? = uid as CFString
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString?>.size),
                uidPointer,
                &size,
                &deviceID
            )
        }
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    // MARK: - Enumeration

    /// Re-read the device list from the HAL. `notify` fires onDevicesChanged.
    public func refreshDevices(notify: Bool = true) {
        var devices: [AudioOutputDevice] = []
        for id in Self.allDeviceIDs() {
            let channels = Self.outputChannelCount(of: id)
            guard channels > 0, let uid = Self.stringProperty(of: id, selector: kAudioDevicePropertyDeviceUID) else {
                continue
            }
            let name = Self.stringProperty(of: id, selector: kAudioObjectPropertyName) ?? uid
            devices.append(AudioOutputDevice(deviceID: id, uid: uid, name: name, channelCount: channels))
        }
        outputDevices = devices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        if let defaultID = Self.defaultOutputDeviceID() {
            defaultOutputDevice = outputDevices.first { $0.deviceID == defaultID }
        } else {
            defaultOutputDevice = nil
        }

        if notify {
            onDevicesChanged?()
        }
    }

    // MARK: - Hardware listener

    /// ONE process-lifetime listener on kAudioHardwarePropertyDevices. Never
    /// removed: the HAL's listener-removal API is historically unreliable, and
    /// this object lives for the whole process anyway.
    private func installHardwareListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // @Sendable is load-bearing: without it this literal inherits the
        // class's MainActor isolation, and Swift's runtime isolation check
        // TRAPS when CoreAudio invokes it on the HAL queue (the C API's block
        // parameter isn't @Sendable-audited, so the compiler can't catch it).
        _ = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            halListenerQueue
        ) { @Sendable [weak self] _, _ in
            // HAL queue → hop to the main actor before touching any state.
            // The address pointer is only valid inside this block; don't use it.
            Task { @MainActor in
                self?.refreshDevices(notify: true)
            }
        }
    }

    // MARK: - HAL property plumbing (nonisolated pure reads)

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        let status = ids.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, buffer.baseAddress!)
        }
        guard status == noErr else { return [] }
        return ids
    }

    /// Output channel count = sum of mNumberChannels over the output-scope
    /// stream configuration. 0 → not an output device.
    private static func outputChannelCount(of device: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let bufferList = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(of device: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let cf = value?.takeRetainedValue() else { return nil }
        return cf as String
    }

    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }
}
