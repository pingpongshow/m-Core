import Foundation
import MeshCoreKit
import Observation

/// A named LoRa configuration used by a region or community mesh.
public struct RadioPreset: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let region: String
    public let radio: RadioParameters
    /// Path hash size (bytes) the mesh recommends, when it publishes one.
    public let pathHashSize: UInt8?

    public init(id: String, name: String, region: String, radio: RadioParameters, pathHashSize: UInt8? = nil) {
        self.id = id
        self.name = name
        self.region = region
        self.radio = radio
        self.pathHashSize = pathHashSize
    }

    init(_ id: String, _ name: String, _ region: String, mhz: Double, khz: Double, sf: UInt8, cr: UInt8, hash: UInt8? = nil) {
        self.init(id: id, name: name, region: region, radio: RadioParameters(
            frequencyKHz: UInt32((mhz * 1000).rounded()), bandwidthHz: UInt32((khz * 1000).rounded()),
            spreadingFactor: sf, codingRate: cr
        ), pathHashSize: hash)
    }

    /// MeshCore's suggested regional settings (api.meshcore.nz), bundled for offline use. ``PresetCatalog``
    /// refreshes them from the API. Check with your local mesh before changing.
    public static let all: [RadioPreset] = [
        RadioPreset("us", "USA", "North America", mhz: 910.525, khz: 62.5, sf: 7, cr: 5),
        RadioPreset("us-socal", "USA - Southern California", "North America", mhz: 927.875, khz: 62.5, sf: 7, cr: 5, hash: 3),
        RadioPreset("ca", "Canada", "North America", mhz: 910.525, khz: 62.5, sf: 7, cr: 5, hash: 3),
        RadioPreset("cr", "Costa Rica", "Central & South America", mhz: 910.525, khz: 125, sf: 11, cr: 5),
        RadioPreset("br", "Brazil", "Central & South America", mhz: 923.125, khz: 62.5, sf: 8, cr: 8),
        RadioPreset("eu-narrow", "EU/UK (Narrow)", "Europe", mhz: 869.618, khz: 62.5, sf: 8, cr: 8),
        RadioPreset("eu-lr", "EU/UK (Deprecated)", "Europe", mhz: 869.525, khz: 250, sf: 11, cr: 5),
        RadioPreset("eu-433-lr", "EU 433MHz (Long Range)", "Europe", mhz: 433.65, khz: 250, sf: 11, cr: 5),
        RadioPreset("eu-433", "EU 433MHz (Narrow)", "Europe", mhz: 433.65, khz: 62.5, sf: 8, cr: 8),
        RadioPreset("cz", "Czech Republic (Narrow)", "Europe", mhz: 869.432, khz: 62.5, sf: 7, cr: 5, hash: 2),
        RadioPreset("hu", "Hungary", "Europe", mhz: 869.618, khz: 62.5, sf: 7, cr: 5, hash: 2),
        RadioPreset("nl", "Netherlands", "Europe", mhz: 869.618, khz: 62.5, sf: 7, cr: 5),
        RadioPreset("nl-limburg", "Netherlands (Limburg)", "Europe", mhz: 869.618, khz: 62.5, sf: 8, cr: 8, hash: 2),
        RadioPreset("pt-433", "Portugal 433", "Europe", mhz: 433.375, khz: 62.5, sf: 9, cr: 6),
        RadioPreset("pt-868", "Portugal 868", "Europe", mhz: 869.618, khz: 62.5, sf: 7, cr: 6),
        RadioPreset("sk", "Slovakia", "Europe", mhz: 869.618, khz: 62.5, sf: 7, cr: 5, hash: 2),
        RadioPreset("ch", "Switzerland", "Europe", mhz: 869.618, khz: 62.5, sf: 8, cr: 8),
        RadioPreset("au", "Australia", "Oceania", mhz: 915.8, khz: 250, sf: 10, cr: 5),
        RadioPreset("au-narrow", "Australia (Narrow)", "Oceania", mhz: 916.575, khz: 62.5, sf: 7, cr: 7),
        RadioPreset("au-mid", "Australia (Mid)", "Oceania", mhz: 915.075, khz: 125, sf: 9, cr: 5),
        RadioPreset("au-sa-wa", "Australia: SA, WA", "Oceania", mhz: 923.125, khz: 62.5, sf: 8, cr: 8),
        RadioPreset("au-qld", "Australia: QLD", "Oceania", mhz: 923.125, khz: 62.5, sf: 8, cr: 5),
        RadioPreset("nz-narrow", "New Zealand (Narrow)", "Oceania", mhz: 917.375, khz: 62.5, sf: 7, cr: 5, hash: 2),
        RadioPreset("nz-gisborne", "New Zealand (Gisborne)", "Oceania", mhz: 917.375, khz: 250, sf: 11, cr: 5, hash: 1),
        RadioPreset("vn", "Vietnam (Narrow)", "Asia", mhz: 920.25, khz: 62.5, sf: 8, cr: 5),
        RadioPreset("vn-lr", "Vietnam (Deprecated)", "Asia", mhz: 920.25, khz: 250, sf: 11, cr: 5),
    ]

    public static func matching(_ radio: RadioParameters) -> RadioPreset? {
        all.first { $0.radio == radio }
    }

    /// Regions in the order presets are listed.
    public static var regions: [String] { regions(of: all) }

    public static func regions(of presets: [RadioPreset]) -> [String] {
        presets.reduce(into: []) { regions, preset in
            if !regions.contains(preset.region) { regions.append(preset.region) }
        }
    }

    /// Best-guess region for a preset title from the API, which doesn't group them.
    public static func region(forTitle title: String) -> String {
        let lowered = title.lowercased()
        let table: [(String, [String])] = [
            ("North America", ["usa", "canada", "mexico"]),
            ("Central & South America", ["costa rica", "brazil", "chile", "argentina", "colombia", "peru"]),
            ("Oceania", ["australia", "new zealand"]),
            ("Asia", ["vietnam", "japan", "korea", "taiwan", "india", "philippines", "thailand", "malaysia", "singapore"]),
            ("Europe", ["eu", "uk", "czech", "hungary", "netherlands", "portugal", "slovakia", "switzerland", "germany",
                        "poland", "france", "italy", "spain", "austria", "belgium", "sweden", "norway", "finland", "denmark"]),
        ]
        for (region, words) in table where words.contains(where: { lowered.hasPrefix($0) }) {
            return region
        }
        return "Other"
    }

    public static let customRegion = "Custom"
    public var isCustom: Bool { region == Self.customRegion }
}

/// Everything needed to set up another radio the same way (or restore this one), as JSON.
public struct DeviceProfile: Codable, Equatable, Sendable {
    public struct Channel: Codable, Equatable, Sendable {
        public var index: Int
        public var name: String
        public var secretHex: String
    }

    public var version = 1
    public var name: String
    public var frequencyKHz: UInt32
    public var bandwidthHz: UInt32
    public var spreadingFactor: UInt8
    public var codingRate: UInt8
    public var txPowerDbm: Int8
    public var telemetryModes: UInt8
    public var advertLocationPolicy: UInt8
    public var manualAddContacts: UInt8
    public var multiAcks: UInt8
    public var autoAddFlags: UInt8?
    public var autoAddMaxHops: UInt8?
    public var rxDelayBase: Double?
    public var airtimeFactor: Double?
    public var channels: [Channel]
    /// Included only when the user chooses; restores the radio's identity.
    public var privateKeyHex: String?
}

public enum RadioSettingsError: Error, Equatable, Sendable {
    case notConnected
    case invalidPin
    case disabledByFirmware
}

/// Settings of the connected companion radio.
@MainActor
@Observable
public final class RadioSettingsService {
    public private(set) var tuning: TuningParams?
    public private(set) var autoAdd: AutoAddConfig?
    public private(set) var repeatRanges: [FrequencyRange] = []
    public private(set) var wifiStatus: String?
    public private(set) var lastError: String?

    @ObservationIgnored private let radio: RadioController
    @ObservationIgnored private let messaging: MessagingService

    public init(radio: RadioController, messaging: MessagingService) {
        self.radio = radio
        self.messaging = messaging
    }

    private func session() async throws -> MeshSession {
        guard let session = await radio.session() else { throw RadioSettingsError.notConnected }
        return session
    }

    /// Reads settings that aren't part of `SelfInfo`.
    public func load() async {
        guard let session = try? await session() else { return }
        tuning = try? await session.request(.getTuningParams) { if case .tuningParams(let value) = $0 { value } else { nil } }
        autoAdd = try? await session.request(.getAutoAddConfig) { if case .autoAddConfig(let value) = $0 { value } else { nil } }
        repeatRanges = (try? await session.request(.getAllowedRepeatFrequencies) {
            if case .allowedRepeatFrequencies(let value) = $0 { value } else { nil }
        }) ?? []
        if let status = try? await session.runCLICommand("get wifi.status"), !status.lowercased().contains("unknown") {
            wifiStatus = status
        }
    }

    private func apply(_ command: Command) async throws {
        try await session().perform(command)
        await radio.refreshSelfInfo()
    }

    public func setName(_ name: String) async throws {
        try await apply(.setAdvertName(name))
    }

    /// Changes LoRa settings. The radio can then only talk to nodes on the same settings.
    public func setRadio(_ parameters: RadioParameters, clientRepeat: Bool? = nil) async throws {
        try await apply(.setRadioParams(parameters, clientRepeat: clientRepeat))
    }

    public func setTxPower(_ dbm: Int8) async throws {
        try await apply(.setRadioTxPower(dbm))
    }

    public func setTuning(_ params: TuningParams) async throws {
        try await session().perform(.setTuningParams(params))
        tuning = params
    }

    public func updateOtherParams(_ change: (inout OtherParams) -> Void) async throws {
        guard let selfInfo = radio.selfInfo else { throw RadioSettingsError.notConnected }
        var params = OtherParams(from: selfInfo)
        change(&params)
        try await apply(.setOtherParams(params))
    }

    public func setAutoAdd(_ config: AutoAddConfig) async throws {
        try await session().perform(.setAutoAddConfig(config))
        autoAdd = config
    }

    /// 0 removes the PIN; otherwise 6 digits.
    public func setPin(_ pin: UInt32) async throws {
        guard pin == 0 || (100_000...999_999).contains(pin) else { throw RadioSettingsError.invalidPin }
        try await session().perform(.setDevicePin(pin))
    }

    /// Wi‑Fi builds only; takes effect after a reboot.
    public func setWiFi(ssid: String, password: String, enabled: Bool) async throws {
        let session = try await session()
        _ = try await session.runCLICommand("set wifi.ssid \(ssid)")
        _ = try await session.runCLICommand("set wifi.pwd \(password)")
        _ = try await session.runCLICommand("set wifi.enabled \(enabled ? "on" : "off")")
    }

    public func exportPrivateKey() async throws -> Data {
        let session = try await session()
        do {
            return try await session.request(.exportPrivateKey) { if case .privateKey(let key) = $0 { key } else { nil } }
        } catch MeshError.disabled {
            throw RadioSettingsError.disabledByFirmware
        }
    }

    public func importPrivateKey(_ key: Data) async throws {
        do {
            try await session().perform(.importPrivateKey(key))
        } catch MeshError.disabled {
            throw RadioSettingsError.disabledByFirmware
        }
    }

    public func reboot() async throws {
        try await session().sendExpectingPush(.reboot)
    }

    public func powerOff() async throws {
        _ = try? await session().runCLICommand("poweroff")
    }

    /// Erases everything on the radio, including its identity.
    public func factoryReset() async throws {
        try await session().sendExpectingPush(.factoryReset)
    }

    // MARK: Profiles

    public func exportProfile(includePrivateKey: Bool) async throws -> DeviceProfile {
        guard let selfInfo = radio.selfInfo else { throw RadioSettingsError.notConnected }
        await load()
        let channels = (messaging.store?.channels() ?? []).map {
            DeviceProfile.Channel(index: $0.index, name: $0.name, secretHex: $0.secret.hexString)
        }
        let key = includePrivateKey ? try await exportPrivateKey().hexString : nil
        return DeviceProfile(
            name: selfInfo.name, frequencyKHz: selfInfo.radio.frequencyKHz, bandwidthHz: selfInfo.radio.bandwidthHz,
            spreadingFactor: selfInfo.radio.spreadingFactor, codingRate: selfInfo.radio.codingRate, txPowerDbm: selfInfo.txPowerDbm,
            telemetryModes: selfInfo.telemetryModes.byte, advertLocationPolicy: selfInfo.advertLocationPolicy,
            manualAddContacts: selfInfo.manualAddContacts, multiAcks: selfInfo.multiAcks,
            autoAddFlags: autoAdd?.flags, autoAddMaxHops: autoAdd?.maxHops,
            rxDelayBase: tuning?.rxDelayBase, airtimeFactor: tuning?.airtimeFactor,
            channels: channels, privateKeyHex: key
        )
    }

    public func importProfile(_ profile: DeviceProfile, includePrivateKey: Bool) async throws {
        let session = try await session()
        try await session.perform(.setAdvertName(profile.name))
        try await session.perform(.setRadioParams(RadioParameters(
            frequencyKHz: profile.frequencyKHz, bandwidthHz: profile.bandwidthHz,
            spreadingFactor: profile.spreadingFactor, codingRate: profile.codingRate
        )))
        try await session.perform(.setRadioTxPower(profile.txPowerDbm))
        try await session.perform(.setOtherParams(OtherParams(
            manualAddContacts: profile.manualAddContacts, telemetryModes: TelemetryModes(byte: profile.telemetryModes),
            advertLocationPolicy: profile.advertLocationPolicy, multiAcks: profile.multiAcks
        )))
        if let flags = profile.autoAddFlags {
            try? await session.perform(.setAutoAddConfig(AutoAddConfig(flags: flags, maxHops: profile.autoAddMaxHops)))
        }
        if let rx = profile.rxDelayBase, let af = profile.airtimeFactor {
            try? await session.perform(.setTuningParams(TuningParams(rxDelayBase: rx, airtimeFactor: af)))
        }
        for channel in profile.channels {
            guard let secret = Data(hexString: channel.secretHex), secret.count == 16 else { continue }
            try await session.perform(.setChannel(ChannelInfo(index: UInt8(channel.index), name: channel.name, secret: [UInt8](secret))))
        }
        if includePrivateKey, let hex = profile.privateKeyHex, let key = Data(hexString: hex) {
            try await importPrivateKey(key)
        }
        await radio.refreshSelfInfo()
        await messaging.syncChannels()
    }
}
