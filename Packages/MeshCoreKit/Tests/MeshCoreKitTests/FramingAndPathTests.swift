import Foundation
import Testing
@testable import MeshCoreKit

struct SerialFramingTests {
    @Test func encodeAddsMarkerAndLength() throws {
        #expect(try SerialFraming.encode(hex("1603")) == hex("3c", "0200", "1603"))
    }

    @Test func encodeRejectsOversizedFrames() {
        #expect(throws: TransportError.frameTooLarge(177)) {
            try SerialFraming.encode(Data(count: 177))
        }
    }

    @Test func deframesSplitAndBackToBackFrames() {
        var deframer = SerialFraming.Deframer()
        #expect(deframer.append(hex("3e", "02")).isEmpty)
        #expect(deframer.append(hex("00", "0106")) == [hex("0106")])
        let frames = deframer.append(hex("3e0100", "83", "3e0100", "0a"))
        #expect(frames == [hex("83"), hex("0a")])
    }

    @Test func skipsJunkBeforeMarker() {
        var deframer = SerialFraming.Deframer()
        #expect(deframer.append(hex("ffff00", "3e0100", "83")) == [hex("83")])
    }

    @Test func resynchronisesAfterBogusLength() {
        var deframer = SerialFraming.Deframer(maxFrameLength: 176)
        // A stray ">" followed by an impossible length, then a real frame.
        #expect(deframer.append(hex("3effff", "3e0100", "83")) == [hex("83")])
    }

    @Test func ignoresZeroLengthHeaders() {
        var deframer = SerialFraming.Deframer()
        #expect(deframer.append(hex("3e0000", "3e0100", "0a")) == [hex("0a")])
    }
}

struct MeshPathTests {
    @Test func encodedLengthCarriesHashSizeAndCount() {
        #expect(MeshPath(hashSize: 1, hashes: [[0x10], [0x20]]).encodedLength == 0x02)
        #expect(MeshPath(hashSize: 2, hashes: [[0x10, 0xA3]]).encodedLength == 0x41)
        #expect(MeshPath(hashSize: 3, hashes: []).encodedLength == 0x80)
    }

    @Test func byteCountValidation() {
        #expect(MeshPath.byteCount(forEncodedLength: 0x02) == 2)
        #expect(MeshPath.byteCount(forEncodedLength: 0x43) == 6)
        #expect(MeshPath.byteCount(forEncodedLength: 0xFF) == nil) // hash size 4 is reserved / "unknown"
        #expect(MeshPath.byteCount(forEncodedLength: 0xBF) == nil) // 3 × 63 > 64 bytes
    }

    @Test func decodesFromBytes() {
        let path = MeshPath(encodedLength: 0x42, bytes: [0x10, 0xA3, 0x20, 0xB7, 0x00])
        #expect(path?.hashes == [[0x10, 0xA3], [0x20, 0xB7]])
        #expect(MeshPath(encodedLength: 0x03, bytes: [0x10]) == nil)
    }

    @Test func messageRouting() {
        #expect(MessageRouting(pathLength: 0xFF) == .direct)
        #expect(MessageRouting(pathLength: 0x43) == .flood(hops: 3))
    }
}

struct ModelTests {
    @Test func publicKeyHexAndPrefix() {
        #expect(sampleKey.hex == sampleKeyHex)
        #expect(PublicKey(hex: sampleKeyHex) == sampleKey)
        #expect(PublicKey(hex: "0011") == nil)
        #expect(sampleKey.prefix == KeyPrefix([0, 1, 2, 3, 4, 5]))
        #expect(sampleKey.prefix.matches(sampleKey))
        #expect(!samplePrefix.matches(sampleKey))
    }

    @Test func telemetryModesRoundTrip() {
        for byte: UInt8 in [0x00, 0x06, 0x2A, 0x15] {
            #expect(TelemetryModes(byte: byte).byte == byte)
        }
    }

    @Test func otherParamsFromSelfInfoPreservesFields() {
        let selfInfo = MockRadio.sampleState.selfInfo
        let params = OtherParams(from: selfInfo)
        #expect(params.telemetryModes == selfInfo.telemetryModes)
        #expect(params.advertLocationPolicy == selfInfo.advertLocationPolicy)
        #expect(params.multiAcks == selfInfo.multiAcks)
        #expect(params.manualAddContacts == selfInfo.manualAddContacts)
    }

    @Test func channelSenderParsing() {
        let message = ChannelMessage(channelIndex: 0, routing: .direct, senderTimestamp: 0, text: "no prefix here")
        #expect(message.senderName == nil)
        #expect(message.body == "no prefix here")
    }

    @Test func hexStringParsing() {
        #expect(Data(hexString: "0a 0B") == Data([0x0A, 0x0B]))
        #expect(Data(hexString: "abc") == nil)
        #expect(Data(hexString: "zz") == nil)
    }
}

/// Encoder (simulated radio) → decoder round trips for the frames `MockRadio` produces.
struct RoundTripTests {
    @Test func responsesRoundTrip() throws {
        let state = MockRadio.sampleState
        let contact = Contact(
            publicKey: otherKey, type: .room, flags: 0, outPath: MeshPath(hashSize: 2, hashes: [[1, 2]]),
            name: "Room", lastAdvert: 5, latitudeE6: -1, longitudeE6: 2, lastModified: 9
        )
        let responses: [Response] = [
            .ok(nil), .error(.tableFull), .contactsStart(count: 3), .contact(contact), .endOfContacts(lastModified: 9),
            .selfInfo(state.selfInfo), .deviceInfo(state.device), .deviceInfo(DeviceInfo(protocolVersion: 2)),
            .sent(SentInfo(isFlood: false, tag: 7, estimatedTimeoutMs: 900)), .currentTime(42), .noMoreMessages,
            .contactMessage(ContactMessage(
                senderPrefix: samplePrefix, routing: .flood(hops: 2), senderTimestamp: 1, text: "hey", snr: -2.25
            )),
            .channelMessage(ChannelMessage(channelIndex: 3, routing: .direct, senderTimestamp: 1, text: "A: b", snr: 1.5)),
            .batteryAndStorage(state.battery), .customVars(["gps": "1"]), .cliReply("ok"),
        ]
        for response in responses {
            let frame = try #require(RadioFrameEncoder.encode(response))
            #expect(try decodeResponse(frame) == response)
        }
    }

    @Test func pushesRoundTrip() throws {
        let pushes: [Push] = [
            .messagesWaiting, .contactsFull, .advert(sampleKey), .pathUpdated(sampleKey), .contactDeleted(sampleKey),
            .sendConfirmed(SendConfirmation(ackCode: 1, roundTripMs: 2)),
            .newAdvert(Contact(publicKey: sampleKey, type: .chat, name: "New")),
        ]
        for push in pushes {
            let frame = try #require(RadioFrameEncoder.encode(push))
            #expect(try decodePush(frame) == push)
        }
    }
}
