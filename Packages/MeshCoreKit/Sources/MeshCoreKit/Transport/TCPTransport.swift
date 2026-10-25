import Foundation
import Network
import Synchronization

/// Connects to a Wi‑Fi companion build over TCP (default port 5000) using serial-style framing.
public final class TCPTransport: MeshTransport {
    public let host: String
    public let port: UInt16
    private let connectTimeout: Duration
    private let queue = DispatchQueue(label: "app.mcore.tcp")

    private struct State {
        var connection: NWConnection?
        var continuation: AsyncThrowingStream<Data, Error>.Continuation?
        var deframer = SerialFraming.Deframer()
    }

    private let state = Mutex(State())

    public init(host: String, port: UInt16 = MeshCoreProtocol.defaultTCPPort, connectTimeout: Duration = .seconds(10)) {
        self.host = host
        self.port = port
        self.connectTimeout = connectTimeout
    }

    public func open() async throws -> AsyncThrowingStream<Data, Error> {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw TransportError.connectionFailed("invalid port \(port)")
        }
        let options = NWProtocolTCP.Options()
        options.noDelay = true
        options.enableKeepalive = true
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: NWParameters(tls: nil, tcp: options))
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        try state.withLock { state in
            guard state.connection == nil else { throw TransportError.alreadyOpen }
            state.connection = connection
            state.continuation = continuation
            state.deframer = SerialFraming.Deframer()
        }

        do {
            try await waitUntilReady(connection)
        } catch {
            connection.cancel()
            state.withLock { $0 = State() }
            throw error
        }
        receive(on: connection)
        return stream
    }

    public func send(_ frame: Data) async throws {
        guard let connection = state.withLock({ $0.connection }) else { throw TransportError.notOpen }
        let bytes = try SerialFraming.encode(frame)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: bytes, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: TransportError.disconnected(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    public func close() async {
        finish(error: nil)
    }

    // MARK: - Private

    private func waitUntilReady(_ connection: NWConnection) async throws {
        let resumed = Mutex(false)
        let timeout = connectTimeout
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumeOnce: @Sendable (Result<Void, Error>) -> Void = { result in
                let first = resumed.withLock { done in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(with: result) }
            }
            connection.stateUpdateHandler = { [weak self] newState in
                switch newState {
                case .ready:
                    resumeOnce(.success(()))
                case .failed(let error):
                    resumeOnce(.failure(TransportError.connectionFailed(error.localizedDescription)))
                    self?.finish(error: TransportError.disconnected(error.localizedDescription))
                case .waiting(let error):
                    // No route yet (e.g. radio offline); fail fast instead of waiting indefinitely.
                    resumeOnce(.failure(TransportError.connectionFailed(error.localizedDescription)))
                case .cancelled:
                    resumeOnce(.failure(TransportError.disconnected(nil)))
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout.timeInterval) {
                resumeOnce(.failure(TransportError.timedOut))
            }
        }
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                let (frames, continuation) = self.state.withLock { state in
                    (state.deframer.append(data), state.continuation)
                }
                frames.forEach { continuation?.yield($0) }
            }
            if let error {
                self.finish(error: TransportError.disconnected(error.localizedDescription))
            } else if isComplete {
                self.finish(error: TransportError.disconnected("connection closed by radio"))
            } else {
                self.receive(on: connection)
            }
        }
    }

    private func finish(error: Error?) {
        let (connection, continuation) = state.withLock { state in
            defer { state = State() }
            return (state.connection, state.continuation)
        }
        // Keep the state handler: cancelling delivers `.cancelled`, which releases a pending `open()`.
        connection?.cancel()
        if let error {
            continuation?.finish(throwing: error)
        } else {
            continuation?.finish()
        }
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
