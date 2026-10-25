import Foundation

// Command handlers for `MockRadio`, grouped by area. Each returns nil for commands it doesn't handle.
extension MockRadio {
    static func responses(to frame: Data, state: inout State) -> [Response] {
        guard let first = frame.first, let code = CommandCode(rawValue: first) else {
            return [.error(.unsupportedCommand)]
        }
        var reader = ByteReader(frame, code: first, offset: 1)
        if let responses = deviceResponses(code, &reader, &state) { return responses }
        if let responses = advertResponses(code, &reader, &state) { return responses }
        if let responses = messagingResponses(code, &reader, &state) { return responses }
        if let responses = contactResponses(code, &reader, &state) { return responses }
        if let responses = requestResponses(code, &reader, &state) { return responses }
        if let responses = settingsResponses(code, &reader, &state) { return responses }
        if let responses = securityResponses(code, &reader, &state) { return responses }
        return [.error(.unsupportedCommand)]
    }

    /// Device identity, clock, battery and custom variable commands.
    private static func deviceResponses(_ code: CommandCode, _ reader: inout ByteReader, _ state: inout State) -> [Response]? {
        switch code {
        case .deviceQuery:
            return [.deviceInfo(state.device)]
        case .appStart:
            return [.selfInfo(state.selfInfo)]
        case .getDeviceTime:
            return [.currentTime(state.clock)]
        case .setDeviceTime:
            guard let time = try? reader.u32() else { return [.error(.illegalArgument)] }
            guard time >= state.clock else { return [.error(.illegalArgument)] }
            state.clock = time
            return [.ok(nil)]
        case .getBatteryAndStorage:
            return [.batteryAndStorage(state.battery)]
        case .getCustomVars:
            return [.customVars(state.customVars)]
        case .setCustomVar:
            let text = reader.restString()
            guard let colon = text.firstIndex(of: ":") else { return [.error(.illegalArgument)] }
            let name = String(text[..<colon])
            guard state.customVars[name] != nil else { return [.error(.illegalArgument)] }
            state.customVars[name] = String(text[text.index(after: colon)...])
            return [.ok(nil)]
        default:
            return nil
        }
    }

    /// Advert position and name, other params, reboot and stats commands.
    private static func advertResponses(_ code: CommandCode, _ reader: inout ByteReader, _ state: inout State) -> [Response]? {
        switch code {
        case .setAdvertLatLon:
            guard let lat = try? reader.i32(), let lon = try? reader.i32(),
                  abs(Int(lat)) <= 90_000_000, abs(Int(lon)) <= 180_000_000 else {
                return [.error(.illegalArgument)]
            }
            state.selfInfo.latitudeE6 = lat
            state.selfInfo.longitudeE6 = lon
            state.positionWrites += 1
            return [.ok(nil)]
        case .setAdvertName:
            state.selfInfo.name = reader.restString()
            return [.ok(nil)]
        case .sendSelfAdvert:
            state.advertsSent += 1
            return [.ok(nil)]
        case .setOtherParams:
            guard let manual = try? reader.u8() else { return [.error(.illegalArgument)] }
            state.selfInfo.manualAddContacts = manual
            if let modes = try? reader.u8() { state.selfInfo.telemetryModes = TelemetryModes(byte: modes) }
            if let policy = try? reader.u8() { state.selfInfo.advertLocationPolicy = policy }
            if let acks = try? reader.u8() { state.selfInfo.multiAcks = acks }
            return [.ok(nil)]
        case .reboot, .factoryReset:
            state.reboots += 1
            return []
        case .getStats:
            switch try? reader.u8() {
            case StatsType.core.rawValue:
                return [.stats(.core(CoreStats(
                    batteryMillivolts: state.battery.millivolts, uptimeSeconds: 3_600, errorFlags: 0, outboundQueueLength: 0
                )))]
            case StatsType.radio.rawValue:
                let noise = Int16(-118 + Int(state.clock % 7))
                return [.stats(.radio(RadioStats(
                    noiseFloorDbm: noise, lastRSSI: -72, lastSNR: 7.25, txAirtimeSeconds: 42, rxAirtimeSeconds: 610
                )))]
            case StatsType.packets.rawValue:
                return [.stats(.packets(PacketStats(
                    received: 1_204, sent: 233, sentFlood: 120, sentDirect: 113, receivedFlood: 980, receivedDirect: 224, receiveErrors: 3
                )))]
            default:
                return [.error(.illegalArgument)]
            }
        default:
            return nil
        }
    }

    /// Message queue, channel and text message commands.
    private static func messagingResponses(_ code: CommandCode, _ reader: inout ByteReader, _ state: inout State) -> [Response]? {
        switch code {
        case .syncNextMessage:
            return state.queuedMessages.isEmpty ? [.noMoreMessages] : [state.queuedMessages.removeFirst()]
        case .getChannel:
            // The firmware keeps a fixed table: every slot below the limit answers, unused ones with an
            // empty name and zero secret. Only an index past the table is "not found".
            guard let index = try? reader.u8(), Int(index) < channelSlots(state) else { return [.error(.notFound)] }
            let empty = ChannelInfo(index: index, name: "", secret: [UInt8](repeating: 0, count: 16))
            return [.channelInfo(state.channels.first { $0.index == index } ?? empty)]
        case .setChannel:
            guard let index = try? reader.u8(), let name = try? reader.fixedString(32), let secret = try? reader.bytes(16) else {
                return [.error(.illegalArgument)]
            }
            guard Int(index) < channelSlots(state) else { return [.error(.notFound)] }
            state.channels.removeAll { $0.index == index }
            if !name.isEmpty { state.channels.append(ChannelInfo(index: index, name: name, secret: secret)) }
            state.channels.sort { $0.index < $1.index }
            return [.ok(nil)]
        case .sendTextMessage:
            guard let textType = try? reader.u8(), let attempt = try? reader.u8(), (try? reader.u32()) != nil,
                  let prefix = try? reader.bytes(6) else { return [.error(.illegalArgument)] }
            let keyPrefix = KeyPrefix(prefix)
            guard state.contacts.contains(where: { keyPrefix.matches($0.publicKey) }) else { return [.error(.notFound)] }
            let text = reader.restString()
            if textType == TextType.cliData.rawValue {
                // Repeaters answer CLI commands with a CLI-data message, delivered through the queue.
                if let reply = remoteCLIReply(to: text, state: &state) {
                    state.queuedMessages.append(.contactMessage(ContactMessage(
                        senderPrefix: keyPrefix, routing: .direct, textType: .cliData, senderTimestamp: state.clock, text: reply
                    )))
                }
                state.nextTag += 1
                return [.sent(SentInfo(isFlood: false, tag: state.nextTag, estimatedTimeoutMs: 100))]
            }
            state.sentDirectMessages.append(SentDirectMessage(prefix: keyPrefix, text: text, attempt: attempt))
            state.nextTag += 1
            return [.sent(SentInfo(isFlood: false, tag: state.nextTag, estimatedTimeoutMs: 100))]
        case .sendChannelTextMessage:
            guard (try? reader.u8()) != nil, let index = try? reader.u8(), (try? reader.u32()) != nil else {
                return [.error(.illegalArgument)]
            }
            guard state.channels.contains(where: { $0.index == index }) else { return [.error(.notFound)] }
            state.sentChannelMessages.append((index, reader.restString()))
            return [.ok(nil)]
        default:
            return nil
        }
    }

    /// Like `updateContactFromFrame`: an explicit trailing lastmod is stored as given, otherwise the radio's clock.
    private static func addOrUpdateContact(_ reader: inout ByteReader, _ state: inout State) -> [Response] {
        let hasLastModified = reader.remaining >= 32 + 3 + MeshCoreProtocol.maxPathSize + 32 + 4 + 8 + 4
        guard var contact = try? Frame.decodeContact(&reader) else { return [.error(.illegalArgument)] }
        if !hasLastModified {
            state.clock += 1
            contact.lastModified = state.clock
        }
        if let index = state.contacts.firstIndex(where: { $0.publicKey == contact.publicKey }) {
            state.contacts[index] = contact
        } else {
            state.contacts.append(contact)
        }
        return [.ok(nil)]
    }

    /// Size of the radio's channel table (`MAX_GROUP_CHANNELS`).
    private static func channelSlots(_ state: State) -> Int {
        state.device.maxChannels ?? 8
    }

    /// Contact list commands.
    private static func contactResponses(_ code: CommandCode, _ reader: inout ByteReader, _ state: inout State) -> [Response]? {
        switch code {
        case .getContacts:
            let since = reader.remaining >= 4 ? (try? reader.u32()) ?? 0 : 0
            let changed = state.contacts.filter { $0.lastModified > since }
            let lastModified = changed.map(\.lastModified).max() ?? 0
            return [.contactsStart(count: UInt32(state.contacts.count))]
                + changed.map(Response.contact)
                + [.endOfContacts(lastModified: lastModified)]
        case .getContactByKey:
            guard let bytes = try? reader.bytes(32), let contact = state.contacts.first(where: { $0.publicKey.bytes == bytes }) else {
                return [.error(.notFound)]
            }
            return [.contact(contact)]
        case .importContact:
            let packet = Data(reader.rest())
            guard !packet.isEmpty else { return [.error(.illegalArgument)] }
            state.importedContacts.append(packet)
            return [.ok(nil)]
        case .exportContact:
            // The simulator only exports itself; other contacts' adverts aren't kept.
            return reader.remaining >= 32 ? [.error(.unsupportedCommand)] : [.exportedContact(selfAdvert(for: state))]
        case .resetPath:
            guard let bytes = try? reader.bytes(32), let key = PublicKey(bytes: bytes) else { return [.error(.illegalArgument)] }
            state.pathResets.append(key)
            return [.ok(nil)]
        case .removeContact:
            guard let bytes = try? reader.bytes(32), let index = state.contacts.firstIndex(where: { $0.publicKey.bytes == bytes }) else {
                return [.error(.notFound)]
            }
            state.contacts.remove(at: index)
            return [.ok(nil)]
        case .addUpdateContact:
            return addOrUpdateContact(&reader, &state)
        case .shareContact:
            guard let bytes = try? reader.bytes(32), state.contacts.contains(where: { $0.publicKey.bytes == bytes }) else {
                return [.error(.notFound)]
            }
            state.advertsSent += 1
            return [.ok(nil)]
        default:
            return nil
        }
    }

    /// Requests sent over the mesh to other nodes (logins, telemetry, traces, CLI).
    private static func requestResponses(_ code: CommandCode, _ reader: inout ByteReader, _ state: inout State) -> [Response]? {
        switch code {
        case .sendLogin, .sendStatusRequest, .sendPathDiscoveryRequest:
            if code == .sendPathDiscoveryRequest { _ = try? reader.u8() }
            guard let bytes = try? reader.bytes(32), state.contacts.contains(where: { $0.publicKey.bytes == bytes }) else {
                return [.error(.notFound)]
            }
            state.nextTag += 1
            return [.sent(SentInfo(isFlood: code == .sendPathDiscoveryRequest, tag: state.nextTag, estimatedTimeoutMs: 100))]
        case .sendTelemetryRequest:
            _ = try? reader.bytes(3)
            guard reader.remaining >= 32 else { return [] } // self request: answered by push only
            guard let bytes = try? reader.bytes(32), state.contacts.contains(where: { $0.publicKey.bytes == bytes }) else {
                return [.error(.notFound)]
            }
            state.nextTag += 1
            return [.sent(SentInfo(isFlood: false, tag: state.nextTag, estimatedTimeoutMs: 100))]
        case .sendBinaryRequest:
            guard let bytes = try? reader.bytes(32), state.contacts.contains(where: { $0.publicKey.bytes == bytes }) else {
                return [.error(.notFound)]
            }
            state.nextTag += 1
            return [.sent(SentInfo(isFlood: false, tag: state.nextTag, estimatedTimeoutMs: 100))]
        case .sendTracePath:
            state.nextTag += 1
            return [.sent(SentInfo(isFlood: false, tag: (try? reader.u32()) ?? 0, estimatedTimeoutMs: 100))]
        case .runCLICommand:
            let command = reader.restString()
            state.cliCommands.append(command)
            switch command {
            case "ver": return [.cliReply("v1.18.0 (Build: 15 Oct 2026)")]
            case "get wifi.status": return [.cliReply("Unknown command")]
            default: return [.cliReply("OK")]
            }
        default:
            return nil
        }
    }

    /// Radio, tuning, auto-add and repeat frequency settings.
    private static func settingsResponses(_ code: CommandCode, _ reader: inout ByteReader, _ state: inout State) -> [Response]? {
        switch code {
        case .setRadioParams:
            guard let freq = try? reader.u32(), let bw = try? reader.u32(), let sf = try? reader.u8(), let cr = try? reader.u8(),
                  (150_000...2_500_000).contains(freq), (5...12).contains(sf), (5...8).contains(cr), (7_000...500_000).contains(bw) else {
                return [.error(.illegalArgument)]
            }
            state.selfInfo.radio = RadioParameters(frequencyKHz: freq, bandwidthHz: bw, spreadingFactor: sf, codingRate: cr)
            if let repeatFlag = try? reader.u8() { state.clientRepeat = repeatFlag != 0 }
            return [.ok(nil)]
        case .setRadioTxPower:
            guard let power = try? reader.i8(), (-9...state.selfInfo.maxTxPowerDbm).contains(power) else {
                return [.error(.illegalArgument)]
            }
            state.selfInfo.txPowerDbm = power
            return [.ok(nil)]
        case .getTuningParams:
            return [.tuningParams(state.tuning)]
        case .setTuningParams:
            guard let rx = try? reader.u32(), let af = try? reader.u32() else { return [.error(.illegalArgument)] }
            state.tuning = TuningParams(rxDelayBase: Double(rx) / 1000, airtimeFactor: Double(af) / 1000)
            return [.ok(nil)]
        case .getAutoAddConfig:
            return [.autoAddConfig(state.autoAdd)]
        case .setAutoAddConfig:
            guard let flags = try? reader.u8() else { return [.error(.illegalArgument)] }
            state.autoAdd = AutoAddConfig(flags: flags, maxHops: try? reader.u8())
            return [.ok(nil)]
        case .getAllowedRepeatFrequencies:
            return [.allowedRepeatFrequencies([
                FrequencyRange(lowerKHz: 433_000, upperKHz: 433_000),
                FrequencyRange(lowerKHz: 869_495, upperKHz: 869_495),
                FrequencyRange(lowerKHz: 918_000, upperKHz: 918_000),
            ])]
        default:
            return nil
        }
    }

    /// PIN, signing and private key commands.
    private static func securityResponses(_ code: CommandCode, _ reader: inout ByteReader, _ state: inout State) -> [Response]? {
        switch code {
        case .setDevicePin:
            guard let pin = try? reader.u32(), pin == 0 || (100_000...999_999).contains(pin) else { return [.error(.illegalArgument)] }
            state.blePin = pin
            return [.ok(nil)]
        case .signStart:
            state.signBuffer = Data()
            return [.signStart(maxLength: 8 * 1024)]
        case .signData:
            guard state.signBuffer != nil else { return [.error(.badState)] }
            state.signBuffer?.append(Data(reader.rest()))
            return [.ok(nil)]
        case .signFinish:
            guard let buffer = state.signBuffer else { return [.error(.badState)] }
            state.signBuffer = nil
            return [.signature(Self.demoSignature(of: buffer))]
        case .exportPrivateKey:
            return state.privateKeyExportEnabled ? [.privateKey(state.privateKey)] : [.disabled]
        case .importPrivateKey:
            guard state.privateKeyExportEnabled else { return [.disabled] }
            guard let key = try? reader.bytes(64) else { return [.error(.illegalArgument)] }
            state.privateKey = Data(key)
            return [.ok(nil)]
        default:
            return nil
        }
    }
}
