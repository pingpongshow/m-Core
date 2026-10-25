import Foundation
import Testing
@testable import MeshTools

struct MQTTCodecTests {
    @Test func remainingLengthBoundaries() throws {
        let cases: [(Int, [UInt8])] = [
            (0, [0x00]), (127, [0x7F]), (128, [0x80, 0x01]), (16_383, [0xFF, 0x7F]),
            (16_384, [0x80, 0x80, 0x01]), (2_097_151, [0xFF, 0xFF, 0x7F]),
            (2_097_152, [0x80, 0x80, 0x80, 0x01]), (268_435_455, [0xFF, 0xFF, 0xFF, 0x7F]),
        ]
        for (value, bytes) in cases {
            #expect(try MQTTCodec.encodeRemainingLength(value) == bytes)
            let decoded = try MQTTCodec.decodeRemainingLength([0x30] + bytes, from: 1)
            #expect(decoded?.value == value)
            #expect(decoded?.byteCount == bytes.count)
        }
        #expect(throws: MQTTCodecError.packetTooLarge) { try MQTTCodec.encodeRemainingLength(268_435_456) }
        #expect(throws: MQTTCodecError.malformedRemainingLength) {
            try MQTTCodec.decodeRemainingLength([0xFF, 0xFF, 0xFF, 0xFF, 0x01], from: 0)
        }
        #expect(try MQTTCodec.decodeRemainingLength([0x30, 0x80], from: 1) == nil)
    }

    @Test func connectWithCredentials() throws {
        let options = MQTTConnectOptions(clientID: "m", keepAlive: 60, username: "u", password: "p")
        let expected = "10130004" + "4D515454" + "04C2003C" + "00016D" + "000175" + "000170"
        #expect(try MQTTCodec.connect(options).hexString.uppercased() == expected)
    }

    @Test func connectWithWillAndNoCredentials() throws {
        let will = MQTTWill(topic: "t", payload: Data("x".utf8), qos: .atLeastOnce, retain: true)
        let options = MQTTConnectOptions(clientID: "c", cleanSession: true, keepAlive: 0, will: will)
        // Flags: clean 0x02 | will 0x04 | will QoS1 0x08 | will retain 0x20 = 0x2E.
        let expected = "1013" + "00044D51545404" + "2E" + "0000" + "000163" + "000174" + "000178"
        #expect(try MQTTCodec.connect(options).hexString.uppercased() == expected)
    }

    @Test func publishEncoding() throws {
        let qos0 = try MQTTCodec.publish(topic: "a/b", payload: Data("hi".utf8), qos: .atMostOnce, retain: false, packetID: nil)
        #expect(qos0.hexString.uppercased() == "3007" + "0003612F62" + "6869")
        let qos1 = try MQTTCodec.publish(topic: "a", payload: Data([0xFF]), qos: .atLeastOnce, retain: true, packetID: 0x0102)
        #expect(qos1.hexString.uppercased() == "3306" + "000161" + "0102" + "FF")
    }

    @Test func frameParserReassemblesSplitAndMergedReads() throws {
        var parser = MQTTFrameParser()
        let stream = Data([0x20, 0x02, 0x00, 0x00, 0xD0, 0x00, 0x40, 0x02, 0x00, 0x07])
        var packets: [MQTTInboundPacket] = []
        for byte in stream {
            packets += try parser.feed(Data([byte]))
        }
        #expect(packets == [.connack(sessionPresent: false, returnCode: 0), .pingresp, .puback(packetID: 7)])
        #expect(try parser.feed(stream) == packets)
        #expect(parser.bufferedByteCount == 0)

        // A large PUBLISH split at awkward places, including inside the length varint.
        let big = try MQTTCodec.publish(
            topic: "x", payload: Data(repeating: 0xAB, count: 300), qos: .atMostOnce, retain: false, packetID: nil
        )
        #expect(try parser.feed(big.prefix(2)).isEmpty)
        #expect(try parser.feed(big.dropFirst(2).prefix(100)).isEmpty)
        let decoded = try parser.feed(big.dropFirst(102))
        #expect(decoded == [.publish(topic: "x", payload: Data(repeating: 0xAB, count: 300), qos: 0, packetID: nil, retain: false)])
    }

    @Test func endpointURLs() {
        #expect(MQTTEndpoint(host: "mqtt.example.net", port: 443, kind: .secureWebSocket(path: "/mqtt")).webSocketURL?.absoluteString
            == "wss://mqtt.example.net:443/mqtt")
        #expect(MQTTEndpoint(host: "h", port: 80, kind: .webSocket(path: "mqtt")).webSocketURL?.absoluteString == "ws://h:80/mqtt")
        #expect(MQTTEndpoint(host: "h", port: 8883, kind: .tls).webSocketURL == nil)
        #expect(MQTTEndpoint(host: "h", port: 8883, kind: .tls).usesTLS)
    }
}

struct MQTTClientTests {
    private func makeClient(_ broker: FakeBroker, keepAlive: UInt16 = 0, ping: Duration? = nil) -> MQTTClient {
        MQTTClient(
            transport: broker,
            options: MQTTConnectOptions(clientID: "meshcore_TEST", keepAlive: keepAlive, username: "v1_AB", password: "token"),
            connectTimeout: .milliseconds(300),
            pingInterval: ping,
            ackTimeout: .milliseconds(300)
        )
    }

    @Test func connectTimesOutWhenTheTransportNeverOpens() async throws {
        let client = MQTTClient(
            transport: SilentTransport(),
            options: MQTTConnectOptions(clientID: "meshcore_TEST"),
            connectTimeout: .milliseconds(200)
        )
        let started = ContinuousClock.now
        await #expect(throws: MQTTClientError.timeout) { try await client.connect() }
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(await client.state == .failed(.timeout))
    }

    @Test func connectPublishDisconnect() async throws {
        let broker = FakeBroker()
        let client = makeClient(broker)
        let recorder = Recorder<MQTTConnectionState>()
        let stream = await client.stateUpdates()
        let watcher = Task {
            for await state in stream {
                await recorder.append(state)
            }
        }

        try await client.connect()
        try await client.publish(topic: "meshcore/SEA/AB/packets", string: "{}")
        await client.disconnect()

        #expect(await broker.packetTypes == [1, 3, 14])
        #expect(await broker.sent.last == MQTTCodec.disconnect)
        #expect(await broker.publishes == [
            .publish(topic: "meshcore/SEA/AB/packets", payload: Data("{}".utf8), qos: 0, packetID: nil, retain: false),
        ])
        #expect(await eventually { await recorder.values.count >= 4 })
        #expect(await recorder.values == [.disconnected, .connecting, .connected, .disconnected])
        watcher.cancel()
    }

    @Test func refusedConnectionReportsReturnCode() async throws {
        let broker = FakeBroker()
        await broker.set(connackCode: 4)
        let client = makeClient(broker)
        await #expect(throws: MQTTClientError.refused(.badUsernameOrPassword)) { try await client.connect() }
        #expect(await client.state == .failed(.refused(.badUsernameOrPassword)))
        #expect(await !broker.isOpen)
        await #expect(throws: MQTTClientError.notConnected) { try await client.publish(topic: "t", string: "x") }
    }

    @Test func unknownReturnCode() async throws {
        let broker = FakeBroker()
        await broker.set(connackCode: 9)
        await #expect(throws: MQTTClientError.unknownReturnCode(9)) { try await makeClient(broker).connect() }
    }

    @Test func connackSplitAcrossReads() async throws {
        let broker = FakeBroker()
        await broker.set(splitReplies: true)
        let client = makeClient(broker)
        try await client.connect()
        try await client.publish(topic: "t", payload: Data([1]), qos: .atLeastOnce)
        #expect(await client.state == .connected)
    }

    @Test func qos1WaitsForPubackWithIncrementingIDs() async throws {
        let broker = FakeBroker()
        let client = makeClient(broker)
        try await client.connect()
        try await client.publish(topic: "t", string: "a", qos: .atLeastOnce)
        try await client.publish(topic: "t", string: "b", qos: .atLeastOnce, retain: true)
        let ids = await broker.publishes.compactMap { packet -> UInt16? in
            if case .publish(_, _, 1, let id, _) = packet { id } else { nil }
        }
        #expect(ids == [1, 2])

        await broker.set(acksPublishes: false)
        await #expect(throws: MQTTClientError.timeout) { try await client.publish(topic: "t", string: "c", qos: .atLeastOnce) }
        #expect(await client.state == .connected)
    }

    @Test func qos1PublishFailsPromptlyWhenTheLinkDropsMidSend() async throws {
        // The drop cancelled all ack waiters before this publish registered its own, which then sat
        // out the whole ack timeout and reported `.timeout` instead of the real cause.
        let broker = FakeBroker()
        let client = MQTTClient(
            transport: broker, options: MQTTConnectOptions(clientID: "c", keepAlive: 0), ackTimeout: .seconds(5)
        )
        try await client.connect()
        await broker.set(hangsUpDuringPublish: true)

        let clock = ContinuousClock()
        let elapsed = await clock.measure {
            await #expect(throws: MQTTClientError.connectionClosed) {
                try await client.publish(topic: "t", string: "x", qos: .atLeastOnce)
            }
        }
        #expect(elapsed < .seconds(2))
        #expect(await client.state == .failed(.connectionClosed))
    }

    @Test func connectTimesOutWithoutConnack() async throws {
        let broker = FakeBroker()
        await broker.set(answersConnect: false)
        let client = makeClient(broker)
        await #expect(throws: MQTTClientError.timeout) { try await client.connect() }
        #expect(await client.state == .failed(.timeout))
    }

    @Test func keepAlivePingsAndDetectsDeadBroker() async throws {
        let broker = FakeBroker()
        let client = makeClient(broker, keepAlive: 1, ping: .milliseconds(20))
        try await client.connect()
        #expect(await eventually { await broker.packetTypes.filter { $0 == 12 }.count >= 3 })
        #expect(await client.state == .connected)

        await broker.set(answersPings: false)
        #expect(await eventually { await client.state == .failed(.keepAliveTimeout) })
    }

    @Test func brokerHangUpFailsConnection() async throws {
        let broker = FakeBroker()
        let client = makeClient(broker)
        try await client.connect()
        await broker.hangUp()
        #expect(await eventually { await client.state == .failed(.connectionClosed) })

        // The client can reconnect afterwards.
        try await client.connect()
        #expect(await client.state == .connected)
    }

    @Test func malformedBrokerBytesFailConnection() async throws {
        let broker = FakeBroker()
        let client = makeClient(broker)
        try await client.connect()
        await broker.push(Data([0x30, 0xFF, 0xFF, 0xFF, 0xFF, 0x01]))
        #expect(await eventually { await client.state == .failed(.codec(.malformedRemainingLength)) })
    }
}

/// A host that never answers: `open()` waits until cancelled.
private struct SilentTransport: MQTTTransport {
    func open() async throws { try await Task.sleep(for: .seconds(60)) }
    func send(_ data: Data) async throws {}
    func receive() async throws -> Data? { nil }
    func close() async {}
}
