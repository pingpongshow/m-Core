import Foundation

/// Builds radio → app frames, mirroring the firmware's writers. Used by `MockRadio` and round-trip tests;
/// covers the frames a simulated radio needs, not every response type.
public enum RadioFrameEncoder {
    public static func encode(_ response: Response) -> Data? {
        switch response {
        case .contact(let contact):
            return encodeContact(contact, code: ResponseCode.contact.rawValue)
        case .selfInfo(let info):
            return encodeSelfInfo(info)
        case .deviceInfo(let info):
            return encodeDeviceInfo(info)
        case .contactMessage(let message):
            return encodeContactMessage(message)
        case .channelMessage(let message):
            return encodeChannelMessage(message)
        case .channelData(let data):
            return encodeChannelData(data)
        case .advertPath(let advertPath):
            var w = ByteWriter(code: ResponseCode.advertPath.rawValue)
            w.u32(advertPath.receivedAt)
            w.u8(advertPath.path?.encodedLength ?? MeshPath.unknownLength)
            w.append(advertPath.path?.bytes ?? [])
            return w.data
        case .defaultFloodScope(let scope):
            var w = ByteWriter(code: ResponseCode.defaultFloodScope.rawValue)
            if let scope {
                w.fixedString(scope.name, width: 31)
                w.append(scope.key)
            }
            return w.data
        default:
            return encodeScalar(response) ?? encodeSettings(response)
        }
    }

    /// Responses made of a few fixed fields.
    private static func encodeScalar(_ response: Response) -> Data? {
        switch response {
        case .ok(let value):
            var w = ByteWriter(code: ResponseCode.ok.rawValue)
            if let value { w.u32(value) }
            return w.data
        case .error(let code):
            var w = ByteWriter(code: ResponseCode.error.rawValue)
            if let code { w.u8(code.rawValue) }
            return w.data
        case .contactsStart(let count):
            var w = ByteWriter(code: ResponseCode.contactsStart.rawValue)
            w.u32(count)
            return w.data
        case .endOfContacts(let lastModified):
            var w = ByteWriter(code: ResponseCode.endOfContacts.rawValue)
            w.u32(lastModified)
            return w.data
        case .sent(let info):
            var w = ByteWriter(code: ResponseCode.sent.rawValue)
            w.u8(info.isFlood ? 1 : 0)
            w.u32(info.tag)
            w.u32(info.estimatedTimeoutMs)
            return w.data
        case .currentTime(let time):
            var w = ByteWriter(code: ResponseCode.currentTime.rawValue)
            w.u32(time)
            return w.data
        case .noMoreMessages:
            return Data([ResponseCode.noMoreMessages.rawValue])
        case .batteryAndStorage(let value):
            var w = ByteWriter(code: ResponseCode.batteryAndStorage.rawValue)
            w.u16(value.millivolts)
            w.u32(value.usedKB)
            w.u32(value.totalKB)
            return w.data
        case .customVars(let vars):
            var w = ByteWriter(code: ResponseCode.customVars.rawValue)
            w.text(vars.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ","))
            return w.data
        case .cliReply(let text):
            var w = ByteWriter(code: ResponseCode.cliReply.rawValue)
            w.text(text)
            return w.data
        default:
            return nil
        }
    }

    /// Stats, settings, key and signing responses.
    private static func encodeSettings(_ response: Response) -> Data? {
        switch response {
        case .stats(let stats):
            return encodeStats(stats)
        case .tuningParams(let params):
            var w = ByteWriter(code: ResponseCode.tuningParams.rawValue)
            w.u32(ByteWriter.thousandths(params.rxDelayBase))
            w.u32(ByteWriter.thousandths(params.airtimeFactor))
            return w.data
        case .autoAddConfig(let config):
            var w = ByteWriter(code: ResponseCode.autoAddConfig.rawValue)
            w.u8(config.flags)
            if let hops = config.maxHops { w.u8(hops) }
            return w.data
        case .allowedRepeatFrequencies(let ranges):
            var w = ByteWriter(code: ResponseCode.allowedRepeatFrequencies.rawValue)
            for range in ranges {
                w.u32(range.lowerKHz)
                w.u32(range.upperKHz)
            }
            return w.data
        case .privateKey(let key):
            return Data([ResponseCode.privateKey.rawValue]) + key
        case .disabled:
            return Data([ResponseCode.disabled.rawValue])
        case .signStart(let maxLength):
            var w = ByteWriter(code: ResponseCode.signStart.rawValue)
            w.u8(0)
            w.u32(maxLength)
            return w.data
        case .signature(let signature):
            return Data([ResponseCode.signature.rawValue]) + signature
        case .exportedContact(let packet):
            return Data([ResponseCode.exportContact.rawValue]) + packet
        case .channelInfo(let channel):
            var w = ByteWriter(code: ResponseCode.channelInfo.rawValue)
            w.u8(channel.index)
            w.fixedString(channel.name, width: 32)
            w.append(channel.secret)
            return w.data
        default:
            return nil
        }
    }

    public static func encode(_ push: Push) -> Data? {
        switch push {
        case .messagesWaiting:
            return Data([PushCode.messagesWaiting.rawValue])
        case .contactsFull:
            return Data([PushCode.contactsFull.rawValue])
        case .advert(let key):
            return Data([PushCode.advert.rawValue] + key.bytes)
        case .pathUpdated(let key):
            return Data([PushCode.pathUpdated.rawValue] + key.bytes)
        case .contactDeleted(let key):
            return Data([PushCode.contactDeleted.rawValue] + key.bytes)
        case .newAdvert(let contact):
            return encodeContact(contact, code: PushCode.newAdvert.rawValue)
        case .loginSuccess(let result):
            return encodeLoginSuccess(result)
        case .loginFailed(let prefix):
            return Data([PushCode.loginFailed.rawValue, 0] + prefix.bytes)
        case .telemetryResponse(let response):
            return Data([PushCode.telemetryResponse.rawValue, 0] + response.senderPrefix.bytes) + response.lpp
        case .statusResponse(let response):
            return Data([PushCode.statusResponse.rawValue, 0] + response.senderPrefix.bytes) + response.payload
        case .pathDiscoveryResponse(let result):
            return encodePathDiscovery(result)
        case .traceData(let trace):
            return encodeTrace(trace)
        case .rxLog(let entry):
            var w = ByteWriter(code: PushCode.rxLog.rawValue)
            w.i8(Int8(clamping: Int((entry.snr * 4).rounded())))
            w.i8(entry.rssi)
            w.append(entry.raw)
            return w.data
        case .binaryResponse(let response):
            var w = ByteWriter(code: PushCode.binaryResponse.rawValue)
            w.u8(0)
            w.u32(response.tag)
            w.append(response.payload)
            return w.data
        case .rawData(let packet):
            return encodeRadioPacket(packet, code: PushCode.rawData.rawValue)
        case .controlData(let packet):
            return encodeRadioPacket(packet, code: PushCode.controlData.rawValue)
        case .sendConfirmed(let confirmation):
            var w = ByteWriter(code: PushCode.sendConfirmed.rawValue)
            w.u32(confirmation.ackCode)
            w.u32(confirmation.roundTripMs)
            return w.data
        default:
            return nil
        }
    }
}

// MARK: Frame bodies

extension RadioFrameEncoder {
    private static func encodeStats(_ stats: Stats) -> Data {
        var w = ByteWriter(code: ResponseCode.stats.rawValue)
        switch stats {
        case .core(let core):
            w.u8(StatsType.core.rawValue)
            w.u16(core.batteryMillivolts)
            w.u32(core.uptimeSeconds)
            w.u16(core.errorFlags)
            w.u8(core.outboundQueueLength)
        case .radio(let radio):
            w.u8(StatsType.radio.rawValue)
            w.u16(UInt16(bitPattern: radio.noiseFloorDbm))
            w.i8(radio.lastRSSI)
            w.i8(Int8(clamping: Int((radio.lastSNR * 4).rounded())))
            w.u32(radio.txAirtimeSeconds)
            w.u32(radio.rxAirtimeSeconds)
        case .packets(let packets):
            w.u8(StatsType.packets.rawValue)
            for value in [packets.received, packets.sent, packets.sentFlood, packets.sentDirect,
                          packets.receivedFlood, packets.receivedDirect, packets.receiveErrors] {
                w.u32(value)
            }
        case .unknown(let type, let payload):
            w.u8(type)
            w.append(payload)
        }
        return w.data
    }

    private static func encodeLoginSuccess(_ result: LoginResult) -> Data {
        var w = ByteWriter(code: PushCode.loginSuccess.rawValue)
        w.u8(result.permissions)
        w.append(result.senderPrefix.bytes)
        if let timestamp = result.serverTimestamp {
            w.u32(timestamp)
            w.u8(result.aclPermissions ?? 0)
            w.u8(result.firmwareLevel ?? 0)
        }
        return w.data
    }

    private static func encodePathDiscovery(_ result: PathDiscoveryResult) -> Data {
        var w = ByteWriter(code: PushCode.pathDiscoveryResponse.rawValue)
        w.u8(0)
        w.append(result.senderPrefix.bytes)
        for path in [result.outPath, result.inPath] {
            w.u8(path?.encodedLength ?? MeshPath.unknownLength)
            w.append(path?.bytes ?? [])
        }
        return w.data
    }

    private static func encodeTrace(_ trace: TraceResult) -> Data {
        var w = ByteWriter(code: PushCode.traceData.rawValue)
        let hashBytes = trace.pathHashes.flatMap { $0 }
        w.u8(0)
        w.u8(UInt8(hashBytes.count))
        w.u8(trace.flags)
        w.u32(trace.tag)
        w.u32(trace.authCode)
        w.append(hashBytes)
        w.append(trace.hopSNRs.map { UInt8(bitPattern: Int8(clamping: Int(($0 * 4).rounded()))) })
        w.i8(Int8(clamping: Int((trace.finalSNR * 4).rounded())))
        return w.data
    }

    private static func encodeContact(_ contact: Contact, code: UInt8) -> Data {
        var w = ByteWriter(code: code)
        w.append(contact.publicKey.bytes)
        w.u8(contact.type.rawValue)
        w.u8(contact.flags)
        w.u8(contact.outPath?.encodedLength ?? MeshPath.unknownLength)
        let path = contact.outPath?.bytes ?? []
        w.append(path + [UInt8](repeating: 0, count: MeshCoreProtocol.maxPathSize - path.count))
        w.fixedString(contact.name, width: 32)
        w.u32(contact.lastAdvert)
        w.i32(contact.latitudeE6)
        w.i32(contact.longitudeE6)
        w.u32(contact.lastModified)
        return w.data
    }

    private static func encodeSelfInfo(_ info: SelfInfo) -> Data {
        var w = ByteWriter(code: ResponseCode.selfInfo.rawValue)
        w.u8(info.advertType.rawValue)
        w.i8(info.txPowerDbm)
        w.i8(info.maxTxPowerDbm)
        w.append(info.publicKey.bytes)
        w.i32(info.latitudeE6)
        w.i32(info.longitudeE6)
        w.u8(info.multiAcks)
        w.u8(info.advertLocationPolicy)
        w.u8(info.telemetryModes.byte)
        w.u8(info.manualAddContacts)
        w.u32(info.radio.frequencyKHz)
        w.u32(info.radio.bandwidthHz)
        w.u8(info.radio.spreadingFactor)
        w.u8(info.radio.codingRate)
        w.text(info.name)
        return w.data
    }

    private static func encodeDeviceInfo(_ info: DeviceInfo) -> Data {
        var w = ByteWriter(code: ResponseCode.deviceInfo.rawValue)
        w.u8(info.protocolVersion)
        guard let maxContacts = info.maxContacts else { return w.data }
        w.u8(UInt8(clamping: maxContacts / 2))
        w.u8(UInt8(clamping: info.maxChannels ?? 0))
        w.u32(info.blePin ?? 0)
        w.fixedString(info.buildDate ?? "", width: 12)
        w.fixedString(info.model ?? "", width: 40)
        w.fixedString(info.firmwareVersion ?? "", width: 20)
        if let clientRepeat = info.clientRepeat {
            w.u8(clientRepeat ? 1 : 0)
            if let mode = info.pathHashMode { w.u8(mode) }
        }
        return w.data
    }

    /// `onChannelDataRecv`: SNR×4, two reserved bytes, channel, path length, data type (LE), length, data.
    private static func encodeChannelData(_ data: ChannelData) -> Data {
        var w = ByteWriter(code: ResponseCode.channelData.rawValue)
        w.i8(Int8(clamping: Int((data.snr * 4).rounded())))
        w.append([0, 0])
        w.u8(data.channelIndex)
        w.u8(data.routing.pathLength)
        w.u16(data.dataType)
        w.u8(UInt8(clamping: data.payload.count))
        w.append(data.payload.prefix(Int(UInt8.max)))
        return w.data
    }

    /// `onRawDataRecv` / `onControlDataRecv`: SNR×4, RSSI, path length, payload.
    private static func encodeRadioPacket(_ packet: RadioPacket, code: UInt8) -> Data {
        var w = ByteWriter(code: code)
        w.i8(Int8(clamping: Int((packet.snr * 4).rounded())))
        w.i8(packet.rssi)
        w.u8(packet.pathLength)
        w.append(packet.payload)
        return w.data
    }

    private static func encodeChannelMessage(_ message: ChannelMessage) -> Data {
        var w = ByteWriter(code: ResponseCode.channelMessage.rawValue)
        w.i8(Int8(clamping: Int(((message.snr ?? 0) * 4).rounded())))
        w.append([0, 0])
        w.u8(message.channelIndex)
        w.u8(message.routing.pathLength)
        w.u8(message.textType.rawValue)
        w.u32(message.senderTimestamp)
        w.text(message.text)
        return w.data
    }

    private static func encodeContactMessage(_ message: ContactMessage) -> Data {
        var w = ByteWriter(code: ResponseCode.contactMessage.rawValue)
        w.i8(Int8(clamping: Int(((message.snr ?? 0) * 4).rounded())))
        w.append([0, 0])
        w.append(message.senderPrefix.bytes)
        w.u8(message.routing.pathLength)
        w.u8(message.textType.rawValue)
        w.u32(message.senderTimestamp)
        if message.textType == .signedPlain { w.append(message.signerPrefix ?? [0, 0, 0, 0]) }
        w.text(message.text)
        return w.data
    }
}
