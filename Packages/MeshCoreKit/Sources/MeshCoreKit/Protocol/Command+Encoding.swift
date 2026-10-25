import Foundation

// Payload writers, grouped by area. Each returns false for cases it doesn't own.
extension Command {

    func encodeConnectionAndMessaging(into w: inout ByteWriter) -> Bool {
        switch self {
        case .deviceQuery(let version):
            w.u8(version)
        case .appStart(let appName):
            // Bytes 1–7 are reserved; byte 1 mirrors the app target version like the reference clients.
            w.u8(MeshCoreProtocol.appTargetVersion)
            w.append([UInt8](repeating: 0, count: 6))
            w.text(appName)
        case .getDeviceTime, .syncNextMessage:
            break
        case .setDeviceTime(let seconds):
            w.u32(seconds)
        case let .sendTextMessage(to, text, timestamp, attempt, type):
            w.u8(type.rawValue)
            w.u8(attempt)
            w.u32(timestamp)
            w.append(to.bytes.prefix(MeshCoreProtocol.keyPrefixSize))
            w.text(text)
        case let .sendChannelTextMessage(channelIndex, text, timestamp):
            w.u8(TextType.plain.rawValue)
            w.u8(channelIndex)
            w.u32(timestamp)
            w.text(text)
        case let .sendChannelData(channelIndex, path, dataType, payload):
            w.u8(channelIndex)
            if let path {
                w.u8(path.encodedLength)
                w.append(path.bytes)
            } else {
                w.u8(MeshPath.unknownLength)
            }
            w.u16(dataType)
            w.append(payload)
        default:
            return false
        }
        return true
    }

    func encodeContacts(into w: inout ByteWriter) -> Bool {
        switch self {
        case .getContacts(let since):
            if let since { w.u32(since) }
        case .getContactByKey(let key), .removeContact(let key), .resetPath(let key),
             .shareContact(let key), .logout(let key), .hasConnection(let key), .sendStatusRequest(let key):
            w.append(key.bytes)
        case .exportContact(let key):
            if let key { w.append(key.bytes) }
        case .importContact(let data):
            w.append(data)
        case .getAdvertPath(let key):
            w.u8(0) // reserved
            w.append(key.bytes)
        case .addUpdateContact(let contact):
            w.append(contact.publicKey.bytes)
            w.u8(contact.type.rawValue)
            w.u8(contact.flags)
            w.u8(contact.outPath?.encodedLength ?? MeshPath.unknownLength)
            let pathBytes = contact.outPath?.bytes ?? []
            w.append(pathBytes + [UInt8](repeating: 0, count: MeshCoreProtocol.maxPathSize - pathBytes.count))
            w.fixedString(contact.name, width: 32)
            w.u32(contact.lastAdvert)
            w.i32(contact.latitudeE6)
            w.i32(contact.longitudeE6)
            w.u32(contact.lastModified)
        case .setAutoAddConfig(let config):
            w.u8(config.flags)
            if let maxHops = config.maxHops { w.u8(maxHops) }
        case .getAutoAddConfig:
            break
        default:
            return false
        }
        return true
    }

    func encodeSelfAndRadio(into w: inout ByteWriter) -> Bool {
        switch self {
        case .sendSelfAdvert(let flood):
            w.u8(flood ? 1 : 0)
        case .setAdvertName(let name):
            w.append(ByteWriter.truncatedUTF8(name, maxBytes: 31))
        case let .setAdvertLatLon(latitudeE6, longitudeE6, altitude):
            w.i32(latitudeE6)
            w.i32(longitudeE6)
            if let altitude { w.i32(altitude) }
        case .setOtherParams(let params):
            w.u8(params.manualAddContacts)
            w.u8(params.telemetryModes.byte)
            w.u8(params.advertLocationPolicy)
            w.u8(params.multiAcks)
        case let .setRadioParams(radio, clientRepeat):
            w.u32(radio.frequencyKHz)
            w.u32(radio.bandwidthHz)
            w.u8(radio.spreadingFactor)
            w.u8(radio.codingRate)
            if let clientRepeat { w.u8(clientRepeat ? 1 : 0) }
        case .setRadioTxPower(let dbm):
            w.i8(dbm)
        case .setTuningParams(let params):
            w.u32(UInt32((params.rxDelayBase * 1000).rounded()))
            w.u32(UInt32((params.airtimeFactor * 1000).rounded()))
        case .getTuningParams, .getAllowedRepeatFrequencies, .getDefaultFloodScope:
            break
        case .setPathHashMode(let mode):
            w.u8(0) // sub-command
            w.u8(mode)
        case .setFloodScopeKey(let key):
            w.u8(0)
            if let key { w.append(key) }
        case .setUnscopedFlood:
            w.u8(1)
        case .setDefaultFloodScope(let scope):
            if let scope {
                w.fixedString(scope.name, width: 31)
                w.append(scope.key)
            }
        default:
            return false
        }
        return true
    }

    func encodeDevice(into w: inout ByteWriter) -> Bool {
        switch self {
        case .getBatteryAndStorage, .getCustomVars, .exportPrivateKey, .signStart, .signFinish:
            break
        case .getStats(let type):
            w.u8(type.rawValue)
        case let .setCustomVar(name, value):
            w.text("\(name):\(value)")
        case .setDevicePin(let pin):
            w.u32(pin)
        case .runCLICommand(let command):
            w.text(command)
        case .reboot:
            w.text("reboot")
        case .factoryReset:
            w.text("reset")
        case .importPrivateKey(let key):
            w.append(key)
        case .getChannel(let index):
            w.u8(index)
        case .setChannel(let channel):
            w.u8(channel.index)
            w.fixedString(channel.name, width: 32)
            w.append(channel.secret)
        case .signData(let data):
            w.append(data)
        default:
            return false
        }
        return true
    }

    func encodeRemote(into w: inout ByteWriter) -> Bool {
        switch self {
        case let .sendLogin(to, password):
            w.append(to.bytes)
            w.text(password)
        case .sendTelemetryRequest(let key):
            w.append([0, 0, 0]) // reserved
            if let key { w.append(key.bytes) }
        case let .sendBinaryRequest(to, data), let .sendAnonRequest(to, data):
            w.append(to.bytes)
            w.append(data)
        case .sendPathDiscoveryRequest(let key):
            w.u8(0) // reserved
            w.append(key.bytes)
        case let .sendTracePath(tag, authCode, flags, pathHashes):
            w.u32(tag)
            w.u32(authCode)
            w.u8(flags)
            w.append(pathHashes)
        default:
            return false
        }
        return true
    }

    func encodeRaw(into w: inout ByteWriter) -> Bool {
        switch self {
        case let .sendRawData(path, payload):
            w.u8(path.encodedLength)
            w.append(path.bytes)
            w.append(payload)
        case let .sendRawPacket(priority, packet):
            w.u8(priority)
            w.append(packet)
        case .sendControlData(let data):
            w.append(data)
        default:
            return false
        }
        return true
    }
}
