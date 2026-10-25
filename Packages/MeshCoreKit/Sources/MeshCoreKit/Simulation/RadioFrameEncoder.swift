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
        default:
            return encodeScalar(response)
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
        case .sendConfirmed(let confirmation):
            var w = ByteWriter(code: PushCode.sendConfirmed.rawValue)
            w.u32(confirmation.ackCode)
            w.u32(confirmation.roundTripMs)
            return w.data
        default:
            return nil
        }
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
