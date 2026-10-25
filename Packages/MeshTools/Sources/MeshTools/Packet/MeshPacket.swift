import CryptoKit
import Foundation
import MeshCoreKit

/// How a packet is routed (`ROUTE_TYPE_*`, low two bits of the header).
public enum RouteType: UInt8, Sendable, CaseIterable {
    /// Flood with two 16-bit transport (region scope) codes.
    case transportFlood = 0
    case flood = 1
    case direct = 2
    /// Direct with two 16-bit transport codes.
    case transportDirect = 3

    public var isFlood: Bool { self == .flood || self == .transportFlood }
    public var isDirect: Bool { !isFlood }
    public var hasTransportCodes: Bool { self == .transportFlood || self == .transportDirect }

    /// Letter the firmware's packet log prints: "D" for either direct type, otherwise "F".
    public var logLetter: String { isDirect ? "D" : "F" }

    public var name: String {
        switch self {
        case .transportFlood: "transport flood"
        case .flood: "flood"
        case .direct: "direct"
        case .transportDirect: "transport direct"
        }
    }
}

/// What a packet carries (`PAYLOAD_TYPE_*`, header bits 2–5).
public enum PayloadType: Equatable, Hashable, Sendable {
    case request
    case response
    case textMessage
    case ack
    case advert
    case groupText
    case groupData
    case anonRequest
    case path
    case trace
    case multipart
    case control
    case rawCustom
    case unknown(UInt8)

    public init(rawValue: UInt8) {
        switch rawValue {
        case 0x00: self = .request
        case 0x01: self = .response
        case 0x02: self = .textMessage
        case 0x03: self = .ack
        case 0x04: self = .advert
        case 0x05: self = .groupText
        case 0x06: self = .groupData
        case 0x07: self = .anonRequest
        case 0x08: self = .path
        case 0x09: self = .trace
        case 0x0A: self = .multipart
        case 0x0B: self = .control
        case 0x0F: self = .rawCustom
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: UInt8 {
        switch self {
        case .request: 0x00
        case .response: 0x01
        case .textMessage: 0x02
        case .ack: 0x03
        case .advert: 0x04
        case .groupText: 0x05
        case .groupData: 0x06
        case .anonRequest: 0x07
        case .path: 0x08
        case .trace: 0x09
        case .multipart: 0x0A
        case .control: 0x0B
        case .rawCustom: 0x0F
        case .unknown(let value): value
        }
    }

    public var name: String {
        switch self {
        case .request: "Request"
        case .response: "Response"
        case .textMessage: "Text message"
        case .ack: "Ack"
        case .advert: "Advert"
        case .groupText: "Group text"
        case .groupData: "Group data"
        case .anonRequest: "Anon request"
        case .path: "Path"
        case .trace: "Trace"
        case .multipart: "Multipart"
        case .control: "Control"
        case .rawCustom: "Raw custom"
        case .unknown(let value): "Type \(value)"
        }
    }

    /// Payloads that start with 1-byte destination and source hashes (payload version 1).
    public var hasAddressHashes: Bool {
        switch self {
        case .request, .response, .textMessage, .path: true
        default: false
        }
    }
}

/// The two 16-bit region-scope codes carried by transport route types (little-endian on the wire).
public struct TransportCodes: Equatable, Hashable, Sendable {
    public var first: UInt16
    public var second: UInt16

    public init(first: UInt16, second: UInt16) {
        self.first = first
        self.second = second
    }
}

/// Why raw bytes couldn't be decoded as a packet.
public enum MeshPacketDecodingError: Error, Equatable, Sendable {
    case empty
    /// The packet ended inside the header, transport codes or path.
    case truncated
    /// Path-length byte uses the reserved hash-size mode (top bits `11`) or exceeds 64 bytes.
    case invalidPathLength(UInt8)
    /// Payload longer than the firmware's 184-byte maximum.
    case payloadTooLong(Int)
}

/// An over-the-air MeshCore packet, as reported raw by a radio's RX log (`Packet::readFrom`).
///
/// Wire layout: header, [transport codes ×2 (u16 LE)], path length, path hashes, payload.
public struct MeshPacket: Equatable, Hashable, Sendable {
    public static let maxPayloadSize = 184
    /// Bytes of SHA-256 the firmware keeps as a packet hash (`MAX_HASH_SIZE`).
    public static let hashSize = 8

    public let raw: Data
    public let header: UInt8
    public let routeType: RouteType
    public let payloadType: PayloadType
    /// Header bits 6–7 (`PAYLOAD_VER_*`); 0 is version 1, the only one firmware currently accepts.
    public let payloadVersion: UInt8
    public let transportCodes: TransportCodes?
    /// The wire path-length byte: hash size − 1 in the top two bits, hop count in the low six.
    public let pathLength: UInt8
    /// Repeater hashes: hops travelled so far (flood) or hops still to go (direct).
    public let path: MeshPath
    public let payload: Data

    public init(raw: Data) throws(MeshPacketDecodingError) {
        let bytes = [UInt8](raw)
        guard let header = bytes.first else { throw .empty }
        let route = RouteType(rawValue: header & 0x03) ?? .flood
        var index = 1
        var codes: TransportCodes?
        if route.hasTransportCodes {
            guard bytes.count >= index + 4 else { throw .truncated }
            codes = TransportCodes(
                first: UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8,
                second: UInt16(bytes[index + 2]) | UInt16(bytes[index + 3]) << 8
            )
            index += 4
        }
        guard bytes.count > index else { throw .truncated }
        let pathLength = bytes[index]
        index += 1
        guard let pathByteCount = MeshPath.byteCount(forEncodedLength: pathLength) else {
            throw .invalidPathLength(pathLength)
        }
        guard bytes.count >= index + pathByteCount,
              let path = MeshPath(encodedLength: pathLength, bytes: Array(bytes[index...]))
        else { throw .truncated }
        index += pathByteCount
        let payloadCount = bytes.count - index
        guard payloadCount <= Self.maxPayloadSize else { throw .payloadTooLong(payloadCount) }

        self.raw = raw
        self.header = header
        self.routeType = route
        self.payloadType = PayloadType(rawValue: (header >> 2) & 0x0F)
        self.payloadVersion = header >> 6
        self.transportCodes = codes
        self.pathLength = pathLength
        self.path = path
        self.payload = Data(bytes[index...])
    }

    /// Decodes `raw`, returning nil instead of throwing.
    public static func decode(_ raw: Data) -> MeshPacket? {
        try? MeshPacket(raw: raw)
    }

    /// Decodes a hex string (as logged by bridges and analyzers).
    public init?(hex: String) {
        guard let data = Data(hexString: hex), let packet = try? MeshPacket(raw: data) else { return nil }
        self = packet
    }

    public var hopCount: Int { path.hashes.count }

    /// Length the firmware reports for the packet (`getRawLength`); equals `raw.count` for a valid decode.
    public var rawLength: Int { 2 + path.bytes.count + payload.count + (transportCodes == nil ? 0 : 4) }

    /// The firmware's `calculatePacketHash`: first 8 bytes of SHA-256 over the payload type byte,
    /// then (TRACE only) the path length as a little-endian `uint16_t`, then the payload.
    ///
    /// The path itself is excluded so a flood packet hashes the same at every hop.
    public var hash: [UInt8] {
        var sha = SHA256()
        sha.update(data: [payloadType.rawValue])
        if payloadType == .trace {
            sha.update(data: [pathLength, 0])
        }
        sha.update(data: payload)
        return Array(sha.finalize().prefix(Self.hashSize))
    }

    /// `hash` as uppercase hex, as printed in the firmware's packet log.
    public var hashHex: String { Data(hash).hexString.uppercased() }

    /// `raw` as uppercase hex.
    public var rawHex: String { raw.hexString.uppercased() }

    /// Destination and source node hashes for requests, responses, text messages and path returns.
    public var addressHashes: (destination: UInt8, source: UInt8)? {
        guard payloadType.hasAddressHashes, payload.count >= 2 else { return nil }
        return (payload[payload.startIndex], payload[payload.startIndex + 1])
    }

    /// First byte of a group text or group data payload: the channel's hash.
    public var channelHash: UInt8? {
        guard payloadType == .groupText || payloadType == .groupData, let first = payload.first else { return nil }
        return first
    }

    /// The decoded advert, when this is an advert packet with at least the fixed fields.
    public var advert: AdvertPayload? {
        payloadType == .advert ? AdvertPayload(payload: payload) : nil
    }
}
