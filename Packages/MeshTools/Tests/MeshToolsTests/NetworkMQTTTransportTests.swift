import Foundation
import Network
import Synchronization
import Testing
@testable import MeshTools

/// Loopback tests against a real Network.framework WebSocket server.
struct NetworkMQTTTransportTests {
    /// A one-shot local WebSocket server that sends `messages` to the first client.
    private final class WebSocketServer: Sendable {
        let listener: NWListener
        private let queue = DispatchQueue(label: "test.ws.server")
        private let connections = Mutex<[NWConnection]>([])

        init(messages: [(NWProtocolWebSocket.Opcode, Data)]) throws {
            let parameters = NWParameters.tcp
            parameters.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
            listener = try NWListener(using: parameters, on: .any)
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                connections.withLock { $0.append(connection) }
                connection.start(queue: queue)
                for (opcode, data) in messages {
                    let context = NWConnection.ContentContext(identifier: "m", metadata: [NWProtocolWebSocket.Metadata(opcode: opcode)])
                    connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
                }
            }
        }

        func start() async throws -> UInt16 {
            let started = ResumeOnce()
            return try await withCheckedThrowingContinuation { continuation in
                listener.stateUpdateHandler = { [listener] state in
                    switch state {
                    case .ready: started.run { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                    case .failed(let error): started.run { continuation.resume(throwing: error) }
                    default: break
                    }
                }
                listener.start(queue: queue)
            }
        }

        func stop() {
            listener.cancel()
            connections.withLock { $0.forEach { $0.cancel() } }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func webSocketPingPayloadIsNotDeliveredAsMQTTBytes() async throws {
        // Network.framework hands pings to receiveMessage even with autoReplyPing; their payload used to be
        // returned as broker bytes and fed into the MQTT parser.
        let connack = Data([0x20, 0x02, 0x00, 0x00])
        let server = try WebSocketServer(messages: [(.ping, Data("abc".utf8)), (.binary, connack)])
        let port = try await server.start()
        defer { server.stop() }

        let transport = NetworkMQTTTransport(endpoint: MQTTEndpoint(host: "127.0.0.1", port: port, kind: .webSocket(path: "/mqtt")))
        try await transport.open()
        #expect(try await transport.receive() == connack)
        await transport.close()
    }
}
