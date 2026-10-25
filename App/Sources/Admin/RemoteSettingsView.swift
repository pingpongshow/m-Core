import CoreLocation
import MeshDesign
import MeshServices
import SwiftUI

/// Forms for a repeater's or room server's settings (admin login required). Each change is sent as the matching remote
/// CLI command (see `RemoteSetting`) and current values are read with `get …` when the screen opens.
struct RemoteSettingsView: View {
    let keyHex: String
    let title: String
    @Environment(RemoteNodeService.self) private var remote
    @Environment(LocationTracker.self) private var location
    @State private var loaded = RemoteNodeSettings()
    @State private var isLoading = false
    @State private var busy: String?
    @State private var message: String?
    @State private var messageIsError = false

    @State private var name = ""
    @State private var frequency = ""
    @State private var bandwidth = 62.5
    @State private var spreadingFactor = 8
    @State private var codingRate = 5
    @State private var txPower = 20
    @State private var advertInterval = 0
    @State private var floodAdvertInterval = 47
    @State private var floodMax = 64
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var guestPassword = ""
    @State private var adminPassword = ""
    @State private var confirmRadio = false
    @State private var confirmReboot = false
    @State private var confirmAdminPassword = false

    private static let bandwidths = [7.8, 10.4, 15.6, 20.8, 31.25, 41.7, 62.5, 125, 250, 500]
    private static let advertIntervals = [0, 60, 90, 120, 180, 240]
    private static let floodAdvertIntervals = [0, 3, 6, 12, 24, 47, 72, 168]

    var body: some View {
        Form {
            statusSection
            identitySection
            radioSection
            advertSection
            locationSection
            passwordSection
            actionsSection
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(busy != nil)
        .task { await load() }
        .refreshable { await load() }
    }

    // MARK: Sections

    private var statusSection: some View {
        Section {
            if isLoading {
                HStack {
                    ProgressView()
                    Text("Reading settings from \(title)…").foregroundStyle(.secondary)
                }
            }
            if let busy {
                HStack {
                    ProgressView()
                    Text(busy).foregroundStyle(.secondary)
                }
            }
            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(messageIsError ? MCColor.warning : Color.secondary)
            }
        } footer: {
            Text("Each change is sent over the mesh and confirmed by \(title). Values it didn't report are left as shown.")
        }
    }

    private var identitySection: some View {
        Section("Name") {
            TextField("Name", text: $name)
                .autocorrectionDisabled()
            saveButton(enabled: !name.isEmpty && name != loaded.name) {
                send(.name(name)) { loaded.name = name }
            }
        }
    }

    private var radioSection: some View {
        Section {
            LabeledContent("Frequency (MHz)") {
                TextField("869.618", text: $frequency)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            }
            Picker("Bandwidth", selection: $bandwidth) {
                ForEach(Self.bandwidths, id: \.self) { Text("\($0.formatted()) kHz").tag($0) }
            }
            Stepper("Spreading factor SF\(spreadingFactor)", value: $spreadingFactor, in: 5...12)
            Stepper("Coding rate 4/\(codingRate)", value: $codingRate, in: 5...8)
            Button("Apply radio settings") { confirmRadio = true }
                .disabled(draftRadio == nil || draftRadio == loaded.radio)
                .confirmationDialog("Change LoRa settings?", isPresented: $confirmRadio, titleVisibility: .visible) {
                    Button("Apply") { applyRadio() }
                } message: {
                    Text("\(title) uses them after a reboot. If they don't match your radio, you'll lose contact with it.")
                }
            Stepper("TX power \(txPower) dBm", value: $txPower, in: 1...22)
            saveButton(title: "Save TX power", enabled: txPower != loaded.txPowerDbm) {
                send(.txPower(txPower)) { loaded.txPowerDbm = txPower }
            }
            Toggle("Repeat packets", isOn: Binding(
                get: { loaded.repeatEnabled ?? true },
                set: { on in send(.repeatEnabled(on)) { loaded.repeatEnabled = on } }
            ))
            .disabled(loaded.repeatEnabled == nil)
        } header: {
            Text("Radio")
        } footer: {
            Text("""
                LoRa settings take effect after a reboot. TX power is at the LoRa chip; boards with an amplifier add to it. \
                Turning off repeat stops this node forwarding other nodes' packets.
                """)
        }
    }

    private var advertSection: some View {
        Section {
            Picker("Zero-hop advert", selection: $advertInterval) {
                ForEach(Self.advertIntervals, id: \.self) { minutes in
                    Text(minutes == 0 ? "Off" : "Every \(minutes) min").tag(minutes)
                }
            }
            Picker("Flood advert", selection: $floodAdvertInterval) {
                ForEach(Self.floodAdvertIntervals, id: \.self) { hours in
                    Text(hours == 0 ? "Off" : "Every \(hours) h").tag(hours)
                }
            }
            Stepper("Flood max \(floodMax) hops", value: $floodMax, in: 0...64)
            saveButton(enabled: advertInterval != loaded.advertIntervalMinutes
                || floodAdvertInterval != loaded.floodAdvertIntervalHours || floodMax != loaded.floodMaxHops) {
                saveAdverts()
            }
        } header: {
            Text("Adverts and flooding")
        } footer: {
            Text("Flood max limits how many hops flooded packets travel through this node (0–64).")
        }
    }

    private var locationSection: some View {
        Section("Location") {
            LabeledContent("Latitude") {
                TextField("0.0", text: $latitude)
                    .keyboardType(.numbersAndPunctuation)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Longitude") {
                TextField("0.0", text: $longitude)
                    .keyboardType(.numbersAndPunctuation)
                    .multilineTextAlignment(.trailing)
            }
            Button("Use my phone's location", systemImage: "location") {
                if let current = location.current?.coordinate {
                    latitude = RemoteSettingsView.format(current.latitude)
                    longitude = RemoteSettingsView.format(current.longitude)
                } else {
                    show("Waiting for your location. Try again in a moment.", isError: true)
                }
            }
            saveButton(enabled: Double(latitude) != nil && Double(longitude) != nil
                && (Double(latitude) != loaded.latitude || Double(longitude) != loaded.longitude)) {
                saveLocation()
            }
        }
        .onAppear { location.start() }
        .onDisappear { location.stop() }
    }

    private var passwordSection: some View {
        Section {
            SecureField("Guest password", text: $guestPassword)
            saveButton(title: "Save guest password", enabled: guestPassword != (loaded.guestPassword ?? "")) {
                send(.guestPassword(guestPassword)) { loaded.guestPassword = guestPassword }
            }
            SecureField("New admin password", text: $adminPassword)
            Button("Change admin password") { confirmAdminPassword = true }
                .disabled(adminPassword.isEmpty)
                .confirmationDialog("Change the admin password?", isPresented: $confirmAdminPassword, titleVisibility: .visible) {
                    Button("Change password", role: .destructive) {
                        send(.adminPassword(adminPassword)) { adminPassword = "" }
                    }
                } message: {
                    Text("You'll need the new password to log in as admin next time.")
                }
        } header: {
            Text("Passwords")
        } footer: {
            Text("Up to 15 characters. An empty guest password lets anyone log in as a guest.")
        }
    }

    private var actionsSection: some View {
        Section("Actions") {
            Button("Send flood advert", systemImage: "dot.radiowaves.right") { send(.sendAdvert) }
            Button("Send zero-hop advert", systemImage: "dot.radiowaves.forward") { send(.sendZeroHopAdvert) }
            Button("Reboot", systemImage: "arrow.clockwise", role: .destructive) { confirmReboot = true }
                .foregroundStyle(MCColor.critical)
                .confirmationDialog("Reboot \(title)?", isPresented: $confirmReboot, titleVisibility: .visible) {
                    Button("Reboot", role: .destructive) { send(.reboot, success: "Rebooting. It'll be back in a few seconds.") }
                }
        }
    }

    private func saveButton(title: String = "Save", enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action).disabled(!enabled)
    }
}

// MARK: Actions

extension RemoteSettingsView {
    private var draftRadio: RemoteRadioParameters? {
        guard let mhz = Double(frequency.replacingOccurrences(of: ",", with: ".")) else { return nil }
        let radio = RemoteRadioParameters(
            frequencyMHz: mhz, bandwidthKHz: bandwidth, spreadingFactor: spreadingFactor, codingRate: codingRate
        )
        return radio.isValid ? radio : nil
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let settings = try await remote.readSettings(keyHex: keyHex) { partial in fill(from: partial) }
            fill(from: settings)
            if settings == RemoteNodeSettings() {
                show("\(title) didn't answer. It may be out of range, or the admin login has expired.", isError: true)
            }
        } catch {
            show("Couldn't read settings: \(errorMessage(error))", isError: true)
        }
    }

    /// Copies newly reported values into the form without overwriting fields the user is already editing.
    private func fill(from settings: RemoteNodeSettings) {
        let previous = loaded
        loaded = settings
        if let value = settings.name, name.isEmpty || name == previous.name { name = value }
        if let radio = settings.radio, radio != previous.radio {
            frequency = Self.format(radio.frequencyMHz, places: 3)
            bandwidth = Self.bandwidths.min { abs($0 - radio.bandwidthKHz) < abs($1 - radio.bandwidthKHz) } ?? radio.bandwidthKHz
            spreadingFactor = radio.spreadingFactor
            codingRate = radio.codingRate
        }
        if let value = settings.txPowerDbm, value != previous.txPowerDbm { txPower = value }
        if let value = settings.advertIntervalMinutes, value != previous.advertIntervalMinutes {
            advertInterval = Self.advertIntervals.min { abs($0 - value) < abs($1 - value) } ?? 0
        }
        if let value = settings.floodAdvertIntervalHours, value != previous.floodAdvertIntervalHours {
            floodAdvertInterval = Self.floodAdvertIntervals.min { abs($0 - value) < abs($1 - value) } ?? 47
        }
        if let value = settings.floodMaxHops, value != previous.floodMaxHops { floodMax = value }
        if let value = settings.latitude, value != previous.latitude { latitude = Self.format(value) }
        if let value = settings.longitude, value != previous.longitude { longitude = Self.format(value) }
        if let value = settings.guestPassword, value != previous.guestPassword { guestPassword = value }
    }

    private func applyRadio() {
        guard let radio = draftRadio else { return }
        send(.radio(radio), success: "Saved. Reboot \(title) to use the new LoRa settings.") { loaded.radio = radio }
    }

    private func saveAdverts() {
        Task {
            if advertInterval != loaded.advertIntervalMinutes,
               await perform(.advertInterval(minutes: advertInterval)) { loaded.advertIntervalMinutes = advertInterval }
            if floodAdvertInterval != loaded.floodAdvertIntervalHours,
               await perform(.floodAdvertInterval(hours: floodAdvertInterval)) { loaded.floodAdvertIntervalHours = floodAdvertInterval }
            if floodMax != loaded.floodMaxHops, await perform(.floodMaxHops(floodMax)) { loaded.floodMaxHops = floodMax }
        }
    }

    private func saveLocation() {
        guard let lat = Double(latitude), let lon = Double(longitude) else { return }
        Task {
            if lat != loaded.latitude, await perform(.latitude(lat)) { loaded.latitude = lat }
            if lon != loaded.longitude, await perform(.longitude(lon)) { loaded.longitude = lon }
        }
    }

    private func send(_ setting: RemoteSetting, success: String? = nil, onSuccess: @escaping () -> Void = {}) {
        Task {
            if await perform(setting, success: success) { onSuccess() }
        }
    }

    /// Sends one command and reports the node's reply; true when it accepted it.
    private func perform(_ setting: RemoteSetting, success: String? = nil) async -> Bool {
        busy = "Sending to \(title)…"
        defer { busy = nil }
        do {
            let reply = try await remote.apply(setting, keyHex: keyHex)
            show(success ?? "\(title): \(reply)", isError: false)
            return true
        } catch RemoteRequestError.timedOut {
            show("\(title) didn't confirm. It may be out of range; check before trying again.", isError: true)
        } catch {
            show(errorMessage(error), isError: true)
        }
        return false
    }

    private func show(_ text: String, isError: Bool) {
        message = text
        messageIsError = isError
    }

    static func format(_ value: Double, places: Int = 6) -> String {
        var text = String(format: "%.\(places)f", value)
        while text.contains(".") && text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}
