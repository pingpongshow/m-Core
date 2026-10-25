import Foundation

/// A frame replying to a command (code below 0x80).
public enum Response: Equatable, Sendable {
    case ok(UInt32?)
    case error(MeshErrorCode?)
    case contactsStart(count: UInt32)
    case contact(Contact)
    case endOfContacts(lastModified: UInt32)
    case selfInfo(SelfInfo)
    case sent(SentInfo)
    case contactMessage(ContactMessage)
    case channelMessage(ChannelMessage)
    case currentTime(UInt32)
    case noMoreMessages
    /// A signed advert packet that another radio can import.
    case exportedContact(Data)
    case batteryAndStorage(BatteryAndStorage)
    case deviceInfo(DeviceInfo)
    case privateKey(Data)
    /// The firmware build has this feature turned off.
    case disabled
    case channelInfo(ChannelInfo)
    case signStart(maxLength: UInt32)
    case signature(Data)
    case customVars([String: String])
    case advertPath(AdvertPath)
    case tuningParams(TuningParams)
    case stats(Stats)
    case autoAddConfig(AutoAddConfig)
    case allowedRepeatFrequencies([FrequencyRange])
    case channelData(ChannelData)
    case defaultFloodScope(FloodScope?)
    case cliReply(String)
    case unknown(code: UInt8, payload: Data)
}

/// An unsolicited frame (code 0x80 and above).
public enum Push: Equatable, Sendable {
    /// A known contact re-advertised.
    case advert(PublicKey)
    case pathUpdated(PublicKey)
    case sendConfirmed(SendConfirmation)
    /// Messages are queued on the radio; fetch them with `syncNextMessage`.
    case messagesWaiting
    case rawData(RadioPacket)
    case loginSuccess(LoginResult)
    case loginFailed(KeyPrefix)
    case statusResponse(StatusResponse)
    case rxLog(RxLogEntry)
    case traceData(TraceResult)
    /// A new node was heard (and auto-added, if enabled).
    case newAdvert(Contact)
    case telemetryResponse(TelemetryResponse)
    case binaryResponse(BinaryResponse)
    case pathDiscoveryResponse(PathDiscoveryResult)
    case controlData(RadioPacket)
    /// The radio overwrote this contact to make room for a new one.
    case contactDeleted(PublicKey)
    case contactsFull
    case unknown(code: UInt8, payload: Data)
}

/// Any frame from the radio.
public enum Frame: Equatable, Sendable {
    case response(Response)
    case push(Push)

    /// Decodes one frame. Unknown codes decode as `.unknown`; optional trailing fields may be absent.
    public static func decode(_ data: Data) throws -> Frame {
        guard let code = data.first else { throw FrameDecodingError.empty }
        var reader = ByteReader(data, code: code, offset: 1)
        if code >= MeshCoreProtocol.firstPushCode {
            guard let pushCode = PushCode(rawValue: code) else {
                return .push(.unknown(code: code, payload: Data(reader.rest())))
            }
            return .push(try decodePush(pushCode, &reader))
        }
        guard let responseCode = ResponseCode(rawValue: code) else {
            return .response(.unknown(code: code, payload: Data(reader.rest())))
        }
        return .response(try decodeResponse(responseCode, &reader))
    }

    // swiftlint:disable:next function_body_length
    private static func decodeResponse(_ code: ResponseCode, _ r: inout ByteReader) throws -> Response {
        switch code {
        case .ok:
            return .ok(r.remaining >= 4 ? try r.u32() : nil)
        case .error:
            return .error(r.isAtEnd ? nil : MeshErrorCode(rawValue: try r.u8()))
        case .contactsStart:
            return .contactsStart(count: try r.u32())
        case .contact:
            return .contact(try decodeContact(&r))
        case .endOfContacts:
            return .endOfContacts(lastModified: r.remaining >= 4 ? try r.u32() : 0)
        case .selfInfo:
            return .selfInfo(try decodeSelfInfo(&r))
        case .sent:
            return .sent(SentInfo(isFlood: try r.u8() == 1, tag: try r.u32(), estimatedTimeoutMs: try r.u32()))
        case .contactMessageV2:
            return .contactMessage(try decodeContactMessage(&r, snr: nil))
        case .contactMessage:
            let snr = Double(try r.i8()) / 4
            _ = try r.bytes(2) // reserved
            return .contactMessage(try decodeContactMessage(&r, snr: snr))
        case .channelMessageV2:
            return .channelMessage(try decodeChannelMessage(&r, snr: nil))
        case .channelMessage:
            let snr = Double(try r.i8()) / 4
            _ = try r.bytes(2)
            return .channelMessage(try decodeChannelMessage(&r, snr: snr))
        case .currentTime:
            return .currentTime(try r.u32())
        case .noMoreMessages:
            return .noMoreMessages
        case .exportContact:
            return .exportedContact(Data(r.rest()))
        case .batteryAndStorage:
            return .batteryAndStorage(BatteryAndStorage(millivolts: try r.u16(), usedKB: try r.u32(), totalKB: try r.u32()))
        case .deviceInfo:
            return .deviceInfo(try decodeDeviceInfo(&r))
        case .privateKey:
            return .privateKey(Data(try r.bytes(64)))
        case .disabled:
            return .disabled
        case .channelInfo:
            return .channelInfo(ChannelInfo(index: try r.u8(), name: try r.fixedString(32), secret: try r.bytes(16)))
        case .signStart:
            _ = try r.u8() // reserved
            return .signStart(maxLength: try r.u32())
        case .signature:
            return .signature(Data(try r.bytes(MeshCoreProtocol.signatureSize)))
        case .customVars:
            return .customVars(parseCustomVars(r.restString()))
        case .advertPath:
            let receivedAt = try r.u32()
            return .advertPath(AdvertPath(receivedAt: receivedAt, path: try decodePath(&r)))
        case .tuningParams:
            return .tuningParams(TuningParams(rxDelayBase: Double(try r.u32()) / 1000, airtimeFactor: Double(try r.u32()) / 1000))
        case .stats:
            return .stats(try decodeStats(&r))
        case .autoAddConfig:
            return .autoAddConfig(AutoAddConfig(flags: try r.u8(), maxHops: r.isAtEnd ? nil : try r.u8()))
        case .allowedRepeatFrequencies:
            var ranges: [FrequencyRange] = []
            while r.remaining >= 8 {
                ranges.append(FrequencyRange(lowerKHz: try r.u32(), upperKHz: try r.u32()))
            }
            return .allowedRepeatFrequencies(ranges)
        case .channelData:
            return .channelData(try decodeChannelData(&r))
        case .defaultFloodScope:
            guard !r.isAtEnd else { return .defaultFloodScope(nil) }
            return .defaultFloodScope(FloodScope(name: try r.fixedString(31), key: try r.bytes(16)))
        case .cliReply:
            return .cliReply(r.restString())
        }
    }

    // swiftlint:disable:next function_body_length
    private static func decodePush(_ code: PushCode, _ r: inout ByteReader) throws -> Push {
        switch code {
        case .advert:
            return .advert(try decodeKey(&r))
        case .pathUpdated:
            return .pathUpdated(try decodeKey(&r))
        case .sendConfirmed:
            return .sendConfirmed(SendConfirmation(ackCode: try r.u32(), roundTripMs: try r.u32()))
        case .messagesWaiting:
            return .messagesWaiting
        case .rawData:
            return .rawData(try decodeRadioPacket(&r))
        case .loginSuccess:
            let permissions = try r.u8()
            let prefix = KeyPrefix(try r.bytes(6))
            let timestamp = r.remaining >= 4 ? try r.u32() : nil
            let acl = r.isAtEnd ? nil : try r.u8()
            let level = r.isAtEnd ? nil : try r.u8()
            return .loginSuccess(LoginResult(
                senderPrefix: prefix, permissions: permissions, serverTimestamp: timestamp,
                aclPermissions: acl, firmwareLevel: level
            ))
        case .loginFailed:
            _ = try r.u8()
            return .loginFailed(KeyPrefix(try r.bytes(6)))
        case .statusResponse:
            _ = try r.u8()
            return .statusResponse(StatusResponse(senderPrefix: KeyPrefix(try r.bytes(6)), payload: Data(r.rest())))
        case .rxLog:
            return .rxLog(RxLogEntry(snr: Double(try r.i8()) / 4, rssi: try r.i8(), raw: Data(r.rest())))
        case .traceData:
            return .traceData(try decodeTrace(&r))
        case .newAdvert:
            return .newAdvert(try decodeContact(&r))
        case .telemetryResponse:
            _ = try r.u8()
            return .telemetryResponse(TelemetryResponse(senderPrefix: KeyPrefix(try r.bytes(6)), lpp: Data(r.rest())))
        case .binaryResponse:
            _ = try r.u8()
            return .binaryResponse(BinaryResponse(tag: try r.u32(), payload: Data(r.rest())))
        case .pathDiscoveryResponse:
            _ = try r.u8()
            let prefix = KeyPrefix(try r.bytes(6))
            let outPath = try decodePath(&r)
            let inPath = try decodePath(&r)
            return .pathDiscoveryResponse(PathDiscoveryResult(senderPrefix: prefix, outPath: outPath, inPath: inPath))
        case .controlData:
            return .controlData(try decodeRadioPacket(&r))
        case .contactDeleted:
            return .contactDeleted(try decodeKey(&r))
        case .contactsFull:
            return .contactsFull
        }
    }
}
