import Foundation
import MeshCoreKit
import MeshStore
import Testing
@testable import MeshServices

@MainActor
struct RadioSettingsTests {
    struct Connection {
        let mock: MockRadio
        let radio: RadioController
        let messaging: MessagingService
        let settings: RadioSettingsService
    }

    private func connect(_ state: MockRadio.State = MockRadio.demoState) async throws -> Connection {
        let mock = MockRadio(state: state)
        let radio = RadioController(defaults: UserDefaults(suiteName: "settings.\(UUID().uuidString)")!, simulatedRadio: mock)
        let messaging = MessagingService(
            radio: radio, defaults: UserDefaults(suiteName: "settings.\(UUID().uuidString)")!,
            storeFactory: { try RadioStore(radioKeyHex: $0, inMemory: true) }
        )
        let settings = RadioSettingsService(radio: radio, messaging: messaging)
        await radio.connect(to: .simulator)
        try await waitUntil { messaging.store != nil && !messaging.isSyncing && messaging.revision > 0 }
        return Connection(mock: mock, radio: radio, messaging: messaging, settings: settings)
    }

    @Test func presetsMatchKnownValues() {
        let us = RadioPreset.all.first { $0.id == "us" }
        #expect(us?.radio == RadioParameters(frequencyKHz: 910_525, bandwidthHz: 62_500, spreadingFactor: 7, codingRate: 5))
        #expect(RadioPreset.matching(MockRadio.sampleState.selfInfo.radio)?.id == "us")
        #expect(Set(RadioPreset.all.map(\.id)).count == RadioPreset.all.count)
    }

    @Test func loadsAndChangesSettings() async throws {
        let connection = try await connect()
        let mock = connection.mock
        let radio = connection.radio
        let settings = connection.settings
        await settings.load()
        #expect(settings.tuning == TuningParams(rxDelayBase: 0, airtimeFactor: 1))
        #expect(settings.autoAdd?.flags == 0x1E)
        #expect(settings.repeatRanges.count == 3)
        #expect(settings.wifiStatus == nil)

        try await settings.setName("Trail Radio")
        #expect(radio.selfInfo?.name == "Trail Radio")

        let eu = try #require(RadioPreset.all.first { $0.id == "eu-narrow" })
        try await settings.setRadio(eu.radio)
        #expect(radio.selfInfo?.radio == eu.radio)

        try await settings.setTxPower(10)
        #expect(mock.current.selfInfo.txPowerDbm == 10)
        await #expect(throws: MeshError.self) { try await settings.setTxPower(30) }

        try await settings.setTuning(TuningParams(rxDelayBase: 0.5, airtimeFactor: 2))
        #expect(mock.current.tuning == TuningParams(rxDelayBase: 0.5, airtimeFactor: 2))

        try await settings.updateOtherParams { $0.telemetryModes.environment = .allowAll; $0.multiAcks = 1 }
        #expect(mock.current.selfInfo.telemetryModes.environment == .allowAll)
        #expect(mock.current.selfInfo.multiAcks == 1)

        try await settings.setAutoAdd(AutoAddConfig(flags: AutoAddConfig.repeater, maxHops: 3))
        #expect(mock.current.autoAdd == AutoAddConfig(flags: AutoAddConfig.repeater, maxHops: 3))
        await radio.disconnect()
    }

    @Test func pinValidation() async throws {
        let connection = try await connect()
        let mock = connection.mock
        let radio = connection.radio
        let settings = connection.settings
        await #expect(throws: RadioSettingsError.invalidPin) { try await settings.setPin(1234) }
        try await settings.setPin(654_321)
        #expect(mock.current.blePin == 654_321)
        try await settings.setPin(0)
        #expect(mock.current.blePin == 0)
        await radio.disconnect()
    }

    @Test func privateKeyAndDisabledFirmware() async throws {
        let connection = try await connect()
        let mock = connection.mock
        let radio = connection.radio
        let settings = connection.settings
        #expect(try await settings.exportPrivateKey().count == 64)
        mock.update { $0.privateKeyExportEnabled = false }
        await #expect(throws: RadioSettingsError.disabledByFirmware) { _ = try await settings.exportPrivateKey() }
        await radio.disconnect()
    }

    @Test func profileRoundTrip() async throws {
        let connection = try await connect()
        let mock = connection.mock
        let radio = connection.radio
        let settings = connection.settings
        let profile = try await settings.exportProfile(includePrivateKey: true)
        #expect(profile.name == "Sim")
        #expect(profile.channels.map(\.name) == ["Public", "#test", "Bay Area"])
        #expect(profile.privateKeyHex?.count == 128)
        let json = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(DeviceProfile.self, from: json)
        #expect(decoded == profile)

        // Apply it to a blank radio.
        let blankConnection = try await connect(MockRadio.sampleState)
        let blank = blankConnection.mock
        let blankRadio = blankConnection.radio
        let blankMessaging = blankConnection.messaging
        let blankSettings = blankConnection.settings
        try await blankSettings.importProfile(decoded, includePrivateKey: true)
        #expect(blank.current.selfInfo.name == "Sim")
        #expect(blank.current.channels.map(\.name) == ["Public", "#test", "Bay Area"])
        #expect(blank.current.privateKey == mock.current.privateKey)
        #expect(blankMessaging.store?.channels().count == 3)
        await radio.disconnect()
        await blankRadio.disconnect()
    }

    @Test func rebootAndWiFi() async throws {
        let connection = try await connect()
        let mock = connection.mock
        let radio = connection.radio
        let settings = connection.settings
        try await settings.setWiFi(ssid: "Home", password: "secret", enabled: true)
        #expect(mock.current.cliCommands.suffix(3) == ["set wifi.ssid Home", "set wifi.pwd secret", "set wifi.enabled on"])
        try await settings.reboot()
        try await waitUntil { mock.current.reboots == 1 }
        await radio.disconnect()
    }
}

@MainActor
struct CustomPresetTests {
    @Test func savesValidatesEditsAndPersists() throws {
        let defaults = UserDefaults(suiteName: "presets.\(UUID().uuidString)")!
        let store = PresetCatalog(defaults: defaults)
        let preset = try store.save(name: " Local mesh ", frequencyMHz: 906.875, bandwidthKHz: 250, spreadingFactor: 11, codingRate: 5)
        #expect(preset.name == "Local mesh")
        #expect(preset.isCustom)
        #expect(preset.radio == RadioParameters(frequencyKHz: 906_875, bandwidthHz: 250_000, spreadingFactor: 11, codingRate: 5))
        #expect(store.allPresets.count == RadioPreset.all.count + 1)

        #expect(throws: CustomPresetError.frequencyOutOfRange) {
            try store.save(name: "Bad", frequencyMHz: 2400, bandwidthKHz: 125, spreadingFactor: 7, codingRate: 5)
        }
        #expect(throws: CustomPresetError.unsupportedBandwidth) {
            try store.save(name: "Bad", frequencyMHz: 915, bandwidthKHz: 100, spreadingFactor: 7, codingRate: 5)
        }
        #expect(throws: CustomPresetError.emptyName) {
            try store.save(name: "  ", frequencyMHz: 915, bandwidthKHz: 125, spreadingFactor: 7, codingRate: 5)
        }

        try store.save(id: preset.id, name: "Local mesh", frequencyMHz: 906.875, bandwidthKHz: 62.5, spreadingFactor: 7, codingRate: 5)
        let reloaded = PresetCatalog(defaults: defaults)
        #expect(reloaded.presets.count == 1)
        #expect(reloaded.presets[0].radio.bandwidthHz == 62_500)
        #expect(reloaded.matching(reloaded.presets[0].radio)?.id == preset.id)

        reloaded.delete(id: preset.id)
        #expect(PresetCatalog(defaults: defaults).presets.isEmpty)
    }

    @Test func regionsKeepListOrder() {
        #expect(RadioPreset.regions.first == "North America")
        #expect(Set(RadioPreset.regions).count == RadioPreset.regions.count)
    }
}

@MainActor
struct OfficialPresetTests {
    nonisolated static let sample = Data("""
    {"config":{"suggested_radio_settings":{"entries":[
      {"title":"Australia","description":"","frequency":"915.800","spreading_factor":"10","bandwidth":"250","coding_rate":"5"},
      {"title":"USA","description":"","frequency":"910.525","spreading_factor":"7","bandwidth":"62.5","coding_rate":"5"},
      {"title":"Atlantis","description":"","frequency":"906.000","spreading_factor":"9","bandwidth":"125","coding_rate":"6",
       "network_settings":{"path_hash_size":2}},
      {"title":"Broken","description":"","frequency":"n/a","spreading_factor":"7","bandwidth":"62.5","coding_rate":"5"}
    ]}}}
    """.utf8)

    @Test func parsesGroupsAndReusesBundledIDs() throws {
        let presets = try PresetCatalog.parseOfficial(Self.sample)
        #expect(presets.map(\.name) == ["USA", "Australia", "Atlantis"])
        #expect(presets[0].id == "us")
        #expect(presets[0].region == "North America")
        #expect(presets[1].radio == RadioParameters(frequencyKHz: 915_800, bandwidthHz: 250_000, spreadingFactor: 10, codingRate: 5))
        #expect(presets[2].region == "Other")
        #expect(presets[2].pathHashSize == 2)
    }

    @Test func refreshReplacesCachesAndThrottles() async throws {
        let defaults = UserDefaults(suiteName: "official.\(UUID().uuidString)")!
        let http = FakeHTTP { _ in (200, OfficialPresetTests.sample) }
        let catalog = PresetCatalog(defaults: defaults, fetch: http.fetch)
        #expect(catalog.official == RadioPreset.all)
        await catalog.refreshOfficial()
        #expect(catalog.official.count == 3)
        #expect(catalog.regions == ["North America", "Oceania", "Other"])
        await catalog.refreshOfficial()
        #expect(http.sent.count == 1)

        let reopened = PresetCatalog(defaults: defaults, fetch: http.fetch)
        #expect(reopened.official.count == 3)
    }

    @Test func failedRefreshKeepsBundledList() async {
        let catalog = PresetCatalog(defaults: UserDefaults(suiteName: "official.\(UUID().uuidString)")!,
                                    fetch: FakeHTTP { _ in (500, Data()) }.fetch)
        await catalog.refreshOfficial()
        #expect(catalog.official == RadioPreset.all)
    }

    @Test func bundledListIsGroupedWithUniqueIDs() {
        #expect(RadioPreset.all.count == 26)
        #expect(Set(RadioPreset.all.map(\.id)).count == 26)
        #expect(RadioPreset.regions == ["North America", "Central & South America", "Europe", "Oceania", "Asia"])
        #expect(RadioPreset.all.allSatisfy { RadioPreset.region(forTitle: $0.name) == $0.region })
    }
}
