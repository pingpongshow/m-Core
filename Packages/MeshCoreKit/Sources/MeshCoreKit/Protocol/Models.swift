import Foundation

/// A node's 32-byte Ed25519 public key; its identity on the mesh.
public struct PublicKey: Hashable, Sendable, CustomStringConvertible {
    public let bytes: [UInt8]

    public init?(bytes: [UInt8]) {
        guard bytes.count == MeshCoreProtocol.publicKeySize else { return nil }
        self.bytes = bytes
    }

    public init?(hex: String) {
        guard let data = Data(hexString: hex) else { return nil }
        self.init(bytes: [UInt8](data))
    }

    public var hex: String { Data(bytes).hexString }
    /// The 6-byte prefix the protocol uses to address messages.
    public var prefix: KeyPrefix { KeyPrefix(Array(bytes.prefix(MeshCoreProtocol.keyPrefixSize))) }
    public var description: String { hex }
}

/// First 6 bytes of a public key, as carried in message frames.
public struct KeyPrefix: Hashable, Sendable, CustomStringConvertible {
    public let bytes: [UInt8]

    public init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    public var hex: String { Data(bytes).hexString }
    public var description: String { hex }

    public func matches(_ key: PublicKey) -> Bool {
        key.bytes.starts(with: bytes)
    }
}

/// A route through repeaters: each hop is identified by a 1–3 byte hash of its public key.
public struct MeshPath: Equatable, Hashable, Sendable {
    public let hashSize: Int
    public let hashes: [[UInt8]]

    public init(hashSize: Int, hashes: [[UInt8]]) {
        precondition((1...3).contains(hashSize), "hash size must be 1–3 bytes")
        precondition(hashes.allSatisfy { $0.count == hashSize }, "every hash must be hashSize bytes")
        precondition(hashes.count <= 63, "at most 63 hops")
        self.hashSize = hashSize
        self.hashes = hashes
    }

    public static let empty = MeshPath(hashSize: 1, hashes: [])

    /// The protocol's path-length byte: hash size − 1 in the top two bits, hop count in the low six.
    public var encodedLength: UInt8 { UInt8((hashSize - 1) << 6 | hashes.count) }
    public var bytes: [UInt8] { hashes.flatMap { $0 } }

    /// Byte length of the path described by an encoded length, or nil if the encoding is invalid.
    public static func byteCount(forEncodedLength length: UInt8) -> Int? {
        let hashSize = Int(length >> 6) + 1
        let count = Int(length & 63)
        guard hashSize <= 3, hashSize * count <= MeshCoreProtocol.maxPathSize else { return nil }
        return hashSize * count
    }

    /// Builds a path from its encoded length and at least that many bytes.
    public init?(encodedLength length: UInt8, bytes: [UInt8]) {
        guard let byteCount = Self.byteCount(forEncodedLength: length), bytes.count >= byteCount else { return nil }
        let hashSize = Int(length >> 6) + 1
        let used = Array(bytes.prefix(byteCount))
        self.init(hashSize: hashSize, hashes: stride(from: 0, to: byteCount, by: hashSize).map {
            Array(used[$0..<$0 + hashSize])
        })
    }

    /// Value of `out_path_len` when the radio has no direct path and floods instead.
    static let unknownLength: UInt8 = 0xFF
}

/// How a received message travelled.
public enum MessageRouting: Equatable, Hashable, Sendable {
    /// Delivered along a known direct path.
    case direct
    /// Flooded; `hops` repeaters relayed it.
    case flood(hops: Int)

    init(pathLength: UInt8) {
        self = pathLength == 0xFF ? .direct : .flood(hops: Int(pathLength & 63))
    }

    var pathLength: UInt8 {
        switch self {
        case .direct: 0xFF
        case .flood(let hops): UInt8(hops & 63)
        }
    }
}

/// A contact stored on the radio (`ContactInfo`).
public struct Contact: Equatable, Hashable, Sendable {
    public var publicKey: PublicKey
    public var type: AdvertType
    /// Bit 0 is "favourite"; the upper bits grant telemetry permissions.
    public var flags: UInt8
    /// Known direct path, or nil when the radio floods to this contact.
    public var outPath: MeshPath?
    public var name: String
    /// Sender's clock at its last advert (Unix seconds).
    public var lastAdvert: UInt32
    public var latitudeE6: Int32
    public var longitudeE6: Int32
    /// Radio's clock when this record last changed; used for incremental sync.
    public var lastModified: UInt32

    public init(
        publicKey: PublicKey,
        type: AdvertType,
        flags: UInt8 = 0,
        outPath: MeshPath? = nil,
        name: String,
        lastAdvert: UInt32 = 0,
        latitudeE6: Int32 = 0,
        longitudeE6: Int32 = 0,
        lastModified: UInt32 = 0
    ) {
        self.publicKey = publicKey
        self.type = type
        self.flags = flags
        self.outPath = outPath
        self.name = name
        self.lastAdvert = lastAdvert
        self.latitudeE6 = latitudeE6
        self.longitudeE6 = longitudeE6
        self.lastModified = lastModified
    }

    public var isFavourite: Bool { flags & 0x01 != 0 }
    public var latitude: Double { Double(latitudeE6) / 1e6 }
    public var longitude: Double { Double(longitudeE6) / 1e6 }
    public var hasLocation: Bool { latitudeE6 != 0 || longitudeE6 != 0 }
}

/// How the radio answers telemetry requests for one category (`TELEM_MODE_*`).
public enum TelemetryMode: UInt8, Sendable, CaseIterable {
    case deny = 0
    /// Allowed only for contacts whose flags grant it.
    case allowFlagged = 1
    case allowAll = 2
}

/// Telemetry permissions for base (battery), location and environment data, packed into one byte.
public struct TelemetryModes: Equatable, Hashable, Sendable {
    public var base: TelemetryMode
    public var location: TelemetryMode
    public var environment: TelemetryMode

    public init(base: TelemetryMode, location: TelemetryMode, environment: TelemetryMode) {
        self.base = base
        self.location = location
        self.environment = environment
    }

    public init(byte: UInt8) {
        base = TelemetryMode(rawValue: byte & 0x03) ?? .deny
        location = TelemetryMode(rawValue: (byte >> 2) & 0x03) ?? .deny
        environment = TelemetryMode(rawValue: (byte >> 4) & 0x03) ?? .deny
    }

    public var byte: UInt8 { environment.rawValue << 4 | location.rawValue << 2 | base.rawValue }
}

/// LoRa settings.
public struct RadioParameters: Equatable, Hashable, Sendable {
    public var frequencyKHz: UInt32
    public var bandwidthHz: UInt32
    public var spreadingFactor: UInt8
    public var codingRate: UInt8

    public init(frequencyKHz: UInt32, bandwidthHz: UInt32, spreadingFactor: UInt8, codingRate: UInt8) {
        self.frequencyKHz = frequencyKHz
        self.bandwidthHz = bandwidthHz
        self.spreadingFactor = spreadingFactor
        self.codingRate = codingRate
    }

    public var frequencyMHz: Double { Double(frequencyKHz) / 1000 }
    public var bandwidthKHz: Double { Double(bandwidthHz) / 1000 }
}

/// The connected radio's own identity and settings (`RESP_CODE_SELF_INFO`, reply to app start).
public struct SelfInfo: Equatable, Hashable, Sendable {
    public var advertType: AdvertType
    public var txPowerDbm: Int8
    public var maxTxPowerDbm: Int8
    public var publicKey: PublicKey
    public var latitudeE6: Int32
    public var longitudeE6: Int32
    public var multiAcks: UInt8
    /// 0 = don't share location in adverts, 1 = share.
    public var advertLocationPolicy: UInt8
    public var telemetryModes: TelemetryModes
    public var manualAddContacts: UInt8
    public var radio: RadioParameters
    public var name: String

    public var latitude: Double { Double(latitudeE6) / 1e6 }
    public var longitude: Double { Double(longitudeE6) / 1e6 }
    public var sharesLocationInAdverts: Bool { advertLocationPolicy != 0 }
}

/// Firmware and hardware details (`RESP_CODE_DEVICE_INFO`). Fields after the version need protocol v3+.
public struct DeviceInfo: Equatable, Hashable, Sendable {
    public var protocolVersion: UInt8
    public var maxContacts: Int?
    public var maxChannels: Int?
    public var blePin: UInt32?
    public var buildDate: String?
    public var model: String?
    public var firmwareVersion: String?
    /// v9+: whether the companion repeats packets ("client repeat").
    public var clientRepeat: Bool?
    /// v10+: path hash size mode (0 = 1-byte hashes).
    public var pathHashMode: UInt8?

    public init(
        protocolVersion: UInt8,
        maxContacts: Int? = nil,
        maxChannels: Int? = nil,
        blePin: UInt32? = nil,
        buildDate: String? = nil,
        model: String? = nil,
        firmwareVersion: String? = nil,
        clientRepeat: Bool? = nil,
        pathHashMode: UInt8? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.maxContacts = maxContacts
        self.maxChannels = maxChannels
        self.blePin = blePin
        self.buildDate = buildDate
        self.model = model
        self.firmwareVersion = firmwareVersion
        self.clientRepeat = clientRepeat
        self.pathHashMode = pathHashMode
    }
}

/// A channel slot (`RESP_CODE_CHANNEL_INFO`). Slot 0 is the built-in Public channel.
public struct ChannelInfo: Equatable, Hashable, Sendable {
    public var index: UInt8
    public var name: String
    /// 16-byte shared secret.
    public var secret: [UInt8]

    public init(index: UInt8, name: String, secret: [UInt8]) {
        self.index = index
        self.name = name
        self.secret = secret
    }
}

/// Acknowledgement that a message or request was queued (`RESP_CODE_SENT`).
public struct SentInfo: Equatable, Hashable, Sendable {
    public var isFlood: Bool
    /// Expected ACK code (messages) or request tag (requests).
    public var tag: UInt32
    public var estimatedTimeoutMs: UInt32
}

public struct BatteryAndStorage: Equatable, Hashable, Sendable {
    public var millivolts: UInt16
    public var usedKB: UInt32
    public var totalKB: UInt32
}

public struct CoreStats: Equatable, Hashable, Sendable {
    public var batteryMillivolts: UInt16
    public var uptimeSeconds: UInt32
    public var errorFlags: UInt16
    public var outboundQueueLength: UInt8
}

public struct RadioStats: Equatable, Hashable, Sendable {
    public var noiseFloorDbm: Int16
    public var lastRSSI: Int8
    /// dB, 0.25 dB precision.
    public var lastSNR: Double
    public var txAirtimeSeconds: UInt32
    public var rxAirtimeSeconds: UInt32
}

public struct PacketStats: Equatable, Hashable, Sendable {
    public var received: UInt32
    public var sent: UInt32
    public var sentFlood: UInt32
    public var sentDirect: UInt32
    public var receivedFlood: UInt32
    public var receivedDirect: UInt32
    public var receiveErrors: UInt32
}

public enum Stats: Equatable, Hashable, Sendable {
    case core(CoreStats)
    case radio(RadioStats)
    case packets(PacketStats)
    case unknown(type: UInt8, payload: Data)
}

public struct TuningParams: Equatable, Hashable, Sendable {
    /// Sent over the wire ×1000.
    public var rxDelayBase: Double
    public var airtimeFactor: Double

    public init(rxDelayBase: Double, airtimeFactor: Double) {
        self.rxDelayBase = rxDelayBase
        self.airtimeFactor = airtimeFactor
    }
}

/// Which advert types the radio adds as contacts automatically.
public struct AutoAddConfig: Equatable, Hashable, Sendable {
    public static let overwriteOldest: UInt8 = 0x01
    public static let chat: UInt8 = 0x02
    public static let repeater: UInt8 = 0x04
    public static let room: UInt8 = 0x08
    public static let sensor: UInt8 = 0x10

    public var flags: UInt8
    /// 0 = no limit; N = up to N−1 hops.
    public var maxHops: UInt8?

    public init(flags: UInt8, maxHops: UInt8? = nil) {
        self.flags = flags
        self.maxHops = maxHops
    }
}

/// The path an advert from a node arrived on (`RESP_CODE_ADVERT_PATH`).
public struct AdvertPath: Equatable, Hashable, Sendable {
    public var receivedAt: UInt32
    public var path: MeshPath?
}

/// Settings written together by `CMD_SET_OTHER_PARAMS`. Read the current values from `SelfInfo` first.
public struct OtherParams: Equatable, Hashable, Sendable {
    public var manualAddContacts: UInt8
    public var telemetryModes: TelemetryModes
    public var advertLocationPolicy: UInt8
    public var multiAcks: UInt8

    public init(manualAddContacts: UInt8, telemetryModes: TelemetryModes, advertLocationPolicy: UInt8, multiAcks: UInt8) {
        self.manualAddContacts = manualAddContacts
        self.telemetryModes = telemetryModes
        self.advertLocationPolicy = advertLocationPolicy
        self.multiAcks = multiAcks
    }

    public init(from selfInfo: SelfInfo) {
        self.init(
            manualAddContacts: selfInfo.manualAddContacts,
            telemetryModes: selfInfo.telemetryModes,
            advertLocationPolicy: selfInfo.advertLocationPolicy,
            multiAcks: selfInfo.multiAcks
        )
    }
}

public struct FloodScope: Equatable, Hashable, Sendable {
    public var name: String
    /// 16-byte transport key.
    public var key: [UInt8]

    public init(name: String, key: [UInt8]) {
        self.name = name
        self.key = key
    }
}

public struct FrequencyRange: Equatable, Hashable, Sendable {
    public var lowerKHz: UInt32
    public var upperKHz: UInt32
}
