import CoreImage.CIFilterBuiltins
import Darwin
import SwiftUI

/// Operator-facing description of a captured MIDI-Learn binding
/// ("Note 60 ch 1" / "CC 64 ch 1"). Mirrors KeyBinding.displayName's role
/// for keyboard shortcuts — channels are displayed 1-based, as every DAW/
/// controller does, even though the wire value is 0-15.
extension MIDIBinding {
    var displayName: String {
        switch kind {
        case .noteOn: return "Note \(number) ch \(channel + 1)"
        case .controlChange: return "CC \(number) ch \(channel + 1)"
        }
    }
}

/// MIDI remote-control settings — a tab inside SettingsPanelView. Enable
/// toggle, connected-source list, and one MIDI-Learn binding row per
/// bindable transport action (the same set the keyboard shortcuts tab
/// exposes — see ShortcutAction.assignable).
struct RemoteSettingsTab: View {
    @Environment(ShowDocumentController.self) private var document
    @Environment(AppModel.self) private var app
    @State private var learningAction: ShortcutAction?
    @State private var portText: String = ""
    @State private var webRemotePortText: String = ""

    var body: some View {
        Form {
            Section("MIDI Control") {
                Toggle("Enable MIDI Control", isOn: Binding(
                    get: { document.show.settings.midiEnabled },
                    set: { app.setMIDIEnabled($0) }
                ))

                if app.midiController.sources.isEmpty {
                    Text("No MIDI sources")
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(app.midiController.sources, id: \.self) { name in
                        Label(name, systemImage: "pianokeys")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Bindings") {
                ForEach(ShortcutAction.assignable, id: \.self) { action in
                    bindingRow(for: action)
                }
            }

            Section("OSC") {
                Toggle("Enable OSC Control", isOn: Binding(
                    get: { document.show.settings.oscEnabled },
                    set: { app.setOSCEnabled($0) }
                ))

                HStack {
                    Text("Port")
                    TextField("Port", text: $portText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                        .onSubmit { commitPort() }
                    Spacer()
                    Text(oscStatusText)
                        .foregroundStyle(.secondary)
                }

                Text("Addresses: /stagewizard/go, /stopall, /next, /prev, /toggle, /panic, /cue/{number}/fire, /cue/{number}/select")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Sends status feedback to any sender (StageWand): /stagewizard/status/…. Advertised on the network as _stagewizard._udp.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Unauthenticated — enable only on a trusted show network.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Web Remote") {
                Toggle("Enable Web Remote", isOn: Binding(
                    get: { document.show.settings.webRemoteEnabled },
                    set: { app.setWebRemoteEnabled($0) }
                ))

                HStack {
                    Text("Port")
                    TextField("Port", text: $webRemotePortText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                        .onSubmit { commitWebRemotePort() }
                    Spacer()
                    Text(webRemoteStatusText)
                        .foregroundStyle(.secondary)
                }

                if document.show.settings.webRemoteEnabled, app.webRemoteServer.isRunning {
                    webRemoteURLRow
                }

                Text("Open on your phone — unauthenticated, enable only on a trusted show network.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            Text("MIDI, OSC, and the web remote are active in every mode while enabled.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.bottom, 8)
        }
        .onAppear {
            portText = String(document.show.settings.oscPort)
            webRemotePortText = String(document.show.settings.webRemotePort)
        }
        .onDisappear {
            if learningAction != nil { cancelLearning() }
        }
    }

    // MARK: - Web Remote

    private var webRemoteStatusText: String {
        guard document.show.settings.webRemoteEnabled else { return "Off" }
        if let error = app.webRemoteServer.lastError { return "Error: \(error)" }
        return app.webRemoteServer.isRunning
            ? "Running on port \(document.show.settings.webRemotePort)"
            : "Starting…"
    }

    @ViewBuilder
    private var webRemoteURLRow: some View {
        if let address = Self.currentLANAddress() {
            let url = "http://\(address):\(document.show.settings.webRemotePort)"
            HStack(alignment: .top, spacing: 12) {
                if let qr = Self.qrImage(for: url) {
                    Image(nsImage: qr)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: 120, height: 120)
                        .padding(8)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Scan or open:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(url)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                Spacer()
            }
            .padding(.vertical, 4)
        } else {
            Text("No network — connect this Mac to the show's Wi-Fi or Ethernet.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func commitWebRemotePort() {
        guard let value = Int(webRemotePortText) else {
            webRemotePortText = String(document.show.settings.webRemotePort)
            return
        }
        let clamped = UInt16(min(max(value, 1024), 65535))
        webRemotePortText = String(clamped)
        app.setWebRemotePort(clamped)
    }

    /// First non-loopback IPv4 address on a Wi-Fi/Ethernet interface
    /// (en0-style) — good enough for showing the operator a URL to type or
    /// scan. Returns nil when there's no such interface (no network).
    private static func currentLANAddress() -> String? {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let flags = interface.ifa_flags
            guard flags & UInt32(IFF_UP) != 0, flags & UInt32(IFF_LOOPBACK) == 0,
                  let sa = interface.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            guard String(cString: interface.ifa_name).hasPrefix("en") else { continue }

            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(sa, socklen_t(sa.pointee.sa_len), &hostBuffer, socklen_t(hostBuffer.count), nil, 0, NI_NUMERICHOST)
            guard status == 0 else { continue }
            return hostBuffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        }
        return nil
    }

    /// A crisp (non-anti-aliased) QR code for `text`, generated at native
    /// module resolution — the caller scales it up with nearest-neighbor
    /// interpolation (`.interpolation(.none)`) so edges stay sharp instead
    /// of blurring, which CIQRCodeGenerator's own affine upscale would do.
    private static func qrImage(for text: String) -> NSImage? {
        guard let data = text.data(using: .utf8) else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    private var oscStatusText: String {
        guard document.show.settings.oscEnabled else { return "Off" }
        if let error = app.oscServer.lastError { return "Error: \(error)" }
        return app.oscServer.isRunning
            ? "Running on port \(document.show.settings.oscPort)"
            : "Starting…"
    }

    private func commitPort() {
        guard let value = Int(portText) else {
            portText = String(document.show.settings.oscPort)
            return
        }
        let clamped = UInt16(min(max(value, 1024), 65535))
        portText = String(clamped)
        app.setOSCPort(clamped)
    }

    private func bindingRow(for action: ShortcutAction) -> some View {
        let binding = document.show.settings.midiBindings.first { $0.action == action }?.binding
        let isLearning = learningAction == action

        return HStack {
            Text(action.displayName)
            Spacer()
            Text(isLearning ? "Listening…" : (binding?.displayName ?? "—"))
                .foregroundStyle(binding == nil && !isLearning ? .secondary : .primary)
                .frame(minWidth: 110, alignment: .trailing)
            Button(isLearning ? "Cancel" : "Learn") {
                if isLearning {
                    cancelLearning()
                } else {
                    startLearning(for: action)
                }
            }
            .disabled(learningAction != nil && !isLearning)
            if binding != nil && !isLearning {
                Button {
                    clearBinding(for: action)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove MIDI binding")
            }
        }
    }

    private func startLearning(for action: ShortcutAction) {
        learningAction = action
        app.midiController.onLearned = { binding in
            assign(binding, to: action)
            learningAction = nil
        }
        app.midiController.learning = true
    }

    private func cancelLearning() {
        app.midiController.cancelLearning()
        learningAction = nil
    }

    private func assign(_ binding: MIDIBinding, to action: ShortcutAction) {
        document.mutate { show in
            // One trigger, one meaning: steal from any other action already
            // using this exact MIDI message — same rule ShortcutBindingsForm
            // applies to keyboard bindings, so a duplicate can't go dead.
            show.settings.midiBindings.removeAll { $0.binding == binding || $0.action == action }
            show.settings.midiBindings.append(MIDIBindingEntry(binding: binding, action: action))
        }
    }

    private func clearBinding(for action: ShortcutAction) {
        document.mutate { show in
            show.settings.midiBindings.removeAll { $0.action == action }
        }
    }
}
