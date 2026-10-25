import Foundation
import MeshCoreKit

/// The node publishing what it hears, as identified to MeshCore analyzers.
public struct ObserverIdentity: Equatable, Hashable, Sendable {
    /// The radio's advertised name (`origin`).
    public var name: String
    public var publicKey: PublicKey
    /// Region code used in topics, e.g. "SEA".
    public var iata: String

    public init(name: String, publicKey: PublicKey, iata: String) {
        self.name = name
        self.publicKey = publicKey
        self.iata = iata
    }

    /// Uppercase public key hex (`origin_id`, topic `{PUBLIC_KEY}`).
    public var publicKeyHex: String { publicKey.hex.uppercased() }
}

/// Status fields reported alongside the observer's online/offline state.
public struct ObserverStatus: Equatable, Sendable {
    public var isOnline: Bool
    /// "freqMHz,bwKHz,sf,cr", e.g. "910.525,62.5,7,5"; see `ObserverUplink.radioDescription`.
    public var radio: String?
    public var model: String?
    public var firmwareVersion: String?
    public var clientVersion: String

    public init(isOnline: Bool, radio: String? = nil, model: String? = nil, firmwareVersion: String? = nil, clientVersion: String) {
        self.isOnline = isOnline
        self.radio = radio
        self.model = model
        self.firmwareVersion = firmwareVersion
        self.clientVersion = clientVersion
    }
}

/// Topics and JSON messages compatible with the community `meshcoretomqtt` bridge, which
/// LetsMesh / CoreScope style analyzers consume.
public enum ObserverUplink {
    public static let packetsTopicTemplate = "meshcore/{IATA}/{PUBLIC_KEY}/packets"
    public static let statusTopicTemplate = "meshcore/{IATA}/{PUBLIC_KEY}/status"

    /// Replaces `{IATA}` and `{PUBLIC_KEY}` (uppercase hex) in a topic template.
    public static func topic(_ template: String, for observer: ObserverIdentity) -> String {
        template
            .replacingOccurrences(of: "{IATA}", with: observer.iata)
            .replacingOccurrences(of: "{PUBLIC_KEY}", with: observer.publicKeyHex)
    }

    public static func packetsTopic(for observer: ObserverIdentity) -> String {
        topic(packetsTopicTemplate, for: observer)
    }

    public static func statusTopic(for observer: ObserverIdentity) -> String {
        topic(statusTopicTemplate, for: observer)
    }

    /// The bridge's client ID: prefix + public key hex, restricted to `[A-Za-z0-9_-]`, cut to 23 characters.
    public static func clientID(for publicKey: PublicKey, prefix: String = "meshcore_") -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        let raw = (prefix + publicKey.hex.uppercased()).replacingOccurrences(of: " ", with: "_")
        return String(raw.filter { allowed.contains($0) }.prefix(23))
    }

    /// Radio settings formatted like the firmware's `get radio` reply: "910.525,62.5,7,5".
    public static func radioDescription(_ radio: RadioParameters) -> String {
        [trimmedDecimal(radio.frequencyMHz), trimmedDecimal(radio.bandwidthKHz), String(radio.spreadingFactor), String(radio.codingRate)]
            .joined(separator: ",")
    }

    /// A PACKET message for a packet from the radio's RX log, or nil if it doesn't decode
    /// (the firmware only logs packets it could parse).
    public static func packetMessage(
        _ entry: RxLogEntry,
        observer: ObserverIdentity,
        receivedAt: Date = Date(),
        radio: RadioParameters? = nil
    ) -> String? {
        packetMessage(raw: entry.raw, snr: entry.snr, rssi: Int(entry.rssi), observer: observer, receivedAt: receivedAt, radio: radio)
    }

    /// A PACKET message. Fields follow the firmware's `RX, len=…` log line as parsed by the bridge:
    ///
    /// - `len`: raw packet length; `packet_type`: payload type number; `route`: "D" for direct and
    ///   transport-direct, "F" for flood and transport-flood; `payload_len`: payload bytes.
    /// - `SNR`/`RSSI`: whole numbers, truncated toward zero like the firmware's `(int)` cast.
    /// - `score`: the firmware's packet score ×1000, computed from `radio`'s spreading factor; "0" without `radio`.
    /// - `duration`: estimated airtime in whole milliseconds from `radio`; "0" without `radio`.
    /// - `hash`: 16 uppercase hex digits; `path` ("SRC -> DST" hashes, as the firmware prints them
    ///   as `[%02X -> %02X]` with payload[1] then payload[0]) only for direct REQ/RESPONSE/TXT_MSG/PATH packets.
    /// - `time`/`date`: `receivedAt` in UTC as "HH:mm:ss" and "d/M/yyyy" (the firmware logs its RTC clock).
    public static func packetMessage(
        raw: Data,
        snr: Double,
        rssi: Int,
        observer: ObserverIdentity,
        receivedAt: Date = Date(),
        radio: RadioParameters? = nil
    ) -> String? {
        guard let packet = MeshPacket.decode(raw) else { return nil }
        var score = 0
        var duration = 0
        if let radio {
            let sf = Int(radio.spreadingFactor)
            score = Int(LoRaEstimate.packetScore(snr: snr, spreadingFactor: sf, packetLength: raw.count) * 1000)
            duration = Int(LoRaEstimate.airtimeMilliseconds(
                payloadLength: raw.count, spreadingFactor: sf, bandwidthKHz: radio.bandwidthKHz, codingRate: Int(radio.codingRate)
            ))
        }
        let clock = utcComponents(receivedAt)
        var members = origin(observer, at: receivedAt) + [
            ("type", .string("PACKET")),
            ("direction", .string("rx")),
            ("time", .string(String(format: "%02d:%02d:%02d", clock.hour ?? 0, clock.minute ?? 0, clock.second ?? 0))),
            ("date", .string("\(clock.day ?? 1)/\(clock.month ?? 1)/\(clock.year ?? 1970)")),
            ("len", .string(String(packet.rawLength))),
            ("packet_type", .string(String(packet.payloadType.rawValue))),
            ("route", .string(packet.routeType.logLetter)),
            ("payload_len", .string(String(packet.payload.count))),
            ("raw", .string(packet.rawHex)),
            ("SNR", .string(String(Int(snr)))),
            ("RSSI", .string(String(rssi))),
            ("score", .string(String(score))),
            ("duration", .string(String(duration))),
            ("hash", .string(packet.hashHex)),
        ]
        if packet.routeType.isDirect, let hashes = packet.addressHashes {
            members.append(("path", .string(String(format: "%02X -> %02X", hashes.source, hashes.destination))))
        }
        return OrderedJSON.object(members).serialized()
    }

    /// A status message (`online` on connect, `offline` as the MQTT will).
    /// Missing radio/model/firmware fields are sent as "unknown", like the bridge.
    public static func statusMessage(_ status: ObserverStatus, observer: ObserverIdentity, at date: Date = Date()) -> String {
        let members: [(String, OrderedJSON)] = [
            ("status", .string(status.isOnline ? "online" : "offline")),
            ("timestamp", .string(isoTimestamp(date))),
            ("origin", .string(observer.name)),
            ("origin_id", .string(observer.publicKeyHex)),
            ("radio", .string(status.radio ?? "unknown")),
            ("model", .string(status.model ?? "unknown")),
            ("firmware_version", .string(status.firmwareVersion ?? "unknown")),
            ("client_version", .string(status.clientVersion)),
        ]
        return OrderedJSON.object(members).serialized()
    }

    /// ISO 8601 in UTC with microseconds and a `+00:00` offset, as Python's `isoformat()` writes it.
    public static func isoTimestamp(_ date: Date) -> String {
        let clock = utcComponents(date)
        let micros = Int(((date.timeIntervalSince1970 - floor(date.timeIntervalSince1970)) * 1_000_000).rounded(.down))
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d.%06d+00:00",
            clock.year ?? 1970, clock.month ?? 1, clock.day ?? 1,
            clock.hour ?? 0, clock.minute ?? 0, clock.second ?? 0, micros
        )
    }

    private static func origin(_ observer: ObserverIdentity, at date: Date) -> [(String, OrderedJSON)] {
        [
            ("origin", .string(observer.name)),
            ("origin_id", .string(observer.publicKeyHex)),
            ("timestamp", .string(isoTimestamp(date))),
        ]
    }

    private static func utcComponents(_ date: Date) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let whole = Date(timeIntervalSince1970: floor(date.timeIntervalSince1970))
        return calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: whole)
    }

    /// Rounds to 3 decimals and drops trailing zeros (firmware `StrHelper::ftoa3`).
    static func trimmedDecimal(_ value: Double) -> String {
        var text = String(format: "%.3f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}
