import Foundation
import MeshCoreKit
import Testing
@testable import MeshTools

/// Vectors built by hand from the firmware layout; hashes cross-checked with Python's hashlib.
enum Vectors {
    /// Flood advert via repeaters A1, B2: repeater "Charlie Node" at 47.606209, -122.332071.
    static let advert = "1102A1B2" + "0102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F20" + "B2A15066"
        + String(repeating: "EE", count: 64) + "92" + "C169D602" + "595CB5F8" + "436861726C6965204E6F6465"
    static let advertHash = "5B1DBBAEE59E36EE"
    /// Direct TRACE, path length 3.
    static let trace = "26031122330102030405060708090A"
    static let traceHash = "D1D595F856F15B66"
    /// Transport-flood group text: codes 0x1234 / 0xABCD, one 2-byte hop hash.
    static let groupText = "143412CDAB41AABB5AC0FFEE0011223344"
    static let groupTextHash = "CA2F14B4480AFBD4"
    /// Direct text message from 3D to 7C, one hop left (99).
    static let textMessage = "0A01997C3D0102030405"
    static let textMessageHash = "455518C3C5F96F85"
}

struct MeshPacketTests {
    @Test func decodesAdvertHeaderPathAndHash() throws {
        let packet = try #require(MeshPacket(hex: Vectors.advert))
        #expect(packet.header == 0x11)
        #expect(packet.routeType == .flood)
        #expect(packet.payloadType == .advert)
        #expect(packet.payloadVersion == 0)
        #expect(packet.transportCodes == nil)
        #expect(packet.path == MeshPath(hashSize: 1, hashes: [[0xA1], [0xB2]]))
        #expect(packet.payload.count == 121)
        #expect(packet.rawLength == packet.raw.count)
        #expect(packet.hashHex == Vectors.advertHash)
    }

    @Test func decodesAdvertAppData() throws {
        let advert = try #require(MeshPacket(hex: Vectors.advert)?.advert)
        #expect(advert.publicKey.bytes == Array(1...32))
        #expect(advert.timestamp == 0x6650_A1B2)
        #expect(advert.signature == [UInt8](repeating: 0xEE, count: 64))
        #expect(advert.type == .repeater)
        #expect(advert.isAppDataValid)
        #expect(advert.latitudeE6 == 47_606_209)
        #expect(advert.longitudeE6 == -122_332_071)
        #expect(advert.feature1 == nil && advert.feature2 == nil)
        #expect(advert.name == "Charlie Node")
    }

    @Test func summaryReadsNaturally() throws {
        #expect(MeshPacket(hex: Vectors.advert)?.summary == "Advert · Charlie Node · flood · 2 hops")
        #expect(MeshPacket(hex: Vectors.textMessage)?.summary == "Text message · 3D → 7C · direct · 1 hop")
        #expect(MeshPacket(hex: Vectors.groupText)?.summary == "Group text · channel 5A · transport flood · 1 hop")
    }

    @Test func traceHashIncludesPathLengthAsUInt16() throws {
        let packet = try #require(MeshPacket(hex: Vectors.trace))
        #expect(packet.routeType == .direct)
        #expect(packet.payloadType == .trace)
        #expect(packet.hashHex == Vectors.traceHash)
    }

    @Test func decodesTransportCodesAndWideHashes() throws {
        let packet = try #require(MeshPacket(hex: Vectors.groupText))
        #expect(packet.routeType == .transportFlood)
        #expect(packet.routeType.logLetter == "F")
        #expect(packet.transportCodes == TransportCodes(first: 0x1234, second: 0xABCD))
        #expect(packet.path.hashSize == 2)
        #expect(packet.path.hashes == [[0xAA, 0xBB]])
        #expect(packet.channelHash == 0x5A)
        #expect(packet.hashHex == Vectors.groupTextHash)
    }

    @Test func hashIgnoresPathForNonTracePackets() throws {
        let original = try #require(MeshPacket(hex: Vectors.advert))
        // Same payload after one more hop (path length 3, extra hash C3).
        let relayed = try #require(MeshPacket(hex: "1103A1B2C3" + Vectors.advert.dropFirst(8)))
        #expect(relayed.hopCount == 3)
        #expect(relayed.hash == original.hash)
        #expect(MeshPacket(hex: Vectors.textMessage)?.hashHex == Vectors.textMessageHash)
    }

    @Test func payloadTypeNumbersMatchFirmware() {
        let expected: [(UInt8, PayloadType)] = [
            (0, .request), (1, .response), (2, .textMessage), (3, .ack), (4, .advert), (5, .groupText),
            (6, .groupData), (7, .anonRequest), (8, .path), (9, .trace), (10, .multipart), (11, .control), (15, .rawCustom),
        ]
        for (raw, type) in expected {
            #expect(PayloadType(rawValue: raw) == type)
            #expect(type.rawValue == raw)
        }
        #expect(PayloadType(rawValue: 12) == .unknown(12))
    }

    @Test func rejectsMalformedInputWithoutCrashing() {
        #expect(throws: MeshPacketDecodingError.empty) { try MeshPacket(raw: Data()) }
        #expect(throws: MeshPacketDecodingError.truncated) { try MeshPacket(raw: Data([0x11])) }
        #expect(throws: MeshPacketDecodingError.truncated) { try MeshPacket(raw: Data([0x10, 0x01, 0x02])) }
        #expect(throws: MeshPacketDecodingError.truncated) { try MeshPacket(raw: Data([0x11, 0x05, 0x01])) }
        #expect(throws: MeshPacketDecodingError.invalidPathLength(0xC1)) { try MeshPacket(raw: Data([0x11, 0xC1, 0x01])) }
        #expect(throws: MeshPacketDecodingError.invalidPathLength(0xBF)) { try MeshPacket(raw: Data([0x11, 0xBF])) }
        #expect(throws: MeshPacketDecodingError.payloadTooLong(185)) {
            try MeshPacket(raw: Data([0x11, 0x00] + [UInt8](repeating: 0, count: 185)))
        }
        // Fuzz: every prefix of every vector decodes or throws, never traps.
        for vector in [Vectors.advert, Vectors.trace, Vectors.groupText, Vectors.textMessage] {
            let bytes = [UInt8](Data(hexString: vector) ?? Data())
            for length in 0...bytes.count {
                let packet = MeshPacket.decode(Data(bytes.prefix(length)))
                _ = packet?.advert
                _ = packet?.summary
            }
        }
    }

    @Test func advertWithShortAppDataIsPartial() throws {
        // Flags promise a location but only 3 bytes follow.
        let fixed = String(Vectors.advert.dropFirst(8).prefix(200))
        let packet = try #require(MeshPacket(hex: "1100" + fixed + "91" + "C169D6"))
        let advert = try #require(packet.advert)
        #expect(advert.type == .chat)
        #expect(!advert.isAppDataValid)
        #expect(advert.latitudeE6 == nil && advert.name == nil)
        #expect(packet.summary.hasPrefix("Advert · key 010203040506 ·"))
        // Too short for the fixed fields at all.
        #expect(MeshPacket(hex: "1100" + String(fixed.prefix(100)))?.advert == nil)
    }

    @Test func advertFeatureFieldsAndNameRemainder() throws {
        let fixed = String(Vectors.advert.dropFirst(8).prefix(200))
        // Chat node, feat1 = 0x0102, feat2 = 0x0304, name "Ab".
        let packet = try #require(MeshPacket(hex: "1100" + fixed + "E1" + "0201" + "0403" + "4162"))
        let advert = try #require(packet.advert)
        #expect(advert.feature1 == 0x0102)
        #expect(advert.feature2 == 0x0304)
        #expect(advert.name == "Ab")
        #expect(advert.latitude == nil)
    }

    @Test func loRaEstimatesMatchFirmwareFormulae() {
        // SF7 threshold −7.5 dB: (2.5 + 7.5) / 10 × (1 − 64/256) = 0.75.
        #expect(abs(LoRaEstimate.packetScore(snr: 2.5, spreadingFactor: 7, packetLength: 64) - 0.75) < 1e-9)
        #expect(LoRaEstimate.packetScore(snr: -21, spreadingFactor: 12, packetLength: 10) == 0)
        #expect(LoRaEstimate.packetScore(snr: 30, spreadingFactor: 7, packetLength: 0) == 1)
        // SF7/125 kHz/CR 4/5, 8-symbol preamble, 10 bytes: 41.216 ms (Semtech calculator).
        let airtime = LoRaEstimate.airtimeMilliseconds(
            payloadLength: 10, spreadingFactor: 7, bandwidthKHz: 125, codingRate: 5, preambleSymbols: 8
        )
        #expect(abs(airtime - 41.216) < 0.01)
    }
}
