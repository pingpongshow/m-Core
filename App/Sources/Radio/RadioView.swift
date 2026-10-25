import MeshCoreKit
import MeshDesign
import MeshServices
import SwiftUI

/// Settings → Radio: connect over Bluetooth or Wi‑Fi (TCP), and show what the radio reported.
struct RadioView: View {
    @Environment(RadioController.self) private var radio
    @Environment(AccessoryPairing.self) private var pairing
    @State private var host = ""
    @State private var port = String(MeshCoreProtocol.defaultTCPPort)
    @State private var renaming: KnownRadio?
    @State private var newName = ""

    var body: some View {
        List {
            statusSection
            if let info = currentInfo {
                ConnectedRadioSections(info: info, battery: radio.battery, chemistry: radio.batteryChemistry)
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
                if !radio.knownRadios.isEmpty { knownRadiosSection }
                bluetoothSection
                tcpSection
            }
        }
        .navigationTitle("Radio")
        .onDisappear { radio.stopScan() }
        .alert("Rename radio", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") {
                if let renaming { radio.renameKnownRadio(renaming, to: newName) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("Leave empty to use the name the radio reports.")
        }
    }

    /// The handshake's details, with the identity the radio has reported since (e.g. the position the GPS Feed
    /// wrote, a new name or radio settings).
    private var currentInfo: ConnectionInfo? {
        guard var info = radio.connectionInfo else { return nil }
        if let selfInfo = radio.selfInfo { info.selfInfo = selfInfo }
        return info
    }

    private var knownRadiosSection: some View {
        Section {
            ForEach(radio.knownRadios) { known in
                Button {
                    Task { await radio.connect(to: known.target) }
                } label: {
                    KnownRadioRow(radio: known, needsAdding: needsAdding(known))
                }
                .swipeActions {
                    Button("Forget", role: .destructive) {
                        Task { await radio.forgetKnownRadio(known) }
                    }
                    .tint(MCColor.critical)
                    Button("Rename") { startRenaming(known) }
                        .tint(MCColor.accentFill)
                }
                .contextMenu {
                    Button("Rename", systemImage: "pencil") { startRenaming(known) }
                    Button("Forget", systemImage: "trash", role: .destructive) {
                        Task { await radio.forgetKnownRadio(known) }
                    }
                }
            }
        } header: {
            Text("My radios")
        } footer: {
            Text("Tap to connect. Swipe to rename or forget a radio.")
        }
    }

    private func needsAdding(_ known: KnownRadio) -> Bool {
        guard case .bluetooth(let id, _) = known.target else { return false }
        return pairing.isEnabled && pairing.isReady && !pairing.mayConnect(to: id)
    }

    private func startRenaming(_ known: KnownRadio) {
        newName = known.customName ?? ""
        renaming = known
    }

    private var statusSection: some View {
        Section {
            StatusPill(connection: radio.status)
            if case let .waitingToReconnect(_, delay, error) = radio.state {
                Text("Retrying in \(max(1, delay.components.seconds)) s · \(error)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let problem = radio.connectionProblem ?? pairing.lastError {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(MCColor.warning)
            }
        }
    }

    private var bluetoothSection: some View {
        Section {
            if pairing.isEnabled {
                Button {
                    pairing.showPicker()
                } label: {
                    Label("Add radio", systemImage: "plus.circle.fill")
                }
                .disabled(pairing.isPickerShowing || !pairing.isReady)
            }
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
            // With an icon, like Add radio above it, so the two titles line up.
            Button(radio.isScanning ? "Stop scanning" : scanTitle,
                   systemImage: radio.isScanning ? "stop.circle" : "magnifyingglass") {
                radio.isScanning ? radio.stopScan() : radio.startScan()
            }
        } header: {
            HStack {
                Text("Bluetooth")
                if radio.isScanning { ProgressView().controlSize(.small) }
            }
        } footer: {
            if pairing.isEnabled {
                Text("""
                    Add radio shows nearby MeshCore radios; pick yours to let m-Core use it. Scanning only finds radios \
                    you've already added. Radios with a PIN ask for it the first time.
                    """)
            } else {
                Text("Radios with a PIN show the system pairing prompt on first connect.")
            }
        }
    }

    private var scanTitle: String {
        pairing.isEnabled ? "Find added radios nearby" : "Scan for radios"
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
    var chemistry: BatteryChemistry = .lithiumIon

    var body: some View {
        Section("Device") {
            row("Model", info.device.model)
            row("Firmware", [info.device.firmwareVersion, info.device.buildDate].compactMap { $0 }.joined(separator: " · "))
            row("Protocol", "v\(info.device.protocolVersion)")
            if let contacts = info.device.maxContacts, let channels = info.device.maxChannels {
                row("Capacity", "\(contacts) contacts · \(channels) channels")
            }
            if let battery {
                row("Battery", chemistry.describe(millivolts: Int(battery.millivolts)))
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

/// One remembered radio: its name, how it connects and when it was last used.
private struct KnownRadioRow: View {
    let radio: KnownRadio
    let needsAdding: Bool

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(MCColor.accent)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: MCSpacing.xxs) {
                Text(radio.displayName).foregroundStyle(Color.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if needsAdding {
                Text("Add again").font(.caption).foregroundStyle(MCColor.warning)
            }
        }
    }

    private var icon: String {
        switch radio.target {
        case .bluetooth: "dot.radiowaves.left.and.right"
        case .tcp: "wifi"
        case .simulator: "cpu"
        }
    }

    private var subtitle: String {
        guard let last = radio.lastConnected else { return radio.transportDescription }
        return "\(radio.transportDescription) · \(last.formatted(.relative(presentation: .named)))"
    }
}
