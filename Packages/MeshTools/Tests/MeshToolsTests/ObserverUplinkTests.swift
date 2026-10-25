import Foundation
import MeshCoreKit
import Testing
@testable import MeshTools

struct ObserverUplinkTests {
    let observer = ObserverIdentity(
        name: "Seattle \"Obs\"",
        publicKey: PublicKey(bytes: Array(1...32))!,
        iata: "SEA"
    )
    let receivedAt = Date(timeIntervalSince1970: 1_716_554_096.5)
    let radio = RadioParameters(frequencyKHz: 910_525, bandwidthHz: 62_500, spreadingFactor: 7, codingRate: 5)
    let keyHex = "0102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F20"

    @Test func topicsUseUppercaseKey() {
        #expect(ObserverUplink.packetsTopic(for: observer) == "meshcore/SEA/\(keyHex)/packets")
        #expect(ObserverUplink.statusTopic(for: observer) == "meshcore/SEA/\(keyHex)/status")
        #expect(ObserverUplink.topic("x/{IATA}", for: observer) == "x/SEA")
    }

    @Test func clientIDMatchesBridge() {
        #expect(ObserverUplink.clientID(for: observer.publicKey) == "meshcore_01020304050607")
        #expect(ObserverUplink.clientID(for: observer.publicKey).count <= 23)
    }

    @Test func radioDescription() {
        #expect(ObserverUplink.radioDescription(radio) == "910.525,62.5,7,5")
        let eu = RadioParameters(frequencyKHz: 869_618, bandwidthHz: 62_500, spreadingFactor: 8, codingRate: 8)
        #expect(ObserverUplink.radioDescription(eu) == "869.618,62.5,8,8")
        let round = RadioParameters(frequencyKHz: 915_000, bandwidthHz: 250_000, spreadingFactor: 10, codingRate: 5)
        #expect(ObserverUplink.radioDescription(round) == "915,250,10,5")
    }

    @Test func isoTimestampLooksLikePython() {
        #expect(ObserverUplink.isoTimestamp(receivedAt) == "2024-05-24T12:34:56.500000+00:00")
    }

    @Test func packetMessageFields() throws {
        let raw = try #require(Data(hexString: Vectors.advert))
        let json = try #require(ObserverUplink.packetMessage(
            raw: raw, snr: 7.75, rssi: -92, observer: observer, receivedAt: receivedAt, radio: radio
        ))
        let expected = #"{"origin":"Seattle \"Obs\"","origin_id":"\#(keyHex)","timestamp":"2024-05-24T12:34:56.500000+00:00","#
            + #""type":"PACKET","direction":"rx","time":"12:34:56","date":"24/5/2024","len":"125","packet_type":"4","#
            + #""route":"F","payload_len":"121","raw":"\#(Vectors.advert)","SNR":"7","RSSI":"-92","score":"780","#
            + #""duration":"469","hash":"\#(Vectors.advertHash)"}"#
        #expect(json == expected)
        // And it's valid JSON.
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String])
        #expect(object["origin"] == "Seattle \"Obs\"")
    }

    @Test func directPacketsCarryPathAndNegativeSNRTruncates() throws {
        let raw = try #require(Data(hexString: Vectors.textMessage))
        let json = try #require(ObserverUplink.packetMessage(raw: raw, snr: -3.75, rssi: -110, observer: observer, receivedAt: receivedAt))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String])
        #expect(object["route"] == "D")
        #expect(object["path"] == "3D -> 7C")
        #expect(object["SNR"] == "-3")
        #expect(object["score"] == "0")
        #expect(object["duration"] == "0")
        #expect(object["packet_type"] == "2")
        #expect(json.hasSuffix(#""path":"3D -> 7C"}"#))
    }

    @Test func undecodablePacketsAreSkipped() {
        #expect(ObserverUplink.packetMessage(raw: Data([0x11, 0xC1]), snr: 0, rssi: 0, observer: observer) == nil)
    }

    @Test func statusMessage() {
        let online = ObserverStatus(
            isOnline: true, radio: ObserverUplink.radioDescription(radio), model: "Heltec V3",
            firmwareVersion: "v1.18.0", clientVersion: "m-Core 1.0"
        )
        let expected = #"{"status":"online","timestamp":"2024-05-24T12:34:56.500000+00:00","origin":"Seattle \"Obs\"","#
            + #""origin_id":"\#(keyHex)","radio":"910.525,62.5,7,5","model":"Heltec V3","firmware_version":"v1.18.0","#
            + #""client_version":"m-Core 1.0"}"#
        #expect(ObserverUplink.statusMessage(online, observer: observer, at: receivedAt) == expected)

        let offline = ObserverStatus(isOnline: false, clientVersion: "m-Core 1.0")
        let json = ObserverUplink.statusMessage(offline, observer: observer, at: receivedAt)
        #expect(json.contains(#""status":"offline""#))
        #expect(json.contains(#""model":"unknown""#))
    }
}

struct MeshCoreAuthTokenTests {
    let key = PublicKey(bytes: Array(1...32))!
    let issuedAt = Date(timeIntervalSince1970: 1_700_000_000)

    /// Signing input produced by the reference Python implementation for the same inputs.
    let referenceInput = "eyJhbGciOiJFZDI1NTE5IiwidHlwIjoiSldUIn0."
        + "eyJwdWJsaWNLZXkiOiIwMTAyMDMwNDA1MDYwNzA4MDkwQTBCMEMwRDBFMEYxMDExMTIxMzE0MTUxNjE3MTgxOTFBMUIxQzFEMUUxRjIwIiwiaWF0Ijox"
        + "NzAwMDAwMDAwLCJleHAiOjE3MDAwMDM2MDAsImF1ZCI6Im1xdHQtdXMtdjEubGV0c21lc2gubmV0IiwiY2xpZW50IjoibS1Db3JlIDEuMCJ9"

    @Test func tokenLayoutMatchesReference() async throws {
        let signed = Recorder<Data>()
        let token = try await MeshCoreAuthToken.make(
            publicKey: key,
            issuedAt: issuedAt,
            claims: [("aud", "mqtt-us-v1.letsmesh.net"), ("client", "m-Core 1.0")],
            signer: { input in
                await signed.append(input)
                return Data((0..<64).map { UInt8($0) })
            }
        )
        let signature = Data((0..<64).map { UInt8($0) }).hexString.uppercased()
        #expect(token == referenceInput + "." + signature)
        #expect(await signed.values == [Data(referenceInput.utf8)])

        let parts = token.split(separator: ".")
        #expect(parts.count == 3)
        #expect(!token.contains("="))
        #expect(base64URLDecode(String(parts[0])) == #"{"alg":"Ed25519","typ":"JWT"}"#)
    }

    @Test func payloadClaimsInOrder() {
        let input = MeshCoreAuthToken.signingInput(publicKey: key, issuedAt: issuedAt, lifetime: 60, claims: [("owner", "Zoë")])
        let json = base64URLDecode(String(input.split(separator: ".")[1]))
        let expected = #"{"publicKey":"0102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F20","#
            + #""iat":1700000000,"exp":1700000060,"owner":"Zo\u00eb"}"#
        #expect(json == expected)
    }

    @Test func usernameAndBadSignature() async {
        #expect(MeshCoreAuthToken.username(for: key) == "v1_0102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F20")
        await #expect(throws: MeshCoreAuthToken.TokenError.invalidSignatureLength(3)) {
            try await MeshCoreAuthToken.make(publicKey: key, issuedAt: issuedAt, signer: { _ in Data([1, 2, 3]) })
        }
    }

    private func base64URLDecode(_ text: String) -> String? {
        let padded = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            + String(repeating: "=", count: (4 - text.count % 4) % 4)
        return Data(base64Encoded: padded).map { String(decoding: $0, as: UTF8.self) }
    }
}
