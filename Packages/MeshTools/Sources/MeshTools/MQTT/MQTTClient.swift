import Foundation

/// Connection lifecycle of an `MQTTClient`.
public enum MQTTConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    /// The connection attempt or an established connection failed.
    case failed(MQTTClientError)
}

public enum MQTTClientError: Error, Equatable, Sendable {
    case notConnected
    case alreadyConnecting
    case refused(MQTTConnectRefusal)
    case unknownReturnCode(UInt8)
    case unexpectedPacket(String)
    case timeout
    /// No PINGRESP arrived before the next ping was due.
    case keepAliveTimeout
    case connectionClosed
    case codec(MQTTCodecError)
    case transport(String)
}

/// A minimal MQTT 3.1.1 publisher: CONNECT/CONNACK, PUBLISH (QoS 0 and 1), PINGREQ keep-alive, DISCONNECT.
///
/// Inbound PUBLISH packets are ignored (the client never subscribes).
public actor MQTTClient {
    public let options: MQTTConnectOptions
    private let transport: any MQTTTransport
    private let connectTimeout: Duration
    private let pingInterval: Duration?
    private let ackTimeout: Duration

    public private(set) var state: MQTTConnectionState = .disconnected
    private var observers: [UUID: AsyncStream<MQTTConnectionState>.Continuation] = [:]

    private var parser = MQTTFrameParser()
    private var readerTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    private var connackWaiter: CheckedContinuation<Void, Error>?
    private var bufferedConnack: Result<Void, MQTTClientError>?
    private var awaitingPingResponse = false
    private var isFailing = false
    private var lastPacketID: UInt16 = 0
    private var ackWaiters: [UInt16: CheckedContinuation<Void, Error>] = [:]
    private var receivedAcks: Set<UInt16> = []

    /// - Parameters:
    ///   - pingInterval: How often to send PINGREQ; defaults to the keep-alive period. A ping still
    ///     unanswered when the next one is due fails the connection.
    public init(
        transport: any MQTTTransport,
        options: MQTTConnectOptions,
        connectTimeout: Duration = .seconds(10),
        pingInterval: Duration? = nil,
        ackTimeout: Duration = .seconds(10)
    ) {
        self.transport = transport
        self.options = options
        self.connectTimeout = connectTimeout
        self.pingInterval = pingInterval ?? (options.keepAlive > 0 ? .seconds(Int(options.keepAlive)) : nil)
        self.ackTimeout = ackTimeout
    }

    /// A client using Network.framework to reach `endpoint`.
    public init(endpoint: MQTTEndpoint, options: MQTTConnectOptions) {
        self.init(transport: NetworkMQTTTransport(endpoint: endpoint), options: options)
    }

    /// Current state followed by every change. Each call returns an independent stream.
    public func stateUpdates() -> AsyncStream<MQTTConnectionState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<MQTTConnectionState>.makeStream(bufferingPolicy: .bufferingNewest(16))
        continuation.yield(state)
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }

    /// Opens the transport, sends CONNECT and waits for an accepting CONNACK.
    /// Opens the transport within `connectTimeout`; the OS alone can take over a minute to give up on a silent host.
    private func openTransport() async throws {
        let transport = transport
        let timeout = connectTimeout
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await transport.open() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw MQTTClientError.timeout
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    public func connect() async throws {
        switch state {
        case .connected: return
        case .connecting: throw MQTTClientError.alreadyConnecting
        case .disconnected, .failed: break
        }
        setState(.connecting)
        parser = MQTTFrameParser()
        bufferedConnack = nil
        awaitingPingResponse = false
        do {
            try await openTransport()
            startReader()
            try await send(try MQTTCodec.connect(options))
            try await waitForConnack()
        } catch {
            let failure = Self.clientError(error)
            if state == .connecting { await fail(failure) }
            throw failure
        }
        guard state == .connecting else { throw MQTTClientError.connectionClosed }
        setState(.connected)
        startKeepAlive()
    }

    /// Publishes a message. QoS 1 waits for the broker's PUBACK.
    public func publish(topic: String, payload: Data, qos: MQTTQoS = .atMostOnce, retain: Bool = false) async throws {
        guard state == .connected else { throw MQTTClientError.notConnected }
        switch qos {
        case .atMostOnce:
            try await send(try MQTTCodec.publish(topic: topic, payload: payload, qos: qos, retain: retain, packetID: nil))
        case .atLeastOnce:
            let id = nextPacketID()
            try await send(try MQTTCodec.publish(topic: topic, payload: payload, qos: qos, retain: retain, packetID: id))
            try await waitForAck(id)
        }
    }

    public func publish(topic: String, string: String, qos: MQTTQoS = .atMostOnce, retain: Bool = false) async throws {
        try await publish(topic: topic, payload: Data(string.utf8), qos: qos, retain: retain)
    }

    /// Sends DISCONNECT (so the broker discards the will) and closes the transport.
    public func disconnect() async {
        if state == .connected {
            try? await transport.send(MQTTCodec.disconnect)
        }
        setState(.disconnected)
        cancelWork(error: .notConnected)
        await transport.close()
    }

    // MARK: - Internals

    private func send(_ data: Data) async throws {
        do {
            try await transport.send(data)
        } catch {
            throw Self.clientError(error)
        }
    }

    private func startReader() {
        readerTask?.cancel()
        let transport = transport
        readerTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    guard let chunk = try await transport.receive() else {
                        await self?.connectionLost(.connectionClosed)
                        return
                    }
                    await self?.ingest(chunk)
                }
            } catch {
                await self?.connectionLost(Self.clientError(error))
            }
        }
    }

    private func startKeepAlive() {
        keepAliveTask?.cancel()
        guard let interval = pingInterval else { return }
        keepAliveTask = Task { [weak self] in
            while true {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard let self, await self.sendPing() else { return }
            }
        }
    }

    /// Returns false when keep-alive should stop.
    private func sendPing() async -> Bool {
        guard state == .connected else { return false }
        if awaitingPingResponse {
            await connectionLost(.keepAliveTimeout)
            return false
        }
        awaitingPingResponse = true
        do {
            try await transport.send(MQTTCodec.pingreq)
            return true
        } catch {
            await connectionLost(Self.clientError(error))
            return false
        }
    }

    private func ingest(_ chunk: Data) async {
        do {
            for packet in try parser.feed(chunk) {
                handle(packet)
            }
        } catch {
            await connectionLost(.codec(error))
        }
    }

    private func handle(_ packet: MQTTInboundPacket) {
        switch packet {
        case .connack(_, let code):
            let result: Result<Void, MQTTClientError>
            if code == 0 {
                result = .success(())
            } else if let refusal = MQTTConnectRefusal(rawValue: code) {
                result = .failure(.refused(refusal))
            } else {
                result = .failure(.unknownReturnCode(code))
            }
            resolveConnack(result)
        case .puback(let id):
            if let waiter = ackWaiters.removeValue(forKey: id) {
                waiter.resume()
            } else {
                receivedAcks.insert(id)
            }
        case .pingresp:
            awaitingPingResponse = false
        case .publish(_, _, let qos, let id, _):
            if qos == 1, let id {
                Task { try? await transport.send(MQTTCodec.puback(packetID: id)) }
            }
        case .other:
            break
        }
    }

    private func connectionLost(_ error: MQTTClientError) async {
        guard state == .connected || state == .connecting else { return }
        await fail(error)
    }

    /// Stops background work, closes the transport, then publishes the failure.
    private func fail(_ error: MQTTClientError) async {
        guard !isFailing else { return }
        isFailing = true
        cancelWork(error: error)
        await transport.close()
        isFailing = false
        setState(.failed(error))
    }

    private func cancelWork(error: MQTTClientError) {
        readerTask?.cancel()
        readerTask = nil
        keepAliveTask?.cancel()
        keepAliveTask = nil
        if let waiter = connackWaiter {
            connackWaiter = nil
            waiter.resume(throwing: error)
        }
        let waiters = ackWaiters
        ackWaiters.removeAll()
        receivedAcks.removeAll()
        for waiter in waiters.values {
            waiter.resume(throwing: error)
        }
    }

    private func setState(_ newState: MQTTConnectionState) {
        guard newState != state else { return }
        state = newState
        for observer in observers.values {
            observer.yield(newState)
        }
    }

    private func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }
}

// MARK: - Acknowledgement waits

extension MQTTClient {
    private func waitForConnack() async throws {
        if let buffered = bufferedConnack {
            bufferedConnack = nil
            return try buffered.get()
        }
        // The link may have dropped while CONNECT was being sent; nothing would resume the waiter then.
        guard state == .connecting, !isFailing else { throw lostConnectionError }
        let timeout = connectTimeout
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { await self?.resolveConnack(.failure(.timeout)) }
        }
        defer { timer.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connackWaiter = continuation
        }
    }

    private func resolveConnack(_ result: Result<Void, MQTTClientError>) {
        guard let waiter = connackWaiter else {
            if state == .connecting { bufferedConnack = result }
            return
        }
        connackWaiter = nil
        waiter.resume(with: result.mapError { $0 as Error })
    }

    private func waitForAck(_ id: UInt16) async throws {
        if receivedAcks.remove(id) != nil { return }
        // As above: a failure during the PUBLISH send already cancelled every waiter.
        guard state == .connected, !isFailing else { throw lostConnectionError }
        let timeout = ackTimeout
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { await self?.failAck(id, .timeout) }
        }
        defer { timer.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            ackWaiters[id] = continuation
        }
    }

    /// Why a wait can't start: the failure being (or already) reported, or `notConnected` after `disconnect()`.
    private var lostConnectionError: MQTTClientError {
        if isFailing { return .connectionClosed }
        if case .failed(let error) = state { return error }
        return .notConnected
    }

    private func failAck(_ id: UInt16, _ error: MQTTClientError) {
        ackWaiters.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func nextPacketID() -> UInt16 {
        lastPacketID = lastPacketID == UInt16.max ? 1 : lastPacketID + 1
        return lastPacketID
    }

    private static func clientError(_ error: any Error) -> MQTTClientError {
        switch error {
        case let error as MQTTClientError: error
        case let error as MQTTCodecError: .codec(error)
        case let error as MQTTTransportError: error == .cancelled ? .connectionClosed : .transport(String(describing: error))
        default: .transport(error.localizedDescription)
        }
    }
}
