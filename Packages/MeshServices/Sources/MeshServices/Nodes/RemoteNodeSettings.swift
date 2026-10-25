import Foundation

// Remote settings for repeaters and room servers, sent as text CLI commands after an admin login.
//
// Command names, value ranges and reply formats are from MeshCore firmware v1.18 (tags repeater-v1.18.0 and
// room-server-v1.18.0), shared by both roles:
// - docs/cli_commands.md — https://github.com/meshcore-dev/MeshCore/blob/main/docs/cli_commands.md
// - src/helpers/CommonCLI.cpp — `handleGetCmd`/`handleSetCmd`: `get` replies are "> value", `set` replies "OK"
//   (or "OK - repeat is now ON/OFF"), errors start with "Error"/"ERROR", unknown keys reply "??: key" or "unknown config: ".
// - src/helpers/CommonRadioPrefs.cpp — `get radio` → "> freq,bw,sf,cr", `set radio f,bw,sf,cr` → "OK - reboot to apply",
//   `get tx` / `set tx <dBm>`.

/// LoRa parameters as the remote CLI reads and writes them (`get radio` / `set radio <freq>,<bw>,<sf>,<cr>`).
public struct RemoteRadioParameters: Equatable, Hashable, Sendable {
    public var frequencyMHz: Double
    public var bandwidthKHz: Double
    public var spreadingFactor: Int
    public var codingRate: Int

    public init(frequencyMHz: Double, bandwidthKHz: Double, spreadingFactor: Int, codingRate: Int) {
        self.frequencyMHz = frequencyMHz
        self.bandwidthKHz = bandwidthKHz
        self.spreadingFactor = spreadingFactor
        self.codingRate = codingRate
    }

    /// Firmware limits from `CommonRadioPrefs::handleCommand`: 150–2500 MHz, 7–500 kHz, SF 5–12, CR 5–8.
    public var isValid: Bool {
        (150...2_500).contains(frequencyMHz) && (7...500).contains(bandwidthKHz)
            && (5...12).contains(spreadingFactor) && (5...8).contains(codingRate)
    }

    /// Parses "869.618,62.5,8,5".
    init?(cliValue: String) {
        let parts = cliValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 4, let frequency = Double(parts[0]), let bandwidth = Double(parts[1]),
              let spreading = Int(parts[2]), let coding = Int(parts[3]) else { return nil }
        self.init(frequencyMHz: frequency, bandwidthKHz: bandwidth, spreadingFactor: spreading, codingRate: coding)
    }

    var cliValue: String {
        let frequency = RemoteSetting.decimal(frequencyMHz, places: 3)
        let bandwidth = RemoteSetting.decimal(bandwidthKHz, places: 3)
        return "\(frequency),\(bandwidth),\(spreadingFactor),\(codingRate)"
    }
}

/// Settings readable with `get <key>`.
public enum RemoteSettingKey: String, CaseIterable, Sendable {
    case name
    case radio
    case txPower = "tx"
    case advertInterval = "advert.interval"
    case floodAdvertInterval = "flood.advert.interval"
    case floodMaxHops = "flood.max"
    case guestPassword = "guest.password"
    case latitude = "lat"
    case longitude = "lon"
    case repeatEnabled = "repeat"

    /// `get radio` must be the exact command (the firmware compares it with `strcmp`).
    public var getCommand: String { "get \(rawValue)" }
}

/// What a repeater or room server reported for its settings; nil where it didn't answer.
public struct RemoteNodeSettings: Equatable, Sendable {
    public var name: String?
    public var radio: RemoteRadioParameters?
    public var txPowerDbm: Int?
    /// Zero-hop advert interval in minutes; 0 is off.
    public var advertIntervalMinutes: Int?
    /// Flood advert interval in hours; 0 is off.
    public var floodAdvertIntervalHours: Int?
    public var floodMaxHops: Int?
    public var guestPassword: String?
    public var latitude: Double?
    public var longitude: Double?
    public var repeatEnabled: Bool?

    public init() {}

    /// Stores the value from a `get` reply (already stripped of "> "); ignores values that don't parse.
    public mutating func apply(_ value: String, for key: RemoteSettingKey) {
        switch key {
        case .name: name = value
        case .radio: radio = RemoteRadioParameters(cliValue: value)
        case .txPower: txPowerDbm = Int(value)
        case .advertInterval: advertIntervalMinutes = Int(value)
        case .floodAdvertInterval: floodAdvertIntervalHours = Int(value)
        case .floodMaxHops: floodMaxHops = Int(value)
        case .guestPassword: guestPassword = value
        case .latitude: latitude = Double(value)
        case .longitude: longitude = Double(value)
        case .repeatEnabled:
            switch value.lowercased() {
            case "on": repeatEnabled = true
            case "off": repeatEnabled = false
            default: break
            }
        }
    }
}

/// A change to send to a repeater or room server, or an action to run on it.
public enum RemoteSetting: Equatable, Sendable {
    /// `set name <name>`: up to 31 bytes, without `[ ] \ : , ? *`.
    case name(String)
    /// `set radio <freq>,<bw>,<sf>,<cr>`; applies after a reboot.
    case radio(RemoteRadioParameters)
    /// `set tx <dBm>`, 1–22 dBm at the LoRa chip.
    case txPower(Int)
    /// `set advert.interval <minutes>`: 0 (off) or 60–240.
    case advertInterval(minutes: Int)
    /// `set flood.advert.interval <hours>`: 0 (off) or 3–168.
    case floodAdvertInterval(hours: Int)
    /// `set flood.max <hops>`: 0–64.
    case floodMaxHops(Int)
    /// `set guest.password <password>`, up to 15 characters.
    case guestPassword(String)
    /// `password <password>` (there's no `get` form; the reply echoes it), up to 15 characters.
    case adminPassword(String)
    /// `set lat <degrees>`.
    case latitude(Double)
    /// `set lon <degrees>`.
    case longitude(Double)
    /// `set repeat on|off`.
    case repeatEnabled(Bool)
    /// `advert`: send a flood advert now.
    case sendAdvert
    /// `advert.zerohop`: send a zero-hop advert now.
    case sendZeroHopAdvert
    /// `reboot`: the node restarts without replying.
    case reboot

    /// The exact command line sent to the node.
    public var command: String {
        switch self {
        case .name(let name): "set name \(name)"
        case .radio(let radio): "set radio \(radio.cliValue)"
        case .txPower(let dbm): "set tx \(dbm)"
        case .advertInterval(let minutes): "set advert.interval \(minutes)"
        case .floodAdvertInterval(let hours): "set flood.advert.interval \(hours)"
        case .floodMaxHops(let hops): "set flood.max \(hops)"
        case .guestPassword(let password): "set guest.password \(password)"
        case .adminPassword(let password): "password \(password)"
        case .latitude(let degrees): "set lat \(Self.decimal(degrees, places: 6))"
        case .longitude(let degrees): "set lon \(Self.decimal(degrees, places: 6))"
        case .repeatEnabled(let on): "set repeat \(on ? "on" : "off")"
        case .sendAdvert: "advert"
        case .sendZeroHopAdvert: "advert.zerohop"
        case .reboot: "reboot"
        }
    }

    /// Why the firmware would reject this value, checked before sending; nil when it's acceptable.
    public var validationError: String? {
        switch self {
        case .name(let name):
            if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter a name." }
            if name.utf8.count > 31 { return "Names can be at most 31 bytes." }
            if name.contains(where: { "[]\\:,?*".contains($0) }) { return "Names can't contain [ ] \\ : , ? or *." }
        case .radio(let radio):
            if !radio.isValid { return "Use 150–2500 MHz, 7–500 kHz, SF 5–12 and CR 5–8." }
        case .txPower(let dbm):
            if !(1...22).contains(dbm) { return "TX power must be 1–22 dBm." }
        case .advertInterval(let minutes):
            if minutes != 0 && !(60...240).contains(minutes) { return "Use 0 (off) or 60–240 minutes." }
        case .floodAdvertInterval(let hours):
            if hours != 0 && !(3...168).contains(hours) { return "Use 0 (off) or 3–168 hours." }
        case .floodMaxHops(let hops):
            if !(0...64).contains(hops) { return "Flood max must be 0–64 hops." }
        case .guestPassword(let password):
            if password.utf8.count > 15 { return "Passwords can be at most 15 characters." }
        case .adminPassword(let password):
            if password.isEmpty { return "Enter a password." }
            if password.utf8.count > 15 { return "Passwords can be at most 15 characters." }
        case .latitude(let degrees):
            if !(-90...90).contains(degrees) { return "Latitude must be between -90 and 90." }
        case .longitude(let degrees):
            if !(-180...180).contains(degrees) { return "Longitude must be between -180 and 180." }
        case .repeatEnabled, .sendAdvert, .sendZeroHopAdvert, .reboot:
            break
        }
        return nil
    }

    /// Shortest decimal text with at most `places` decimals ("62.5", "869.618", "-122.4194").
    static func decimal(_ value: Double, places: Int) -> String {
        var text = String(format: "%.\(places)f", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text == "-0" ? "0" : text
    }
}

/// Reading remote CLI replies.
public enum RemoteCLIReply {
    /// The value of a `get` reply ("> 47" → "47"), or nil when the node didn't recognise the key or failed.
    public static func value(of reply: String) -> String? {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(">") else { return nil }
        return String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
    }

    /// Whether a reply reports a failure ("Error…", "ERROR…", "ERR:", "??: key", "unknown config", "Unknown command").
    public static func isError(_ reply: String) -> Bool {
        let lowered = reply.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lowered.hasPrefix("error") || lowered.hasPrefix("err:") || lowered.hasPrefix("(err") || lowered.hasPrefix("??")
            || lowered.hasPrefix("unknown")
    }
}

public enum RemoteSettingError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalid(String)
    /// The node answered with an error message.
    case rejected(String)

    public var description: String {
        switch self {
        case .invalid(let message): message
        case .rejected(let reply): "The node said: \(reply)"
        }
    }
}

extension RemoteNodeService {
    /// Reads one setting with `get <key>` (admin login required). Returns nil when the node doesn't support the key.
    public func readSetting(_ key: RemoteSettingKey, keyHex: String) async throws -> String? {
        RemoteCLIReply.value(of: try await runCommand(key.getCommand, keyHex: keyHex))
    }

    /// Reads every setting in turn, reporting each as it arrives. Keys that time out or aren't supported stay nil.
    public func readSettings(
        keyHex: String,
        progress: (RemoteNodeSettings) -> Void = { _ in }
    ) async throws -> RemoteNodeSettings {
        var settings = RemoteNodeSettings()
        for key in RemoteSettingKey.allCases {
            do {
                if let value = try await readSetting(key, keyHex: keyHex) {
                    settings.apply(value, for: key)
                    progress(settings)
                }
            } catch RemoteRequestError.timedOut {
                continue
            }
        }
        return settings
    }

    /// Sends a change or action and returns the node's reply. `reboot` returns as soon as it's sent, since the node
    /// restarts without answering.
    @discardableResult
    public func apply(_ setting: RemoteSetting, keyHex: String) async throws -> String {
        if let problem = setting.validationError { throw RemoteSettingError.invalid(problem) }
        if setting == .reboot {
            do {
                return try await runCommand(setting.command, keyHex: keyHex, timeout: .seconds(5))
            } catch RemoteRequestError.timedOut {
                return "Rebooting"
            }
        }
        let reply = try await runCommand(setting.command, keyHex: keyHex)
        if RemoteCLIReply.isError(reply) { throw RemoteSettingError.rejected(reply) }
        return reply
    }
}
