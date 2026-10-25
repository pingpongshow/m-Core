import Foundation
import Testing
@testable import MeshCoreKit

/// Golden frames for app → radio commands, written by hand from `MyMesh::handleCmdFrame`.
struct CommandEncodingTests {
    static let simpleCases: [(Command, String)] = [
        (.deviceQuery(), "1603"),
        (.appStart(appName: "m-Core"), "0103000000000000" + "6d2d436f7265"),
        (.getDeviceTime, "05"),
        (.setDeviceTime(0x1234_5678), "06" + "78563412"),
        (.syncNextMessage, "0a"),
        (.getContacts(), "04"),
        (.getContacts(since: 0x1234_5678), "04" + "78563412"),
        (.sendSelfAdvert(flood: true), "0701"),
        (.sendSelfAdvert(flood: false), "0700"),
        (.setRadioTxPower(-3), "0cfd"),
        (.getBatteryAndStorage, "14"),
        (.getStats(.radio), "3801"),
        (.getCustomVars, "28"),
        (.setCustomVar(name: "gps", value: "0"), "29" + "6770733a30"),
        (.setDevicePin(123_456), "25" + "40e20100"),
        (.runCLICommand("ver"), "42" + "766572"),
        (.reboot, "13" + "7265626f6f74"),
        (.factoryReset, "33" + "7265736574"),
        (.getChannel(index: 0), "1f00"),
        (.setPathHashMode(1), "3d0001"),
        (.setFloodScopeKey(nil), "3600"),
        (.setUnscopedFlood, "3601"),
        (.getDefaultFloodScope, "40"),
        (.setDefaultFloodScope(nil), "3f"),
        (.getAutoAddConfig, "3b"),
        (.setAutoAddConfig(AutoAddConfig(flags: 0x06, maxHops: 3)), "3a0603"),
        (.setAutoAddConfig(AutoAddConfig(flags: 0x06)), "3a06"),
        (.exportContact(nil), "11"),
        (.getTuningParams, "2b"),
        (.getAllowedRepeatFrequencies, "3c"),
        (.signStart, "21"),
        (.signData(Data([0xAA, 0xBB])), "22aabb"),
        (.signFinish, "23"),
        (.exportPrivateKey, "17"),
    ]

    @Test(arguments: simpleCases)
    func simpleCommand(command: Command, expectedHex: String) {
        #expect(command.encoded().hexString == expectedHex)
    }

    @Test func sendTextMessage() {
        let frame = Command.sendTextMessage(to: samplePrefix, text: "hi", timestamp: 0x1234_5678, attempt: 1).encoded()
        #expect(frame == hex("02", "00", "01", "78563412", "010203040506", "6869"))
    }

    @Test func sendTextMessageUsesOnlyTheSixBytePrefix() {
        let frame = Command.sendTextMessage(to: sampleKey.prefix, text: "", timestamp: 0).encoded()
        #expect(frame == hex("02", "00", "00", "00000000", "000102030405"))
    }

    @Test func sendChannelTextMessage() {
        let frame = Command.sendChannelTextMessage(channelIndex: 2, text: "yo", timestamp: 0x1234_5678).encoded()
        #expect(frame == hex("03", "00", "02", "78563412", "796f"))
    }

    @Test func sendChannelDataFlood() {
        let frame = Command.sendChannelData(channelIndex: 1, path: nil, dataType: 0xFFFF, payload: Data([0xAA, 0xBB])).encoded()
        #expect(frame == hex("3e", "01", "ff", "ffff", "aabb"))
    }

    @Test func sendChannelDataDirect() {
        let path = MeshPath(hashSize: 1, hashes: [[0x10], [0x20]])
        let frame = Command.sendChannelData(channelIndex: 1, path: path, dataType: 0x1234, payload: Data([0xAA])).encoded()
        #expect(frame == hex("3e", "01", "02", "1020", "3412", "aa"))
    }

    @Test func setAdvertLatLon() {
        let frame = Command.setAdvertLatLon(latitudeE6: 37_774_900, longitudeE6: -122_419_400).encoded()
        #expect(frame == hex("0e", "34664002", "3807b4f8"))
    }

    @Test func setAdvertLatLonWithAltitude() {
        let frame = Command.setAdvertLatLon(latitudeE6: 37_774_900, longitudeE6: -122_419_400, altitude: 15_000).encoded()
        #expect(frame == hex("0e", "34664002", "3807b4f8", "983a0000"))
    }

    @Test func setOtherParams() {
        let params = OtherParams(
            manualAddContacts: 0,
            telemetryModes: TelemetryModes(base: .allowAll, location: .allowFlagged, environment: .deny),
            advertLocationPolicy: 1,
            multiAcks: 2
        )
        #expect(Command.setOtherParams(params).encoded() == hex("26", "00", "06", "01", "02"))
    }

    @Test func setRadioParams() {
        let radio = RadioParameters(frequencyKHz: 910_525, bandwidthHz: 62_500, spreadingFactor: 7, codingRate: 5)
        #expect(Command.setRadioParams(radio).encoded() == hex("0b", "bde40d00", "24f40000", "07", "05"))
        #expect(Command.setRadioParams(radio, clientRepeat: true).encoded() == hex("0b", "bde40d00", "24f40000", "07", "05", "01"))
    }

    @Test func setTuningParams() {
        #expect(Command.setTuningParams(TuningParams(rxDelayBase: 0, airtimeFactor: 1)).encoded() == hex("15", "00000000", "e8030000"))
    }

    @Test func keyedCommands() {
        #expect(Command.getContactByKey(sampleKey).encoded() == hex("1e", sampleKeyHex))
        #expect(Command.removeContact(sampleKey).encoded() == hex("0f", sampleKeyHex))
        #expect(Command.resetPath(sampleKey).encoded() == hex("0d", sampleKeyHex))
        #expect(Command.shareContact(sampleKey).encoded() == hex("10", sampleKeyHex))
        #expect(Command.exportContact(sampleKey).encoded() == hex("11", sampleKeyHex))
        #expect(Command.logout(sampleKey).encoded() == hex("1d", sampleKeyHex))
        #expect(Command.hasConnection(sampleKey).encoded() == hex("1c", sampleKeyHex))
        #expect(Command.sendStatusRequest(sampleKey).encoded() == hex("1b", sampleKeyHex))
        #expect(Command.getAdvertPath(sampleKey).encoded() == hex("2a", "00", sampleKeyHex))
        #expect(Command.sendPathDiscoveryRequest(sampleKey).encoded() == hex("34", "00", sampleKeyHex))
    }

    @Test func telemetryRequests() {
        #expect(Command.sendTelemetryRequest(nil).encoded() == hex("27", "000000"))
        #expect(Command.sendTelemetryRequest(sampleKey).encoded() == hex("27", "000000", sampleKeyHex))
    }

    @Test func requests() {
        #expect(Command.sendLogin(to: sampleKey, password: "pw").encoded() == hex("1a", sampleKeyHex, "7077"))
        #expect(Command.sendBinaryRequest(to: sampleKey, data: Data([0x01, 0x02])).encoded() == hex("32", sampleKeyHex, "0102"))
        #expect(Command.sendAnonRequest(to: sampleKey, data: Data([0x07])).encoded() == hex("39", sampleKeyHex, "07"))
    }

    @Test func sendTracePath() {
        let frame = Command.sendTracePath(tag: 1, authCode: 2, flags: 0, pathHashes: [0x10, 0x20]).encoded()
        #expect(frame == hex("24", "01000000", "02000000", "00", "1020"))
    }

    @Test func sendRawData() {
        let frame = Command.sendRawData(path: MeshPath(hashSize: 1, hashes: [[0x10]]), payload: Data([0xAA, 0xBB, 0xCC, 0xDD])).encoded()
        #expect(frame == hex("19", "01", "10", "aabbccdd"))
    }

    @Test func setChannel() {
        let secret = (0..<16).map { UInt8($0) }
        let frame = Command.setChannel(ChannelInfo(index: 1, name: "Test", secret: secret)).encoded()
        #expect(frame == hex("20", "01", padded("Test", 32), Data(secret).hexString))
        #expect(frame.count == 50)
    }

    @Test func addUpdateContactLayout() {
        let contact = Contact(
            publicKey: sampleKey, type: .repeater, flags: 0x01,
            outPath: MeshPath(hashSize: 1, hashes: [[0x10], [0x20]]),
            name: "Repeater 1", lastAdvert: 0x1234_5678,
            latitudeE6: 37_774_900, longitudeE6: -122_419_400, lastModified: 0x0102_0304
        )
        let frame = Command.addUpdateContact(contact).encoded()
        let expected = hex(
            "09", sampleKeyHex, "02", "01", "02", "1020" + zeros(62),
            padded("Repeater 1", 32), "78563412", "34664002", "3807b4f8", "04030201"
        )
        #expect(frame == expected)
        #expect(frame.count == 148)
    }

    @Test func addUpdateContactWithUnknownPath() {
        let contact = Contact(publicKey: sampleKey, type: .chat, name: "Bob")
        let frame = [UInt8](Command.addUpdateContact(contact).encoded())
        #expect(frame[35] == 0xFF)
        #expect(frame[36..<100].allSatisfy { $0 == 0 })
    }

    @Test func advertNameIsTruncatedTo31Bytes() {
        let frame = Command.setAdvertName(String(repeating: "x", count: 40)).encoded()
        #expect(frame.count == 1 + 31)
    }

    @Test func fixedStringTruncatesAtCharacterBoundary() {
        // 15 × "é" (2 bytes each) = 30 bytes; one more would exceed the 31-byte limit mid-character.
        let name = String(repeating: "é", count: 16)
        let frame = [UInt8](Command.setChannel(ChannelInfo(index: 0, name: name, secret: [UInt8](repeating: 0, count: 16))).encoded())
        let nameField = Array(frame[2..<34])
        #expect(ByteReader.string(from: nameField) == String(repeating: "é", count: 15))
        #expect(nameField[30] == 0 && nameField[31] == 0)
    }

    @Test func everyCommandCodeIsEncodable() {
        // Guards against a case falling through every encoder group.
        let samples: [Command] = [
            .deviceQuery(), .appStart(appName: "x"), .getDeviceTime, .setDeviceTime(0),
            .sendTextMessage(to: samplePrefix, text: "", timestamp: 0),
            .sendChannelTextMessage(channelIndex: 0, text: "", timestamp: 0),
            .sendChannelData(channelIndex: 0, path: nil, dataType: 1, payload: Data()),
            .importContact(Data([1])), .importPrivateKey(Data([1])), .sendRawPacket(priority: 0, packet: Data([1])),
            .sendControlData(Data([0x80])),
        ]
        for command in samples {
            #expect(command.encoded().first == command.code.rawValue)
        }
    }
}
