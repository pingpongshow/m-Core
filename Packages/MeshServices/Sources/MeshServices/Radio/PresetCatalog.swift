import Foundation
import MeshCoreKit
import Observation

/// Why a custom LoRa setting can't be saved.
public enum CustomPresetError: Error, Equatable, Sendable, CustomStringConvertible {
    case emptyName
    case frequencyOutOfRange
    case unsupportedBandwidth
    case spreadingFactorOutOfRange
    case codingRateOutOfRange

    public var description: String {
        switch self {
        case .emptyName: "Give the setting a name."
        case .frequencyOutOfRange: "Frequency must be between 150 and 960 MHz."
        case .unsupportedBandwidth: "Pick one of the LoRa bandwidths."
        case .spreadingFactorOutOfRange: "Spreading factor must be 5–12."
        case .codingRateOutOfRange: "Coding rate must be 5–8 (4/5 to 4/8)."
        }
    }
}

/// Every LoRa setting the app offers: MeshCore's suggested regional settings (bundled, refreshed from
/// api.meshcore.nz) plus the user's own, e.g. a local mesh that uses its own frequency. Used by Mesh Discovery and
/// Radio settings.
@MainActor
@Observable
public final class PresetCatalog {
    public static let officialURL = URL(string: "https://api.meshcore.nz/api/v1/config")! // swiftlint:disable:this force_unwrapping
    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// LoRa bandwidths the SX126x/SX127x radios MeshCore runs on support, in kHz.
    public static let bandwidthsKHz: [Double] = [7.8, 10.4, 15.6, 20.8, 31.25, 41.7, 62.5, 125, 250, 500]

    /// The user's own settings.
    public private(set) var presets: [RadioPreset] = []
    /// MeshCore's suggested regional settings.
    public private(set) var official: [RadioPreset] = RadioPreset.all
    public private(set) var officialUpdatedAt: Date?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let fetch: Fetch
    private static let key = "radio.customPresets"
    private static let officialKey = "radio.officialPresets"
    private static let officialDateKey = "radio.officialPresetsDate"

    private struct Stored: Codable {
        var id: String
        var name: String
        var frequencyKHz: UInt32
        var bandwidthHz: UInt32
        var spreadingFactor: UInt8
        var codingRate: UInt8
    }

    public init(defaults: UserDefaults = .standard, fetch: @escaping Fetch = { try await URLSession.shared.data(for: $0) }) {
        self.defaults = defaults
        self.fetch = fetch
        if let data = defaults.data(forKey: Self.officialKey), let cached = try? Self.parseOfficial(data), !cached.isEmpty {
            official = cached
            officialUpdatedAt = defaults.object(forKey: Self.officialDateKey) as? Date
        }
        if let data = defaults.data(forKey: Self.key), let stored = try? JSONDecoder().decode([Stored].self, from: data) {
            presets = stored.map {
                RadioPreset(id: $0.id, name: $0.name, region: RadioPreset.customRegion, radio: RadioParameters(
                    frequencyKHz: $0.frequencyKHz, bandwidthHz: $0.bandwidthHz,
                    spreadingFactor: $0.spreadingFactor, codingRate: $0.codingRate
                ))
            }
        }
    }

    /// Regional presets followed by the user's own.
    public var allPresets: [RadioPreset] { official + presets }

    /// Regions of the official presets, in list order.
    public var regions: [String] { RadioPreset.regions(of: official) }

    /// Fetches the latest suggested settings, at most once a day unless `force`. Keeps the current list if the
    /// request fails.
    public func refreshOfficial(force: Bool = false) async {
        if !force, let officialUpdatedAt, Date().timeIntervalSince(officialUpdatedAt) < 86_400 { return }
        do {
            let (data, response) = try await fetch(URLRequest(url: Self.officialURL))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            let parsed = try Self.parseOfficial(data)
            guard !parsed.isEmpty else { return }
            official = parsed
            officialUpdatedAt = Date()
            defaults.set(data, forKey: Self.officialKey)
            defaults.set(officialUpdatedAt, forKey: Self.officialDateKey)
        } catch {
            // Offline or changed format: the bundled or cached list stays.
        }
    }

    /// Parses the API's `config.suggested_radio_settings.entries`. IDs reuse the bundled ones where the title matches.
    nonisolated static func parseOfficial(_ data: Data) throws -> [RadioPreset] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let entries = try decoder.decode(OfficialConfig.self, from: data).config.suggestedRadioSettings.entries
        let bundledIDs = Dictionary(RadioPreset.all.map { ($0.name.lowercased(), $0.id) }, uniquingKeysWith: { first, _ in first })
        let presets = entries.compactMap { entry -> RadioPreset? in
            guard let mhz = Double(entry.frequency), let khz = Double(entry.bandwidth),
                  let sf = UInt8(entry.spreadingFactor), let cr = UInt8(entry.codingRate) else { return nil }
            let slug = entry.title.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            return RadioPreset(
                id: bundledIDs[entry.title.lowercased()] ?? "official-\(slug)",
                name: entry.title,
                region: RadioPreset.region(forTitle: entry.title),
                radio: RadioParameters(frequencyKHz: UInt32((mhz * 1000).rounded()), bandwidthHz: UInt32((khz * 1000).rounded()),
                                       spreadingFactor: sf, codingRate: cr),
                pathHashSize: entry.networkSettings?.pathHashSize.map { UInt8(clamping: $0) }
            )
        }
        let order = ["North America", "Central & South America", "Europe", "Oceania", "Asia", "Other"]
        return presets.enumerated().sorted { lhs, rhs in
            let left = order.firstIndex(of: lhs.element.region) ?? order.count
            let right = order.firstIndex(of: rhs.element.region) ?? order.count
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }

    public func matching(_ radio: RadioParameters) -> RadioPreset? {
        allPresets.first { $0.radio == radio }
    }

    /// Adds a setting, or replaces the one with the same `id`.
    @discardableResult
    public func save(
        id: String? = nil, name: String, frequencyMHz: Double, bandwidthKHz: Double, spreadingFactor: Int, codingRate: Int
    ) throws(CustomPresetError) -> RadioPreset {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .emptyName }
        guard (150...960).contains(frequencyMHz) else { throw .frequencyOutOfRange }
        guard Self.bandwidthsKHz.contains(where: { abs($0 - bandwidthKHz) < 0.01 }) else { throw .unsupportedBandwidth }
        guard (5...12).contains(spreadingFactor) else { throw .spreadingFactorOutOfRange }
        guard (5...8).contains(codingRate) else { throw .codingRateOutOfRange }
        let preset = RadioPreset(
            id: id ?? "custom-\(UUID().uuidString)", name: trimmed, region: RadioPreset.customRegion,
            radio: RadioParameters(
                frequencyKHz: UInt32((frequencyMHz * 1000).rounded()), bandwidthHz: UInt32((bandwidthKHz * 1000).rounded()),
                spreadingFactor: UInt8(spreadingFactor), codingRate: UInt8(codingRate)
            )
        )
        if let index = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[index] = preset
        } else {
            presets.append(preset)
        }
        persist()
        return preset
    }

    public func delete(id: String) {
        presets.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        let stored = presets.map {
            Stored(id: $0.id, name: $0.name, frequencyKHz: $0.radio.frequencyKHz, bandwidthHz: $0.radio.bandwidthHz,
                   spreadingFactor: $0.radio.spreadingFactor, codingRate: $0.radio.codingRate)
        }
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: Self.key) }
    }
}

/// `GET api.meshcore.nz/api/v1/config`, reduced to the suggested radio settings (snake_case on the wire).
private struct OfficialConfig: Decodable {
    var config: OfficialConfigBody
}

private struct OfficialConfigBody: Decodable {
    var suggestedRadioSettings: OfficialRadioSettings
}

private struct OfficialRadioSettings: Decodable {
    var entries: [OfficialPresetEntry]
}

private struct OfficialPresetEntry: Decodable {
    struct Network: Decodable { var pathHashSize: Int? }
    var title: String
    var frequency: String
    var spreadingFactor: String
    var bandwidth: String
    var codingRate: String
    var networkSettings: Network?
}
