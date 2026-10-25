import Foundation

// Decoders for fields shared by several frame types.
extension Frame {

    static func decodeKey(_ r: inout ByteReader) throws -> PublicKey {
        // PublicKey(bytes:) only fails on a wrong length, which bytes(32) rules out.
        PublicKey(bytes: try r.bytes(MeshCoreProtocol.publicKeySize))!
    }

    /// A length byte followed by that many path bytes; nil for an unknown (flood) path.
    static func decodePath(_ r: inout ByteReader) throws -> MeshPath? {
        let length = try r.u8()
        guard let count = MeshPath.byteCount(forEncodedLength: length) else { return nil }
        return MeshPath(encodedLength: length, bytes: try r.bytes(count))
    }

    static func decodeContact(_ r: inout ByteReader) throws -> Contact {
        let key = try decodeKey(&r)
        let type = AdvertType(rawValue: try r.u8())
        let flags = try r.u8()
        let pathLength = try r.u8()
        let pathBytes = try r.bytes(MeshCoreProtocol.maxPathSize)
        let name = try r.fixedString(32)
        let lastAdvert = try r.u32()
        let latitude = r.remaining >= 8 ? try r.i32() : 0
        let longitude = r.remaining >= 4 ? try r.i32() : 0
        let lastModified = r.remaining >= 4 ? try r.u32() : 0
        return Contact(
            publicKey: key, type: type, flags: flags,
            outPath: MeshPath(encodedLength: pathLength, bytes: pathBytes),
            name: name, lastAdvert: lastAdvert,
            latitudeE6: latitude, longitudeE6: longitude, lastModified: lastModified
        )
    }

    static func decodeSelfInfo(_ r: inout ByteReader) throws -> SelfInfo {
        SelfInfo(
            advertType: AdvertType(rawValue: try r.u8()),
            txPowerDbm: try r.i8(),
            maxTxPowerDbm: try r.i8(),
            publicKey: try decodeKey(&r),
            latitudeE6: try r.i32(),
            longitudeE6: try r.i32(),
            multiAcks: try r.u8(),
            advertLocationPolicy: try r.u8(),
            telemetryModes: TelemetryModes(byte: try r.u8()),
            manualAddContacts: try r.u8(),
            radio: RadioParameters(
                frequencyKHz: try r.u32(), bandwidthHz: try r.u32(),
                spreadingFactor: try r.u8(), codingRate: try r.u8()
            ),
            name: r.restString()
        )
    }

    static func decodeDeviceInfo(_ r: inout ByteReader) throws -> DeviceInfo {
        var info = DeviceInfo(protocolVersion: try r.u8())
        guard r.remaining >= 2 + 4 + 12 + 40 + 20 else { return info }
        info.maxContacts = Int(try r.u8()) * 2
        info.maxChannels = Int(try r.u8())
        info.blePin = try r.u32()
        info.buildDate = try r.fixedString(12)
        info.model = try r.fixedString(40)
        info.firmwareVersion = try r.fixedString(20)
        if !r.isAtEnd { info.clientRepeat = try r.u8() != 0 }
        if !r.isAtEnd { info.pathHashMode = try r.u8() }
        return info
    }

    static func decodeContactMessage(_ r: inout ByteReader, snr: Double?) throws -> ContactMessage {
        let prefix = KeyPrefix(try r.bytes(6))
        let routing = MessageRouting(pathLength: try r.u8())
        let textType = TextType(rawValue: try r.u8())
        let timestamp = try r.u32()
        let signer = textType == .signedPlain ? try r.bytes(4) : nil
        return ContactMessage(
            senderPrefix: prefix, routing: routing, textType: textType, senderTimestamp: timestamp,
            signerPrefix: signer, text: r.restString(), snr: snr
        )
    }

    static func decodeChannelMessage(_ r: inout ByteReader, snr: Double?) throws -> ChannelMessage {
        ChannelMessage(
            channelIndex: try r.u8(),
            routing: MessageRouting(pathLength: try r.u8()),
            textType: TextType(rawValue: try r.u8()),
            senderTimestamp: try r.u32(),
            text: r.restString(),
            snr: snr
        )
    }

    static func decodeChannelData(_ r: inout ByteReader) throws -> ChannelData {
        let snr = Double(try r.i8()) / 4
        _ = try r.bytes(2)
        let index = try r.u8()
        let routing = MessageRouting(pathLength: try r.u8())
        let dataType = try r.u16()
        let length = Int(try r.u8())
        return ChannelData(snr: snr, channelIndex: index, routing: routing, dataType: dataType, payload: Data(try r.bytes(length)))
    }

    static func decodeStats(_ r: inout ByteReader) throws -> Stats {
        let rawType = try r.u8()
        switch StatsType(rawValue: rawType) {
        case .core:
            return .core(CoreStats(
                batteryMillivolts: try r.u16(), uptimeSeconds: try r.u32(),
                errorFlags: try r.u16(), outboundQueueLength: try r.u8()
            ))
        case .radio:
            return .radio(RadioStats(
                noiseFloorDbm: try r.i16(), lastRSSI: try r.i8(), lastSNR: Double(try r.i8()) / 4,
                txAirtimeSeconds: try r.u32(), rxAirtimeSeconds: try r.u32()
            ))
        case .packets:
            return .packets(PacketStats(
                received: try r.u32(), sent: try r.u32(), sentFlood: try r.u32(), sentDirect: try r.u32(),
                receivedFlood: try r.u32(), receivedDirect: try r.u32(), receiveErrors: try r.u32()
            ))
        case nil:
            return .unknown(type: rawType, payload: Data(r.rest()))
        }
    }

    static func decodeRadioPacket(_ r: inout ByteReader) throws -> RadioPacket {
        RadioPacket(snr: Double(try r.i8()) / 4, rssi: try r.i8(), pathLength: try r.u8(), payload: Data(r.rest()))
    }

    static func decodeTrace(_ r: inout ByteReader) throws -> TraceResult {
        _ = try r.u8() // reserved
        let pathLength = Int(try r.u8())
        let flags = try r.u8()
        let tag = try r.u32()
        let auth = try r.u32()
        let hashSize = 1 << Int(flags & 0x03)
        let hashBytes = try r.bytes(pathLength)
        let hops = pathLength >> Int(flags & 0x03)
        let snrs = try r.bytes(hops).map { Double(Int8(bitPattern: $0)) / 4 }
        let finalSNR = Double(try r.i8()) / 4
        let hashes = stride(from: 0, to: hashBytes.count, by: hashSize).map {
            Array(hashBytes[$0..<min($0 + hashSize, hashBytes.count)])
        }
        return TraceResult(tag: tag, authCode: auth, flags: flags, pathHashes: hashes, hopSNRs: snrs, finalSNR: finalSNR)
    }

    /// Parses "name:value,name:value".
    static func parseCustomVars(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in text.split(separator: ",") {
            guard let colon = pair.firstIndex(of: ":") else { continue }
            result[String(pair[..<colon])] = String(pair[pair.index(after: colon)...])
        }
        return result
    }
}
