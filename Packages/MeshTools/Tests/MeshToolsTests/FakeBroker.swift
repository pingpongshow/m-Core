import Foundation
@testable import MeshTools

/// In-memory MQTT broker speaking through the `MQTTTransport` interface. No sockets involved.
actor FakeBroker: MQTTTransport {
    var connackCode: UInt8 = 0
    var answersConnect = true
    var answersPings = true
    var acksPublishes = true
    /// Deliver every reply one byte per chunk to exercise reassembly.
    var splitReplies = false
    /// Drop the connection while a PUBLISH is still being sent (the send returns afterwards).
    var hangsUpDuringPublish = false

    private(set) var sent: [Data] = []
    private(set) var received: [MQTTInboundPacket] = []
    private(set) var isOpen = false
    private var parser = MQTTFrameParser()
    private var inbox: [Data?] = []
    private var waiters: [CheckedContinuation<Data?, Never>] = []

    func set(
        connackCode: UInt8? = nil,
        answersConnect: Bool? = nil,
        answersPings: Bool? = nil,
        acksPublishes: Bool? = nil,
        splitReplies: Bool? = nil,
        hangsUpDuringPublish: Bool? = nil
    ) {
        if let hangsUpDuringPublish { self.hangsUpDuringPublish = hangsUpDuringPublish }
        if let acksPublishes { self.acksPublishes = acksPublishes }
        if let connackCode { self.connackCode = connackCode }
        if let answersConnect { self.answersConnect = answersConnect }
        if let answersPings { self.answersPings = answersPings }
        if let splitReplies { self.splitReplies = splitReplies }
    }

    var packetTypes: [UInt8] {
        received.map { packet in
            switch packet {
            case .connack: 2
            case .publish: 3
            case .puback: 4
            case .pingresp: 13
            case .other(let type, _, _): type
            }
        }
    }

    var publishes: [MQTTInboundPacket] {
        received.filter { if case .publish = $0 { true } else { false } }
    }

    // MARK: MQTTTransport

    func open() async throws {
        isOpen = true
        inbox.removeAll()
    }

    func send(_ data: Data) async throws {
        guard isOpen else { throw MQTTTransportError.notOpen }
        sent.append(data)
        for packet in try parser.feed(data) {
            received.append(packet)
            if hangsUpDuringPublish, case .publish = packet {
                hangUp()
                try? await Task.sleep(for: .milliseconds(100)) // let the client notice before the send completes
                return
            }
            respond(to: packet)
        }
    }

    func receive() async throws -> Data? {
        if !inbox.isEmpty { return inbox.removeFirst() }
        guard isOpen else { return nil }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func close() async {
        isOpen = false
        deliver(nil)
    }

    // MARK: Broker side

    /// Sends bytes to the client as one chunk.
    func push(_ data: Data) {
        deliver(data)
    }

    /// Simulates the broker dropping the connection.
    func hangUp() {
        deliver(nil)
    }

    private func respond(to packet: MQTTInboundPacket) {
        switch packet {
        case .other(type: 1, _, _) where answersConnect:
            reply(Data([0x20, 0x02, 0x00, connackCode]))
        case .other(type: 12, _, _) where answersPings:
            reply(Data([0xD0, 0x00]))
        case .publish(_, _, 1, let id?, _) where acksPublishes:
            reply(MQTTCodec.puback(packetID: id))
        default:
            break
        }
    }

    private func reply(_ data: Data) {
        if splitReplies {
            data.forEach { deliver(Data([$0])) }
        } else {
            deliver(data)
        }
    }

    private func deliver(_ chunk: Data?) {
        if waiters.isEmpty {
            inbox.append(chunk)
        } else {
            waiters.removeFirst().resume(returning: chunk)
        }
    }
}

/// Collects values from an async sequence for later inspection.
actor Recorder<Value: Sendable> {
    private(set) var values: [Value] = []

    func append(_ value: Value) {
        values.append(value)
    }
}

/// Polls `condition` until it holds or `timeout` passes.
func eventually(timeout: Duration = .seconds(2), _ condition: @Sendable () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}
