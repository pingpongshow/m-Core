import Foundation

/// A direct message from a contact (`RESP_CODE_CONTACT_MSG_RECV[_V3]`).
public struct ContactMessage: Equatable, Hashable, Sendable {
    public var senderPrefix: KeyPrefix
    public var routing: MessageRouting
    public var textType: TextType
    /// Sender's clock when sent (Unix seconds).
    public var senderTimestamp: UInt32
    /// For signed messages: first 4 bytes of the signer's key.
    public var signerPrefix: [UInt8]?
    public var text: String
    /// Receive SNR in dB (V3 frames only).
    public var snr: Double?

    public init(
        senderPrefix: KeyPrefix,
        routing: MessageRouting,
        textType: TextType = .plain,
        senderTimestamp: UInt32,
        signerPrefix: [UInt8]? = nil,
        text: String,
        snr: Double? = nil
    ) {
        self.senderPrefix = senderPrefix
        self.routing = routing
        self.textType = textType
        self.senderTimestamp = senderTimestamp
        self.signerPrefix = signerPrefix
        self.text = text
        self.snr = snr
    }
}

/// A channel message (`RESP_CODE_CHANNEL_MSG_RECV[_V3]`). The radio prefixes the text with "SenderName: ".
public struct ChannelMessage: Equatable, Hashable, Sendable {
    public var channelIndex: UInt8
    public var routing: MessageRouting
    public var textType: TextType
    public var senderTimestamp: UInt32
    public var text: String
    public var snr: Double?

    public init(
        channelIndex: UInt8,
        routing: MessageRouting,
        textType: TextType = .plain,
        senderTimestamp: UInt32,
        text: String,
        snr: Double? = nil
    ) {
        self.channelIndex = channelIndex
        self.routing = routing
        self.textType = textType
        self.senderTimestamp = senderTimestamp
        self.text = text
        self.snr = snr
    }

    /// Sender name parsed from the "Name: message" convention, if present.
    public var senderName: String? {
        guard let range = text.range(of: ": ") else { return nil }
        return String(text[..<range.lowerBound])
    }

    /// Message body without the sender prefix.
    public var body: String {
        guard let range = text.range(of: ": ") else { return text }
        return String(text[range.upperBound...])
    }
}

/// A binary channel datagram (`RESP_CODE_CHANNEL_DATA_RECV`).
public struct ChannelData: Equatable, Hashable, Sendable {
    public init(snr: Double, channelIndex: UInt8, routing: MessageRouting, dataType: UInt16, payload: Data) {
        self.snr = snr
        self.channelIndex = channelIndex
        self.routing = routing
        self.dataType = dataType
        self.payload = payload
    }

    public var snr: Double
    public var channelIndex: UInt8
    public var routing: MessageRouting
    public var dataType: UInt16
    public var payload: Data
}

/// ACK for a sent message (`PUSH_CODE_SEND_CONFIRMED`).
public struct SendConfirmation: Equatable, Hashable, Sendable {
    public init(ackCode: UInt32, roundTripMs: UInt32) {
        self.ackCode = ackCode
        self.roundTripMs = roundTripMs
    }

    /// Matches `SentInfo.tag` of the sent message.
    public var ackCode: UInt32
    public var roundTripMs: UInt32
}

/// Result of logging in to a repeater or room server.
public struct LoginResult: Equatable, Hashable, Sendable {
    public init(
        senderPrefix: KeyPrefix, permissions: UInt8, serverTimestamp: UInt32? = nil,
        aclPermissions: UInt8? = nil, firmwareLevel: UInt8? = nil
    ) {
        self.senderPrefix = senderPrefix
        self.permissions = permissions
        self.serverTimestamp = serverTimestamp
        self.aclPermissions = aclPermissions
        self.firmwareLevel = firmwareLevel
    }

    public var senderPrefix: KeyPrefix
    /// Bit 0 set = admin.
    public var permissions: UInt8
    public var serverTimestamp: UInt32?
    public var aclPermissions: UInt8?
    public var firmwareLevel: UInt8?

    public var isAdmin: Bool { permissions & 0x01 != 0 }
}

/// Raw reply from a remote node to a status request (`PUSH_CODE_STATUS_RESPONSE`).
public struct StatusResponse: Equatable, Hashable, Sendable {
    public init(senderPrefix: KeyPrefix, payload: Data) {
        self.senderPrefix = senderPrefix
        self.payload = payload
    }

    public var senderPrefix: KeyPrefix
    public var payload: Data
}

/// CayenneLPP telemetry from a node, or from the connected radio itself (`PUSH_CODE_TELEMETRY_RESPONSE`).
public struct TelemetryResponse: Equatable, Hashable, Sendable {
    public init(senderPrefix: KeyPrefix, lpp: Data) {
        self.senderPrefix = senderPrefix
        self.lpp = lpp
    }

    public var senderPrefix: KeyPrefix
    public var lpp: Data
}

/// Reply to a binary or anonymous request (`PUSH_CODE_BINARY_RESPONSE`).
public struct BinaryResponse: Equatable, Hashable, Sendable {
    public init(tag: UInt32, payload: Data) {
        self.tag = tag
        self.payload = payload
    }

    /// Matches `SentInfo.tag` of the request.
    public var tag: UInt32
    public var payload: Data
}

/// Paths learned by a path discovery request (`PUSH_CODE_PATH_DISCOVERY_RESPONSE`).
public struct PathDiscoveryResult: Equatable, Hashable, Sendable {
    public init(senderPrefix: KeyPrefix, outPath: MeshPath?, inPath: MeshPath?) {
        self.senderPrefix = senderPrefix
        self.outPath = outPath
        self.inPath = inPath
    }

    public var senderPrefix: KeyPrefix
    public var outPath: MeshPath?
    public var inPath: MeshPath?
}

/// Result of a trace along a chosen path (`PUSH_CODE_TRACE_DATA`).
public struct TraceResult: Equatable, Hashable, Sendable {
    public init(tag: UInt32, authCode: UInt32, flags: UInt8, pathHashes: [[UInt8]], hopSNRs: [Double], finalSNR: Double) {
        self.tag = tag
        self.authCode = authCode
        self.flags = flags
        self.pathHashes = pathHashes
        self.hopSNRs = hopSNRs
        self.finalSNR = finalSNR
    }

    public var tag: UInt32
    public var authCode: UInt32
    public var flags: UInt8
    public var pathHashes: [[UInt8]]
    /// SNR (dB) measured at each hop.
    public var hopSNRs: [Double]
    /// SNR (dB) of the final hop back to this radio.
    public var finalSNR: Double
}

/// Control or raw-data packet heard by the radio.
public struct RadioPacket: Equatable, Hashable, Sendable {
    public init(snr: Double, rssi: Int8, pathLength: UInt8, payload: Data) {
        self.snr = snr
        self.rssi = rssi
        self.pathLength = pathLength
        self.payload = payload
    }

    public var snr: Double
    public var rssi: Int8
    public var pathLength: UInt8
    public var payload: Data
}

/// Every packet the radio receives, when RX logging is on (`PUSH_CODE_LOG_RX_DATA`).
public struct RxLogEntry: Equatable, Hashable, Sendable {
    public init(snr: Double, rssi: Int8, raw: Data) {
        self.snr = snr
        self.rssi = rssi
        self.raw = raw
    }

    public var snr: Double
    public var rssi: Int8
    public var raw: Data
}
