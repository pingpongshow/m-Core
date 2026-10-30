import MeshCoreKit
import MeshDesign
import MeshServices
import SwiftUI
import UniformTypeIdentifiers

/// Settings of the connected companion radio.
struct RadioSettingsView: View {
    @Environment(RadioController.self) private var radio
    @Environment(RadioSettingsService.self) private var settings
    @Environment(PresetCatalog.self) private var presetCatalog
    @State private var name = ""
    @State private var draftRadio: RadioParameters?
    /// The preset the user picked, which several presets can share LoRa settings with (USA and Canada differ only in
    /// their recommended path hash size). Nil once the values are edited by hand or re-read from the radio, and the
    /// picker then names whichever preset those values match.
    @State private var presetID: String?
    @State private var txPower: Double = 20
    @State private var pinText = ""
    @State private var status: String?
    @State private var confirmRadioChange = false
    @State private var confirmReset = false
    @State private var showingBackup = false
    @State private var showingRestore = false
    @State private var showingWiFi = false

    var body: some View {
        List {
            if let selfInfo = radio.selfInfo {
                identitySection(selfInfo)
                loraSection(selfInfo)
                contactsSection
                telemetrySection(selfInfo)
                securitySection
                if settings.wifiStatus != nil { wifiSection }
                backupSection
                deviceSection
            } else {
                ContentUnavailableView(
                    "No radio",
                    systemImage: "antenna.radiowaves.left.and.right.slash",
                    description: Text("Connect a radio to change its settings.")
                )
            }
            if let status {
                Section { Text(status).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Radio Settings")
        .task {
            await settings.load()
            syncFromRadio(old: nil, new: radio.selfInfo)
        }
        .onChange(of: radio.selfInfo) { old, new in syncFromRadio(old: old, new: new) }
        .sheet(isPresented: $showingBackup) { ProfileBackupSheet() }
        .sheet(isPresented: $showingWiFi) { WiFiSetupSheet() }
        .fileImporter(isPresented: $showingRestore, allowedContentTypes: [.json]) { result in
            restore(result)
        }
    }

    /// Copies only the values the radio changed. SELF_INFO is re-read often (e.g. after every GPS Feed write),
    /// and resetting every field then would throw away a name or LoRa change the user is still typing.
    private func syncFromRadio(old: SelfInfo?, new: SelfInfo?) {
        guard let new else { return }
        let otherRadio = old?.publicKey != new.publicKey
        if otherRadio || old?.name != new.name { name = new.name }
        if otherRadio || old?.radio != new.radio {
            draftRadio = new.radio
            // A chosen preset survives the radio reporting back the settings it was just given; re-deriving it from
            // those settings would rename the user's choice to whichever preset shares them.
            if otherRadio || presetCatalog.allPresets.first(where: { $0.id == presetID })?.radio != new.radio {
                presetID = nil
            }
        }
        if otherRadio || old?.txPowerDbm != new.txPowerDbm { txPower = Double(new.txPowerDbm) }
    }
}

// MARK: Sections

extension RadioSettingsView {
    private func identitySection(_ selfInfo: SelfInfo) -> some View {
        Section("Identity") {
            // Labelled like the rows below it, so it reads as the radio's name and not a stray value.
            LabeledContent("Name") {
                HStack {
                    TextField("Name", text: $name)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                    if name != selfInfo.name {
                        Button("Save") { run("Name saved.") { try await settings.setName(name) } }
                            .buttonStyle(.borderless)
                    }
                }
            }
            LabeledContent("Public key") {
                Text(selfInfo.publicKey.prefix.hex.uppercased()).font(.body.monospaced())
            }
            .contextMenu {
                Button("Copy full key", systemImage: "doc.on.doc") { UIPasteboard.general.string = selfInfo.publicKey.hex }
            }
        }
    }

    /// The preset the picker shows: the one chosen here, else the one last applied to this radio while its settings
    /// still match, else whichever preset the draft values match. Presets can share LoRa settings, so a chosen one
    /// can't be recovered from the values alone.
    private var selectedPresetID: String {
        if let presetID, presetID == "custom" || presetCatalog.allPresets.contains(where: { $0.id == presetID }) {
            return presetID
        }
        if let applied = radio.appliedPresetID,
           let preset = presetCatalog.allPresets.first(where: { $0.id == applied }),
           preset.radio == draftRadio {
            return applied
        }
        return draftRadio.flatMap(presetCatalog.matching)?.id ?? "custom"
    }

    private var presetPicker: some View {
        Picker("Preset", selection: Binding(
            get: { selectedPresetID },
            set: { id in
                presetID = id
                guard let preset = presetCatalog.allPresets.first(where: { $0.id == id }) else {
                    // "Other": stop calling the radio's settings by a preset's name.
                    radio.setAppliedPresetID(nil)
                    return
                }
                draftRadio = preset.radio
                // The radio is already on these settings, so there's nothing to apply and no Apply button to
                // record the choice: name it now. Presets that share settings are only told apart by this.
                if preset.radio == radio.selfInfo?.radio { radio.setAppliedPresetID(id) }
            }
        )) {
            Text("Other").tag("custom")
            ForEach(presetCatalog.regions, id: \.self) { region in
                Section(region) {
                    ForEach(presetCatalog.official.filter { $0.region == region }) { Text($0.name).tag($0.id) }
                }
            }
            if !presetCatalog.presets.isEmpty {
                Section("My settings") {
                    ForEach(presetCatalog.presets) { Text($0.name).tag($0.id) }
                }
            }
        }
    }

    private var applyRadioButton: some View {
        Button("Apply LoRa settings") { confirmRadioChange = true }
            // On the button, so on iOS 26 the confirmation points at it rather than the top of the list.
            .confirmationDialog("Change LoRa settings?", isPresented: $confirmRadioChange, titleVisibility: .visible) {
                Button("Apply") { applyRadio() }
            } message: {
                Text("Your radio will only hear nodes using the same settings.")
            }
    }

    private func loraSection(_ selfInfo: SelfInfo) -> some View {
        Section {
            presetPicker
            if let draft = draftRadio {
                LabeledContent("Frequency") {
                    HStack(spacing: MCSpacing.xs) {
                        TextField("MHz", value: Binding(
                            get: { draft.frequencyMHz },
                            set: { mhz in editDraft { $0.frequencyKHz = UInt32((mhz * 1000).rounded()) } }
                        ), format: .number.precision(.fractionLength(3)))
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.decimalPad)
                        Text("MHz").foregroundStyle(.secondary)
                    }
                }
                Picker("Bandwidth", selection: Binding(
                    get: { draft.bandwidthHz },
                    set: { hz in editDraft { $0.bandwidthHz = hz } }
                )) {
                    ForEach([7_800, 10_400, 15_600, 20_800, 31_250, 41_700, 62_500, 125_000, 250_000, 500_000] as [UInt32], id: \.self) {
                        Text(String(format: "%g kHz", Double($0) / 1000)).tag($0)
                    }
                }
                Picker("Spreading factor", selection: Binding(
                    get: { draft.spreadingFactor },
                    set: { sf in editDraft { $0.spreadingFactor = sf } }
                )) {
                    ForEach(UInt8(5)...12, id: \.self) { Text("SF\($0)").tag($0) }
                }
                Picker("Coding rate", selection: Binding(
                    get: { draft.codingRate },
                    set: { cr in editDraft { $0.codingRate = cr } }
                )) {
                    ForEach(UInt8(5)...8, id: \.self) { Text("4/\($0)").tag($0) }
                }
                if draft != selfInfo.radio { applyRadioButton }
            }
            VStack(alignment: .leading) {
                LabeledContent("TX power", value: "\(Int(txPower)) dBm")
                Slider(value: $txPower, in: -9...Double(selfInfo.maxTxPowerDbm), step: 1) { editing in
                    if !editing { run("TX power set.") { try await settings.setTxPower(Int8(txPower)) } }
                }
                .accessibilityLabel("TX power")
                .accessibilityValue("\(Int(txPower)) dBm")
                // VoiceOver adjusts without a drag ending, so apply each step directly.
                .accessibilityAdjustableAction { direction in
                    let step: Double = direction == .increment ? 1 : (direction == .decrement ? -1 : 0)
                    let value = min(Double(selfInfo.maxTxPowerDbm), max(-9, txPower + step))
                    guard value != txPower else { return }
                    txPower = value
                    run("TX power set.") { try await settings.setTxPower(Int8(value)) }
                }
            }
        } header: {
            Text("LoRa")
        } footer: {
            if let draft = draftRadio, draft != selfInfo.radio {
                Text("These aren't on the radio yet — tap Apply LoRa settings to send them.")
                    .foregroundStyle(MCColor.warning)
            } else {
                Text("Use the same settings as your local mesh. Higher power reaches further but drains the battery faster.")
            }
        }
    }

    private var contactsSection: some View {
        Section {
            if let autoAdd = settings.autoAdd {
                Toggle("Add new repeaters", isOn: autoAddBinding(AutoAddConfig.repeater, autoAdd))
                Toggle("Add new companions", isOn: autoAddBinding(AutoAddConfig.chat, autoAdd))
                Toggle("Add new rooms", isOn: autoAddBinding(AutoAddConfig.room, autoAdd))
                Toggle("Add new sensors", isOn: autoAddBinding(AutoAddConfig.sensor, autoAdd))
                Toggle("Replace oldest when full", isOn: autoAddBinding(AutoAddConfig.overwriteOldest, autoAdd))
            }
            Toggle("Only add contacts manually", isOn: Binding(
                get: { (radio.selfInfo?.manualAddContacts ?? 0) & 1 != 0 },
                set: { manual in run(nil) { try await settings.updateOtherParams { $0.manualAddContacts = manual ? 1 : 0 } } }
            ))
        } header: {
            Text("Contacts")
        } footer: {
            Text("Which nodes the radio adds to its contact list when it hears their adverts.")
        }
    }

    private func autoAddBinding(_ flag: UInt8, _ config: AutoAddConfig) -> Binding<Bool> {
        Binding(
            get: { config.flags & flag != 0 },
            set: { enabled in
                var updated = config
                updated.flags = enabled ? config.flags | flag : config.flags & ~flag
                run(nil) { try await settings.setAutoAdd(updated) }
            }
        )
    }

    private func telemetrySection(_ selfInfo: SelfInfo) -> some View {
        Section {
            telemetryPicker("Battery & status", \.base, selfInfo)
            telemetryPicker("Location", \.location, selfInfo)
            telemetryPicker("Sensors", \.environment, selfInfo)
        } header: {
            Text("Telemetry sharing")
        } footer: {
            Text("Who can request this radio's telemetry. Favourites are contacts you've starred.")
        }
    }

    private func telemetryPicker(
        _ title: String, _ keyPath: WritableKeyPath<TelemetryModes, TelemetryMode>, _ selfInfo: SelfInfo
    ) -> some View {
        Picker(title, selection: Binding(
            get: { selfInfo.telemetryModes[keyPath: keyPath] },
            set: { mode in run(nil) { try await settings.updateOtherParams { $0.telemetryModes[keyPath: keyPath] = mode } } }
        )) {
            Text("Nobody").tag(TelemetryMode.deny)
            Text("Favourites").tag(TelemetryMode.allowFlagged)
            Text("Everyone").tag(TelemetryMode.allowAll)
        }
    }

    private var securitySection: some View {
        Section {
            HStack {
                SecureField("New 6-digit PIN", text: $pinText)
                    .keyboardType(.numberPad)
                Button("Set") {
                    guard let pin = UInt32(pinText) else { return }
                    run("PIN changed. Pair again after the radio restarts.") { try await settings.setPin(pin) }
                    pinText = ""
                }
                .disabled(UInt32(pinText).map { !(100_000...999_999).contains($0) } ?? true)
            }
            // Otherwise the separator lines up with the Set button's text, the row's only Text.
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            Button("Remove PIN") { run("PIN removed.") { try await settings.setPin(0) } }
        } header: {
            Text("Bluetooth PIN")
        } footer: {
            Text("Changing the PIN means re-pairing in iOS Settings → Bluetooth.")
        }
    }

    private var wifiSection: some View {
        Section("Wi‑Fi") {
            LabeledContent("Status", value: settings.wifiStatus ?? "")
            Button("Set up Wi‑Fi") { showingWiFi = true }
        }
    }

    private var backupSection: some View {
        Section {
            Button("Back up settings", systemImage: "square.and.arrow.up") { showingBackup = true }
            Button("Restore settings", systemImage: "square.and.arrow.down") { showingRestore = true }
        } header: {
            Text("Backup")
        } footer: {
            Text("Saves name, LoRa settings, channels and options to a file you can apply to this or another radio.")
        }
    }

    private var deviceSection: some View {
        Section("Device") {
            if let battery = radio.battery {
                LabeledContent("Battery", value: radio.batteryChemistry.describe(millivolts: Int(battery.millivolts)))
                LabeledContent("Storage", value: "\(battery.usedKB) of \(battery.totalKB) KB used")
            }
            Picker("Battery type", selection: Binding(
                get: { radio.batteryChemistry },
                set: { radio.setBatteryChemistry($0) }
            )) {
                ForEach(BatteryChemistry.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Button("Reboot radio", systemImage: "arrow.clockwise") { run("Rebooting…") { try await settings.reboot() } }
            Button("Power off radio", systemImage: "power") { run("Powering off…") { try await settings.powerOff() } }
            Button("Factory reset", systemImage: "exclamationmark.triangle", role: .destructive) { confirmReset = true }
                .foregroundStyle(MCColor.critical)
                .confirmationDialog("Factory reset the radio?", isPresented: $confirmReset, titleVisibility: .visible) {
                    Button("Erase everything", role: .destructive) {
                        run("Radio is resetting.") { try await settings.factoryReset() }
                    }
                } message: {
                    Text("This erases contacts, channels, settings and the radio's identity. It can't be undone.")
                }
        }
    }
}

// MARK: Actions

extension RadioSettingsView {
    /// Edits one LoRa value by hand, which drops any chosen preset: the picker goes back to naming whatever
    /// the values now match, or "Other".
    private func editDraft(_ change: (inout RadioParameters) -> Void) {
        guard var draft = draftRadio else { return }
        change(&draft)
        draftRadio = draft
        presetID = nil
    }

    private func applyRadio() {
        guard let draftRadio else { return }
        // Remembered against the radio, since the settings it reports back can't say which preset they came from.
        let chosen = selectedPresetID
        run("LoRa settings applied.") {
            try await settings.setRadio(draftRadio)
            radio.setAppliedPresetID(chosen == "custom" ? nil : chosen)
        }
    }

    private func restore(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        run("Settings restored.") {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let profile = try JSONDecoder().decode(DeviceProfile.self, from: Data(contentsOf: url))
            try await settings.importProfile(profile, includePrivateKey: false)
        }
    }

    private func run(_ success: String?, _ work: @escaping () async throws -> Void) {
        Task {
            do {
                try await work()
                status = success
            } catch {
                status = "Failed: \(errorMessage(error))"
            }
        }
    }
}

/// Exports the radio's settings as a JSON file.
struct ProfileBackupSheet: View {
    @Environment(RadioSettingsService.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var includeKey = false
    @State private var fileURL: URL?
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Toggle("Include private key", isOn: $includeKey)
                    .onChange(of: includeKey) { fileURL = nil }
                Text(includeKey
                     ? "Anyone with this file can impersonate your radio. Store it somewhere safe."
                     : "Without the key, restoring keeps the target radio's own identity.")
                    .font(.footnote)
                    .foregroundStyle(includeKey ? MCColor.warning : .secondary)
                if let fileURL {
                    ShareLink(item: fileURL) { Label("Share backup file", systemImage: "square.and.arrow.up") }
                } else {
                    Button("Create backup") { create() }
                }
                if let errorText { Text(errorText).foregroundStyle(MCColor.critical) }
            }
            .navigationTitle("Back Up Settings")
            .onDisappear {
                if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
            }
            .toolbarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }

    private func create() {
        Task {
            do {
                let profile = try await settings.exportProfile(includePrivateKey: includeKey)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                // A "/" or ":" in the radio's name would otherwise point the path at a folder that doesn't exist.
                let safeName = profile.name.replacingOccurrences(of: "[/:\\\\]", with: "-", options: .regularExpression)
                let url = FileManager.default.temporaryDirectory.appending(path: "\(safeName)-m-Core.json")
                // The file can hold the private key: keep it encrypted at rest and delete it when the sheet closes.
                try encoder.encode(profile).write(to: url, options: [.atomic, .completeFileProtection])
                fileURL = url
            } catch RadioSettingsError.disabledByFirmware {
                errorText = "This radio's firmware doesn't allow exporting its key."
            } catch {
                errorText = "Couldn't create the backup: \(errorMessage(error))"
            }
        }
    }
}
