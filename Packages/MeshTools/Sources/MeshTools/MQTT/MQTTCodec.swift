import Foundation

/// Quality of service for a PUBLISH.
public enum MQTTQoS: UInt8, Sendable, CaseIterable {
    case atMostOnce = 0
    case atLeastOnce = 1
}

/// A message the broker publishes on the client's behalf if the connection drops ("last will").
public struct MQTTWill: Equatable, Sendable {
    public var topic: String
    public var payload: Data
    public var qos: MQTTQoS
    public var retain: Bool

    public init(topic: String, payload: Data, qos: MQTTQoS = .atMostOnce, retain: Bool = false) {
        self.topic = topic
        self.payload = payload
        self.qos = qos
        self.retain = retain
    }
}

/// CONNECT parameters.
public struct MQTTConnectOptions: Equatable, Sendable {
    public var clientID: String
    public var cleanSession: Bool
    /// Seconds; 0 disables keep-alive.
    public var keepAlive: UInt16
    public var username: String?
    public var password: String?
    public var will: MQTTWill?

    public init(
        clientID: String,
        cleanSession: Bool = true,
        keepAlive: UInt16 = 60,
        username: String? = nil,
        password: String? = nil,
        will: MQTTWill? = nil
    ) {
        self.clientID = clientID
        self.cleanSession = cleanSession
        self.keepAlive = keepAlive
        self.username = username
        self.password = password
        self.will = will
    }
}

/// CONNACK return codes other than "accepted" (MQTT 3.1.1 §3.2.2.3).
public enum MQTTConnectRefusal: UInt8, Error, Sendable {
    case unacceptableProtocolVersion = 1
    case identifierRejected = 2
    case serverUnavailable = 3
    case badUsernameOrPassword = 4
    case notAuthorized = 5
}

/// Packets the client understands from the broker.
public enum MQTTInboundPacket: Equatable, Sendable {
    /// `returnCode` 0 means accepted.
    case connack(sessionPresent: Bool, returnCode: UInt8)
    case publish(topic: String, payload: Data, qos: UInt8, packetID: UInt16?, retain: Bool)
    case puback(packetID: UInt16)
    case pingresp
    case other(type: UInt8, flags: UInt8, body: Data)
}

/// Why bytes from the broker couldn't be framed or decoded.
public enum MQTTCodecError: Error, Equatable, Sendable {
    case malformedRemainingLength
    case malformedPacket(type: UInt8)
    case stringTooLong
    case packetTooLarge
}

/// MQTT 3.1.1 packet encoding.
public enum MQTTCodec {
    /// Largest value the 4-byte remaining-length varint can hold.
    public static let maxRemainingLength = 268_435_455

    /// Encodes a remaining length as 1–4 bytes, seven bits each, least significant first.
    public static func encodeRemainingLength(_ length: Int) throws(MQTTCodecError) -> [UInt8] {
        guard (0...maxRemainingLength).contains(length) else { throw .packetTooLarge }
        var value = length
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(value % 128)
            value /= 128
            if value > 0 { byte |= 0x80 }
            bytes.append(byte)
        } while value > 0
        return bytes
    }

    /// Decodes a remaining length starting at `offset`.
    /// Returns nil when more bytes are needed; throws when a fifth length byte would be required.
    public static func decodeRemainingLength(
        _ bytes: [UInt8],
        from offset: Int
    ) throws(MQTTCodecError) -> (value: Int, byteCount: Int)? {
        var value = 0
        var multiplier = 1
        for index in 0..<4 {
            guard offset + index < bytes.count else { return nil }
            let byte = bytes[offset + index]
            value += Int(byte & 0x7F) * multiplier
            if byte & 0x80 == 0 { return (value, index + 1) }
            multiplier *= 128
        }
        throw .malformedRemainingLength
    }

    public static func connect(_ options: MQTTConnectOptions) throws(MQTTCodecError) -> Data {
        var flags: UInt8 = options.cleanSession ? 0x02 : 0
        var payload: [UInt8] = try string(options.clientID)
        if let will = options.will {
            flags |= 0x04 | will.qos.rawValue << 3 | (will.retain ? 0x20 : 0)
            payload += try string(will.topic) + binary(will.payload)
        }
        if let username = options.username {
            flags |= 0x80
            payload += try string(username)
            if let password = options.password {
                flags |= 0x40
                payload += try binary(Data(password.utf8))
            }
        }
        let variableHeader = try string("MQTT") + [0x04, flags, UInt8(options.keepAlive >> 8), UInt8(options.keepAlive & 0xFF)]
        return try packet(type: 1, flags: 0, body: variableHeader + payload)
    }

    public static func publish(
        topic: String,
        payload: Data,
        qos: MQTTQoS,
        retain: Bool,
        packetID: UInt16?,
        duplicate: Bool = false
    ) throws(MQTTCodecError) -> Data {
        var body = try string(topic)
        if qos != .atMostOnce, let packetID {
            body += [UInt8(packetID >> 8), UInt8(packetID & 0xFF)]
        }
        body += payload
        let flags = (duplicate ? 0x08 : 0) | qos.rawValue << 1 | (retain ? 0x01 : 0)
        return try packet(type: 3, flags: flags, body: body)
    }

    public static func puback(packetID: UInt16) -> Data {
        Data([0x40, 0x02, UInt8(packetID >> 8), UInt8(packetID & 0xFF)])
    }

    public static let pingreq = Data([0xC0, 0x00])
    public static let disconnect = Data([0xE0, 0x00])

    static func packet(type: UInt8, flags: UInt8, body: [UInt8]) throws(MQTTCodecError) -> Data {
        Data([type << 4 | flags & 0x0F] + (try encodeRemainingLength(body.count)) + body)
    }

    static func string(_ text: String) throws(MQTTCodecError) -> [UInt8] {
        try binary(Data(text.utf8))
    }

    static func binary(_ data: Data) throws(MQTTCodecError) -> [UInt8] {
        guard data.count <= Int(UInt16.max) else { throw .stringTooLong }
        return [UInt8(data.count >> 8), UInt8(data.count & 0xFF)] + data
    }

    /// Decodes one complete packet given its fixed-header byte and body.
    static func decode(fixedHeader: UInt8, body: [UInt8]) throws(MQTTCodecError) -> MQTTInboundPacket {
        let type = fixedHeader >> 4
        let flags = fixedHeader & 0x0F
        switch type {
        case 2:
            guard body.count == 2 else { throw .malformedPacket(type: type) }
            return .connack(sessionPresent: body[0] & 0x01 != 0, returnCode: body[1])
        case 3:
            return try decodePublish(flags: flags, body: body)
        case 4:
            guard body.count == 2 else { throw .malformedPacket(type: type) }
            return .puback(packetID: UInt16(body[0]) << 8 | UInt16(body[1]))
        case 13:
            return .pingresp
        default:
            return .other(type: type, flags: flags, body: Data(body))
        }
    }

    private static func decodePublish(flags: UInt8, body: [UInt8]) throws(MQTTCodecError) -> MQTTInboundPacket {
        guard body.count >= 2 else { throw .malformedPacket(type: 3) }
        let topicLength = Int(body[0]) << 8 | Int(body[1])
        let qos = (flags >> 1) & 0x03
        var index = 2 + topicLength
        guard body.count >= index else { throw .malformedPacket(type: 3) }
        let topic = String(decoding: body[2..<index], as: UTF8.self)
        var packetID: UInt16?
        if qos > 0 {
            guard body.count >= index + 2 else { throw .malformedPacket(type: 3) }
            packetID = UInt16(body[index]) << 8 | UInt16(body[index + 1])
            index += 2
        }
        return .publish(topic: topic, payload: Data(body[index...]), qos: qos, packetID: packetID, retain: flags & 0x01 != 0)
    }
}

/// Reassembles MQTT packets from a byte stream whose reads may split or merge packets.
public struct MQTTFrameParser: Sendable {
    private var buffer: [UInt8] = []
    /// Packets larger than this are rejected rather than buffered.
    public var maxPacketSize: Int

    public init(maxPacketSize: Int = 1 << 20) {
        self.maxPacketSize = maxPacketSize
    }

    public var bufferedByteCount: Int { buffer.count }

    public mutating func append(_ data: Data) {
        buffer += data
    }

    /// The next complete packet, or nil when more bytes are needed.
    public mutating func next() throws(MQTTCodecError) -> MQTTInboundPacket? {
        guard buffer.count >= 2 else { return nil }
        guard let (length, lengthBytes) = try MQTTCodec.decodeRemainingLength(buffer, from: 1) else { return nil }
        guard length <= maxPacketSize else { throw .packetTooLarge }
        let total = 1 + lengthBytes + length
        guard buffer.count >= total else { return nil }
        let header = buffer[0]
        let body = Array(buffer[(1 + lengthBytes)..<total])
        buffer.removeFirst(total)
        return try MQTTCodec.decode(fixedHeader: header, body: body)
    }

    /// Appends `data` and returns every packet now complete.
    public mutating func feed(_ data: Data) throws(MQTTCodecError) -> [MQTTInboundPacket] {
        append(data)
        var packets: [MQTTInboundPacket] = []
        while let packet = try next() {
            packets.append(packet)
        }
        return packets
    }
}
