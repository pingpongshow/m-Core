import Foundation
import Network
import Synchronization

/// `MQTTTransport` over Network.framework: plain TCP, TLS, or WebSocket (ws/wss, subprotocol "mqtt").
public final class NetworkMQTTTransport: MQTTTransport {
    public let endpoint: MQTTEndpoint
    private let queue = DispatchQueue(label: "m-core.mqtt.transport")
    private let state = Mutex<NWConnection?>(nil)

    public init(endpoint: MQTTEndpoint) {
        self.endpoint = endpoint
    }

    public func open() async throws {
        let connection = try makeConnection()
        state.withLock { $0 = connection }
        let gate = ResumeOnce()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.stateUpdateHandler = { newState in
                    switch newState {
                    case .ready:
                        gate.run { continuation.resume() }
                    case .failed(let error), .waiting(let error):
                        gate.run { continuation.resume(throwing: MQTTTransportError.connectionFailed(error.localizedDescription)) }
                        connection.cancel()
                    case .cancelled:
                        gate.run { continuation.resume(throwing: MQTTTransportError.cancelled) }
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            connection.cancel()
        }
    }

    public func send(_ data: Data) async throws {
        guard let connection = state.withLock({ $0 }) else { throw MQTTTransportError.notOpen }
        let context: NWConnection.ContentContext
        if endpoint.webSocketURL != nil {
            let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
            context = NWConnection.ContentContext(identifier: "mqtt", metadata: [metadata])
        } else {
            context = .defaultMessage
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: MQTTTransportError.connectionFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    public func receive() async throws -> Data? {
        guard let connection = state.withLock({ $0 }) else { throw MQTTTransportError.notOpen }
        let isWebSocket = endpoint.webSocketURL != nil
        while true {
            let (data, isFinished) = try await receiveChunk(on: connection, webSocket: isWebSocket)
            if let data, !data.isEmpty { return data }
            if isFinished { return nil }
        }
    }

    public func close() async {
        let connection = state.withLock { current in
            defer { current = nil }
            return current
        }
        connection?.cancel()
    }

    private func receiveChunk(on connection: NWConnection, webSocket: Bool) async throws -> (Data?, Bool) {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data?, Bool), Error>) in
            let handler: @Sendable (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void = { data, context, isComplete, error in
                if let error {
                    continuation.resume(throwing: MQTTTransportError.connectionFailed(error.localizedDescription))
                    return
                }
                if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata {
                    switch metadata.opcode {
                    case .close:
                        continuation.resume(returning: (nil, true))
                        return
                    case .ping, .pong:
                        // Still delivered with `autoReplyPing`; their payload isn't MQTT data and would corrupt framing.
                        continuation.resume(returning: (nil, false))
                        return
                    default:
                        break
                    }
                }
                let finished = webSocket ? (data == nil && context?.isFinal == true) : (isComplete && (data?.isEmpty ?? true))
                continuation.resume(returning: (data, finished))
            }
            if webSocket {
                connection.receiveMessage(completion: handler)
            } else {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536, completion: handler)
            }
        }
    }

    private func makeConnection() throws -> NWConnection {
        let parameters = endpoint.usesTLS ? NWParameters(tls: NWProtocolTLS.Options(), tcp: NWProtocolTCP.Options()) : .tcp
        if let url = endpoint.webSocketURL {
            let options = NWProtocolWebSocket.Options()
            options.autoReplyPing = true
            options.setSubprotocols(["mqtt"])
            parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
            return NWConnection(to: .url(url), using: parameters)
        }
        guard let port = NWEndpoint.Port(rawValue: endpoint.port), !endpoint.host.isEmpty else {
            throw MQTTTransportError.invalidEndpoint
        }
        return NWConnection(host: NWEndpoint.Host(endpoint.host), port: port, using: parameters)
    }
}

/// Runs a closure at most once across threads; guards continuation resumption.
final class ResumeOnce: Sendable {
    private let done = Mutex(false)

    func run(_ body: () -> Void) {
        let first = done.withLock { done in
            defer { done = true }
            return !done
        }
        if first { body() }
    }
}
