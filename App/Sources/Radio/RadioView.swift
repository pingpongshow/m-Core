import MeshCoreKit
import MeshDesign
import SwiftUI

/// Settings → Radio: connect over Bluetooth, Wi‑Fi (TCP) or the simulator, and show what the radio reported.
struct RadioView: View {
    @Environment(RadioConnectionModel.self) private var radio
    @State private var host = ""
    @State private var port = String(MeshCoreProtocol.defaultTCPPort)

    var body: some View {
        List {
            statusSection
            if let info = radio.connectionInfo {
                ConnectedRadioSections(info: info, battery: radio.battery)
                Section {
                    Button("Disconnect", role: .destructive) {
                        Task { await radio.disconnect() }
                    }
                }
            } else if radio.isActive {
                Section {
                    Button("Cancel", role: .destructive) {
                        Task { await radio.disconnect() }
                    }
                }
            } else {
                if let last = radio.lastTarget {
                    Section {
                        Button {
                            Task { await radio.connect(to: last) }
                        } label: {
                            Label("Reconnect to \(last.displayName)", systemImage: "arrow.clockwise")
                        }
                    }
                }
                bluetoothSection
                tcpSection
                #if DEBUG
                Section {
                    Button {
                        Task { await radio.connect(to: .simulator) }
                    } label: {
                        Label("Connect to simulated radio", systemImage: "cpu")
                    }
                } footer: {
                    Text("Debug builds only. Answers like a real radio for UI testing.")
                }
                #endif
            }
        }
        .navigationTitle("Radio")
        .onDisappear { radio.stopScan() }
    }

    private var statusSection: some View {
        Section {
            StatusPill(connection: radio.status)
            if case let .waitingToReconnect(_, delay, error) = radio.state {
                Text("Retrying in \(max(1, delay.components.seconds)) s · \(error)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var bluetoothSection: some View {
        Section {
            ForEach(radio.discovered.sorted { $0.rssi > $1.rssi }) { found in
                Button {
                    Task { await radio.connect(to: .bluetooth(id: found.id, name: found.name)) }
                } label: {
                    HStack {
                        Text(found.name).foregroundStyle(Color.primary)
                        Spacer()
                        if found.rssi != 0 {
                            Text("\(found.rssi) dBm").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Button(radio.isScanning ? "Stop scanning" : "Scan for radios") {
                radio.isScanning ? radio.stopScan() : radio.startScan()
            }
        } header: {
            HStack {
                Text("Bluetooth")
                if radio.isScanning { ProgressView().controlSize(.small) }
            }
        } footer: {
            Text("Radios with a PIN show the system pairing prompt on first connect.")
        }
    }

    private var tcpSection: some View {
        Section("Wi‑Fi (TCP)") {
            TextField("Host or IP address", text: $host)
                .textContentType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            TextField("Port", text: $port)
                .keyboardType(.numberPad)
            Button("Connect") {
                guard let portNumber = UInt16(port) else { return }
                Task { await radio.connect(to: .tcp(host: host.trimmingCharacters(in: .whitespaces), port: portNumber)) }
            }
            .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty || UInt16(port) == nil)
        }
    }
}

/// Details from the handshake: device, identity, radio settings, clock and battery.
struct ConnectedRadioSections: View {
    let info: ConnectionInfo
    let battery: BatteryAndStorage?

    var body: some View {
        Section("Device") {
            row("Model", info.device.model)
            row("Firmware", [info.device.firmwareVersion, info.device.buildDate].compactMap { $0 }.joined(separator: " · "))
            row("Protocol", "v\(info.device.protocolVersion)")
            if let contacts = info.device.maxContacts, let channels = info.device.maxChannels {
                row("Capacity", "\(contacts) contacts · \(channels) channels")
            }
            if let battery {
                row("Battery", String(format: "%.2f V", Double(battery.millivolts) / 1000))
                row("Storage", "\(battery.usedKB) of \(battery.totalKB) KB used")
            }
        }
        Section("Identity") {
            row("Name", info.selfInfo.name)
            LabeledContent("Public key") {
                Text(info.selfInfo.publicKey.prefix.hex.uppercased()).font(.body.monospaced())
            }
            row("Position", positionText)
            row("Share in adverts", info.selfInfo.sharesLocationInAdverts ? "On" : "Off")
        }
        Section("LoRa") {
            let radio = info.selfInfo.radio
            row("Frequency", String(format: "%.3f MHz", radio.frequencyMHz))
            row("Bandwidth", String(format: "%g kHz", radio.bandwidthKHz))
            row("Spreading factor", "SF\(radio.spreadingFactor)")
            row("Coding rate", "4/\(radio.codingRate)")
            row("TX power", "\(info.selfInfo.txPowerDbm) dBm (max \(info.selfInfo.maxTxPowerDbm))")
        }
        Section("Clock") {
            switch info.clockSync {
            case .updated:
                row("Radio clock", "Set from phone")
            case .radioAhead(let radioTime):
                row("Radio clock", "Ahead of phone: \(Date(timeIntervalSince1970: TimeInterval(radioTime)).formatted())")
            }
        }
    }

    private var positionText: String {
        guard info.selfInfo.latitudeE6 != 0 || info.selfInfo.longitudeE6 != 0 else { return "Not set" }
        return String(format: "%.5f, %.5f", info.selfInfo.latitude, info.selfInfo.longitude)
    }

    private func row(_ title: String, _ value: String?) -> some View {
        LabeledContent(title, value: value?.isEmpty == false ? value! : "—")
    }
}
