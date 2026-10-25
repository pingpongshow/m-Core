import Foundation
import Testing
@testable import MeshCoreKit

/// Golden radio → app frames, written by hand from the firmware's frame writers.
struct ResponseDecodingTests {
    @Test func okAndError() throws {
        #expect(try decodeResponse(hex("00")) == .ok(nil))
        #expect(try decodeResponse(hex("00", "2a000000")) == .ok(42))
        #expect(try decodeResponse(hex("0106")) == .error(.illegalArgument))
        #expect(try decodeResponse(hex("0102")) == .error(.notFound))
        #expect(try decodeResponse(hex("01")) == .error(nil))
        #expect(try decodeResponse(hex("0163")) == .error(.other(0x63)))
    }

    @Test func simpleValues() throws {
        #expect(try decodeResponse(hex("02", "05000000")) == .contactsStart(count: 5))
        #expect(try decodeResponse(hex("04", "78563412")) == .endOfContacts(lastModified: 0x1234_5678))
        #expect(try decodeResponse(hex("09", "78563412")) == .currentTime(0x1234_5678))
        #expect(try decodeResponse(hex("0a")) == .noMoreMessages)
        #expect(try decodeResponse(hex("0f")) == .disabled)
        #expect(try decodeResponse(hex("0b", "aabbcc")) == .exportedContact(Data([0xAA, 0xBB, 0xCC])))
        #expect(try decodeResponse(hex("13", "00", "00200000")) == .signStart(maxLength: 8192))
        #expect(try decodeResponse(hex("1d", utf8Hex("v1.18.0 (Build: 15 Oct 2026)"))) == .cliReply("v1.18.0 (Build: 15 Oct 2026)"))
    }

    @Test func sent() throws {
        let response = try decodeResponse(hex("06", "01", "efbeadde", "88130000"))
        #expect(response == .sent(SentInfo(isFlood: true, tag: 0xDEAD_BEEF, estimatedTimeoutMs: 5000)))
    }

    @Test func batteryAndStorage() throws {
        let response = try decodeResponse(hex("0c", "d20f", "78000000", "00040000"))
        #expect(response == .batteryAndStorage(BatteryAndStorage(millivolts: 4050, usedKB: 120, totalKB: 1024)))
    }

    @Test func selfInfo() throws {
        let frame = hex(
            "05", "01", "16", "16", sampleKeyHex,
            "34664002", "3807b4f8",       // lat, lon
            "00", "01", "06", "00",       // multi-acks, loc policy, telemetry modes, manual add
            "bde40d00", "24f40000",       // 910.525 MHz, 62.5 kHz
            "07", "05", utf8Hex("m-Core")
        )
        guard case .selfInfo(let info) = try decodeResponse(frame) else {
            Issue.record("not self info")
            return
        }
        #expect(info.advertType == .chat)
        #expect(info.txPowerDbm == 22)
        #expect(info.publicKey == sampleKey)
        #expect(info.latitude == 37.7749)
        #expect(info.longitude == -122.4194)
        #expect(info.sharesLocationInAdverts)
        #expect(info.telemetryModes == TelemetryModes(base: .allowAll, location: .allowFlagged, environment: .deny))
        #expect(info.radio.frequencyMHz == 910.525)
        #expect(info.radio.bandwidthKHz == 62.5)
        #expect(info.radio.spreadingFactor == 7)
        #expect(info.radio.codingRate == 5)
        #expect(info.name == "m-Core")
    }

    @Test func deviceInfoFull() throws {
        let frame = hex(
            "0d", "0e", "af", "28", "40e20100",
            padded("15 Oct 2026", 12), padded("Heltec V3", 40), padded("v1.18.0", 20),
            "00", "00"
        )
        let expected = DeviceInfo(
            protocolVersion: 14, maxContacts: 350, maxChannels: 40, blePin: 123_456,
            buildDate: "15 Oct 2026", model: "Heltec V3", firmwareVersion: "v1.18.0",
            clientRepeat: false, pathHashMode: 0
        )
        #expect(try decodeResponse(frame) == .deviceInfo(expected))
    }

    @Test func deviceInfoFromOldFirmware() throws {
        #expect(try decodeResponse(hex("0d", "02")) == .deviceInfo(DeviceInfo(protocolVersion: 2)))
    }

    @Test func deviceInfoWithoutV9Fields() throws {
        let frame = hex("0d", "08", "af", "08", "00000000", padded("1 Jan 2026", 12), padded("RAK4631", 40), padded("v1.9.0", 20))
        guard case .deviceInfo(let info) = try decodeResponse(frame) else {
            Issue.record("not device info")
            return
        }
        #expect(info.model == "RAK4631")
        #expect(info.clientRepeat == nil)
        #expect(info.pathHashMode == nil)
    }

    @Test func contact() throws {
        let frame = hex(
            "03", sampleKeyHex, "02", "01", "02", "1020" + zeros(62),
            padded("Repeater 1", 32), "78563412", "34664002", "3807b4f8", "04030201"
        )
        let expected = Contact(
            publicKey: sampleKey, type: .repeater, flags: 0x01,
            outPath: MeshPath(hashSize: 1, hashes: [[0x10], [0x20]]),
            name: "Repeater 1", lastAdvert: 0x1234_5678,
            latitudeE6: 37_774_900, longitudeE6: -122_419_400, lastModified: 0x0102_0304
        )
        #expect(try decodeResponse(frame) == .contact(expected))
        #expect(expected.isFavourite)
    }

    @Test func contactWithUnknownPathAndTwoByteHashes() throws {
        let unknown = hex("03", sampleKeyHex, "01", "00", "ff", zeros(64), padded("Bob", 32), zeros(16))
        guard case .contact(let bob) = try decodeResponse(unknown) else {
            Issue.record("not a contact")
            return
        }
        #expect(bob.outPath == nil)
        #expect(bob.type == .chat)
        #expect(!bob.hasLocation)

        // 0x42 = hash size 2 (top bits 01), 2 hops.
        let twoByte = hex("03", sampleKeyHex, "02", "00", "42", "10a320b7" + zeros(60), padded("R", 32), zeros(16))
        guard case .contact(let repeater) = try decodeResponse(twoByte) else {
            Issue.record("not a contact")
            return
        }
        #expect(repeater.outPath == MeshPath(hashSize: 2, hashes: [[0x10, 0xA3], [0x20, 0xB7]]))
    }

    @Test func contactMessageV3() throws {
        let frame = hex("10", "f4", "0000", "010203040506", "ff", "00", "78563412", utf8Hex("hi"))
        let expected = ContactMessage(
            senderPrefix: samplePrefix, routing: .direct, textType: .plain,
            senderTimestamp: 0x1234_5678, text: "hi", snr: -3
        )
        #expect(try decodeResponse(frame) == .contactMessage(expected))
    }

    @Test func signedContactMessage() throws {
        let frame = hex("10", "14", "0000", "010203040506", "03", "02", "78563412", "aabbccdd", utf8Hex("signed"))
        guard case .contactMessage(let message) = try decodeResponse(frame) else {
            Issue.record("not a message")
            return
        }
        #expect(message.textType == .signedPlain)
        #expect(message.signerPrefix == [0xAA, 0xBB, 0xCC, 0xDD])
        #expect(message.routing == .flood(hops: 3))
        #expect(message.text == "signed")
        #expect(message.snr == 5)
    }

    @Test func contactMessageV2HasNoSNR() throws {
        let frame = hex("07", "010203040506", "00", "00", "78563412", utf8Hex("old"))
        guard case .contactMessage(let message) = try decodeResponse(frame) else {
            Issue.record("not a message")
            return
        }
        #expect(message.snr == nil)
        #expect(message.routing == .flood(hops: 0))
        #expect(message.text == "old")
    }

    @Test func channelMessageV3() throws {
        let frame = hex("11", "14", "0000", "00", "02", "00", "78563412", utf8Hex("Bob: hello"))
        guard case .channelMessage(let message) = try decodeResponse(frame) else {
            Issue.record("not a channel message")
            return
        }
        #expect(message.channelIndex == 0)
        #expect(message.routing == .flood(hops: 2))
        #expect(message.snr == 5)
        #expect(message.senderName == "Bob")
        #expect(message.body == "hello")
    }

    @Test func channelData() throws {
        let frame = hex("1b", "08", "0000", "01", "ff", "ffff", "02", "aabb")
        let expected = ChannelData(snr: 2, channelIndex: 1, routing: .direct, dataType: 0xFFFF, payload: Data([0xAA, 0xBB]))
        #expect(try decodeResponse(frame) == .channelData(expected))
    }

    @Test func channelInfo() throws {
        let frame = hex("12", "00", padded("Public", 32), "8b3387e9c5cdea6ac9e5edbaa115cd72")
        let secret = [UInt8](Data(hexString: "8b3387e9c5cdea6ac9e5edbaa115cd72")!)
        #expect(try decodeResponse(frame) == .channelInfo(ChannelInfo(index: 0, name: "Public", secret: secret)))
    }

    @Test func customVars() throws {
        let frame = hex("15", utf8Hex("gps:1,gps_interval:30"))
        #expect(try decodeResponse(frame) == .customVars(["gps": "1", "gps_interval": "30"]))
        #expect(try decodeResponse(hex("15")) == .customVars([:]))
    }

    @Test func advertPath() throws {
        let frame = hex("16", "78563412", "41", "10a3")
        let expected = AdvertPath(receivedAt: 0x1234_5678, path: MeshPath(hashSize: 2, hashes: [[0x10, 0xA3]]))
        #expect(try decodeResponse(frame) == .advertPath(expected))
    }

    @Test func tuningParams() throws {
        #expect(try decodeResponse(hex("17", "00000000", "e8030000")) == .tuningParams(TuningParams(rxDelayBase: 0, airtimeFactor: 1)))
    }

    @Test func stats() throws {
        #expect(try decodeResponse(hex("18", "00", "d20f", "3c000000", "0000", "02")) ==
            .stats(.core(CoreStats(batteryMillivolts: 4050, uptimeSeconds: 60, errorFlags: 0, outboundQueueLength: 2))))
        #expect(try decodeResponse(hex("18", "01", "8cff", "b0", "28", "0a000000", "14000000")) ==
            .stats(.radio(RadioStats(noiseFloorDbm: -116, lastRSSI: -80, lastSNR: 10, txAirtimeSeconds: 10, rxAirtimeSeconds: 20))))
        let packets = hex("18", "02", "01000000", "02000000", "03000000", "04000000", "05000000", "06000000", "07000000")
        #expect(try decodeResponse(packets) == .stats(.packets(PacketStats(
            received: 1, sent: 2, sentFlood: 3, sentDirect: 4, receivedFlood: 5, receivedDirect: 6, receiveErrors: 7
        ))))
        #expect(try decodeResponse(hex("18", "09", "ff")) == .stats(.unknown(type: 9, payload: Data([0xFF]))))
    }

    @Test func autoAddConfig() throws {
        #expect(try decodeResponse(hex("19", "06", "03")) == .autoAddConfig(AutoAddConfig(flags: 6, maxHops: 3)))
        #expect(try decodeResponse(hex("19", "06")) == .autoAddConfig(AutoAddConfig(flags: 6)))
    }

    @Test func allowedRepeatFrequencies() throws {
        let frame = hex("1a", "689b0600", "689b0600", "77440d00", "77440d00")
        #expect(try decodeResponse(frame) == .allowedRepeatFrequencies([
            FrequencyRange(lowerKHz: 433_000, upperKHz: 433_000),
            FrequencyRange(lowerKHz: 869_495, upperKHz: 869_495),
        ]))
    }

    @Test func defaultFloodScope() throws {
        #expect(try decodeResponse(hex("1c")) == .defaultFloodScope(nil))
        let key = (0..<16).map { UInt8($0) }
        let scope = hex("1c", padded("us", 31), Data(key).hexString)
        #expect(try decodeResponse(scope) == .defaultFloodScope(FloodScope(name: "us", key: key)))
    }

    @Test func keysAndSignatures() throws {
        let sixtyFour = Data((0..<64).map { UInt8($0) })
        #expect(try decodeResponse(hex("0e", sixtyFour.hexString)) == .privateKey(sixtyFour))
        #expect(try decodeResponse(hex("14", sixtyFour.hexString)) == .signature(sixtyFour))
    }

    @Test func unknownResponseCode() throws {
        #expect(try decodeResponse(hex("7f", "0102")) == .unknown(code: 0x7F, payload: Data([0x01, 0x02])))
    }

    @Test func truncatedAndEmptyFrames() {
        #expect(throws: FrameDecodingError.empty) { try Frame.decode(Data()) }
        #expect(throws: FrameDecodingError.truncated(code: 0x02, needed: 5, available: 2)) {
            try Frame.decode(hex("02", "05"))
        }
        #expect(throws: FrameDecodingError.self) { try Frame.decode(hex("05", "01")) }
    }
}

/// Golden push frames.
struct PushDecodingTests {
    @Test func keyedPushes() throws {
        #expect(try decodePush(hex("80", sampleKeyHex)) == .advert(sampleKey))
        #expect(try decodePush(hex("81", sampleKeyHex)) == .pathUpdated(sampleKey))
        #expect(try decodePush(hex("8f", sampleKeyHex)) == .contactDeleted(sampleKey))
    }

    @Test func simplePushes() throws {
        #expect(try decodePush(hex("83")) == .messagesWaiting)
        #expect(try decodePush(hex("90")) == .contactsFull)
        let confirmed = SendConfirmation(ackCode: 0xDEAD_BEEF, roundTripMs: 1000)
        #expect(try decodePush(hex("82", "efbeadde", "e8030000")) == .sendConfirmed(confirmed))
        #expect(try decodePush(hex("fe", "01")) == .unknown(code: 0xFE, payload: Data([0x01])))
    }

    @Test func radioPackets() throws {
        #expect(try decodePush(hex("84", "14", "c4", "ff", "aabb")) ==
            .rawData(RadioPacket(snr: 5, rssi: -60, pathLength: 0xFF, payload: Data([0xAA, 0xBB]))))
        #expect(try decodePush(hex("8e", "10", "c4", "00", "90aa")) ==
            .controlData(RadioPacket(snr: 4, rssi: -60, pathLength: 0, payload: Data([0x90, 0xAA]))))
        #expect(try decodePush(hex("88", "28", "a6", "1122")) == .rxLog(RxLogEntry(snr: 10, rssi: -90, raw: Data([0x11, 0x22]))))
    }

    @Test func login() throws {
        let success = try decodePush(hex("85", "01", "010203040506", "78563412", "03", "0e"))
        #expect(success == .loginSuccess(LoginResult(
            senderPrefix: samplePrefix, permissions: 1, serverTimestamp: 0x1234_5678, aclPermissions: 3, firmwareLevel: 14
        )))
        let legacy = try decodePush(hex("85", "00", "010203040506"))
        #expect(legacy == .loginSuccess(LoginResult(senderPrefix: samplePrefix, permissions: 0)))
        #expect(try decodePush(hex("86", "00", "010203040506")) == .loginFailed(samplePrefix))
    }

    @Test func remoteReplies() throws {
        #expect(try decodePush(hex("87", "00", "010203040506", "aabb")) ==
            .statusResponse(StatusResponse(senderPrefix: samplePrefix, payload: Data([0xAA, 0xBB]))))
        #expect(try decodePush(hex("8b", "00", "010203040506", "0174019a")) ==
            .telemetryResponse(TelemetryResponse(senderPrefix: samplePrefix, lpp: Data([0x01, 0x74, 0x01, 0x9A]))))
        #expect(try decodePush(hex("8c", "00", "efbeadde", "0102")) ==
            .binaryResponse(BinaryResponse(tag: 0xDEAD_BEEF, payload: Data([0x01, 0x02]))))
    }

    @Test func pathDiscovery() throws {
        let push = try decodePush(hex("8d", "00", "010203040506", "01", "10", "02", "2030"))
        #expect(push == .pathDiscoveryResponse(PathDiscoveryResult(
            senderPrefix: samplePrefix,
            outPath: MeshPath(hashSize: 1, hashes: [[0x10]]),
            inPath: MeshPath(hashSize: 1, hashes: [[0x20], [0x30]])
        )))
    }

    @Test func trace() throws {
        let push = try decodePush(hex("89", "00", "02", "00", "01000000", "02000000", "1020", "1428", "0c"))
        #expect(push == .traceData(TraceResult(
            tag: 1, authCode: 2, flags: 0, pathHashes: [[0x10], [0x20]], hopSNRs: [5, 10], finalSNR: 3
        )))
    }

    @Test func traceWithTwoByteHashes() throws {
        // flags & 3 = 1 → 2-byte hashes; 4 path bytes = 2 hops.
        let push = try decodePush(hex("89", "00", "04", "01", "01000000", "02000000", "10a320b7", "f4ec", "08"))
        guard case .traceData(let trace) = push else {
            Issue.record("not a trace")
            return
        }
        #expect(trace.pathHashes == [[0x10, 0xA3], [0x20, 0xB7]])
        #expect(trace.hopSNRs == [-3, -5])
        #expect(trace.finalSNR == 2)
    }

    @Test func newAdvertUsesContactLayout() throws {
        let frame = hex("8a", otherKeyHex, "01", "00", "ff", zeros(64), padded("Alice", 32), "01000000", zeros(8), "02000000")
        guard case .newAdvert(let contact) = try decodePush(frame) else {
            Issue.record("not a new advert")
            return
        }
        #expect(contact.publicKey == otherKey)
        #expect(contact.name == "Alice")
        #expect(contact.lastAdvert == 1)
        #expect(contact.lastModified == 2)
    }
}
