import Foundation
import os

public enum MeshError: Error, Equatable, Sendable {
    case notConnected
    /// No reply within the response timeout.
    case timeout(CommandCode)
    /// The radio answered with `RESP_CODE_ERR`.
    case device(MeshErrorCode?, CommandCode)
    /// The firmware build has this feature disabled.
    case disabled(CommandCode)
    case unexpectedResponse(Response, CommandCode)
    case decoding(FrameDecodingError)
    case transport(String)
}

/// Result of setting the radio clock from the phone. The firmware only accepts forward jumps.
public enum ClockSyncResult: Equatable, Sendable {
    case updated(to: UInt32)
    /// The radio clock was already ahead, so it kept its own time.
    case radioAhead(radioTime: UInt32)
}

/// What the handshake learned about the radio.
public struct ConnectionInfo: Equatable, Sendable {
    public var device: DeviceInfo
    public var selfInfo: SelfInfo
    public var clockSync: ClockSyncResult
}

/// Contacts returned by `getContacts`, plus the value to pass as `since` next time.
public struct ContactList: Equatable, Sendable {
    public var contacts: [Contact]
    /// Total contacts stored on the radio (not just those returned).
    public var totalCount: UInt32
    public var lastModified: UInt32
}

/// One open connection to a radio. Commands run one at a time in call order; pushes stream separately.
/// The session ends when the transport closes; `MeshConnection` creates a new one to reconnect.
public actor MeshSession {
    nonisolated public let pushes: AsyncStream<Push>
    private let pushContinuation: AsyncStream<Push>.Continuation
    private let transport: any MeshTransport
    private let responseTimeout: Duration
    private let logger = Logger(subsystem: "app.mcore", category: "MeshSession")

    private struct PendingRequest {
        let id: UInt64
        let command: CommandCode
        var collected: [Response]
        let accepts: @Sendable (Response) -> Bool
        let isComplete: @Sendable ([Response]) -> Bool
        let continuation: CheckedContinuation<[Response], Error>
    }

    private var isOpen = false
    private var readerTask: Task<Void, Never>?
    private var pending: PendingRequest?
    private var timeoutTask: Task<Void, Never>?
    private var nextRequestID: UInt64 = 0
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var endedContinuations: [CheckedContinuation<Void, Never>] = []
    private var hasEnded = false

    public init(transport: any MeshTransport, responseTimeout: Duration = .seconds(5)) {
        self.transport = transport
        self.responseTimeout = responseTimeout
        (pushes, pushContinuation) = AsyncStream<Push>.makeStream(bufferingPolicy: .bufferingNewest(256))
    }

    /// Opens the transport and starts reading frames.
    public func open() async throws {
        guard !isOpen, !hasEnded else { throw MeshError.transport("session already used") }
        let frames: AsyncThrowingStream<Data, Error>
        do {
            frames = try await transport.open()
        } catch {
            end(reason: error)
            throw MeshError.transport(error.localizedDescription)
        }
        isOpen = true
        readerTask = Task { [weak self] in
            var failure: Error?
            do {
                for try await frame in frames {
                    await self?.handle(frame)
                }
            } catch {
                failure = error
            }
            await self?.end(reason: failure)
        }
    }

    /// Closes the transport. Pending and queued commands fail with `notConnected`.
    public func close() async {
        await transport.close()
        end(reason: nil)
    }

    /// Waits until the session has ended (transport closed or failed).
    public func waitUntilEnded() async {
        if hasEnded { return }
        await withCheckedContinuation { endedContinuations.append($0) }
    }

    // MARK: - Sending

    /// Sends a command and returns its single-frame reply (which may be `.error`).
    /// - Parameter accepts: Replies that belong to this command; anything else is treated as stray and skipped.
    public func send(_ command: Command, accepts: @escaping @Sendable (Response) -> Bool = { _ in true }) async throws -> Response {
        let replies = try await exchange(command, accepts: accepts) { _ in true }
        return replies[0]
    }

    /// Sends a command and returns the reply, throwing for `.error`, `.disabled` or an unexpected frame.
    public func request<T: Sendable>(_ command: Command, _ extract: @escaping @Sendable (Response) -> T?) async throws -> T {
        let reply = try await send(command) { extract($0) != nil || Self.isFailure($0) }
        return try Self.unwrap(reply, command: command.code, extract)
    }

    static func isFailure(_ response: Response) -> Bool {
        switch response {
        case .error, .disabled: true
        default: false
        }
    }

    /// Sends a command the radio answers only with a push (e.g. a telemetry request for itself),
    /// keeping the one-at-a-time order. Watch `pushes` for the answer.
    public func sendExpectingPush(_ command: Command) async throws {
        await acquire()
        defer { release() }
        guard isOpen else { throw MeshError.notConnected }
        do {
            try await transport.send(command.encoded())
        } catch {
            throw MeshError.transport(error.localizedDescription)
        }
    }

    /// Sends a command expecting a plain OK.
    public func perform(_ command: Command) async throws {
        try await request(command) { response in
            if case .ok = response { return () }
            return nil
        }
    }

    static func unwrap<T>(_ response: Response, command: CommandCode, _ extract: (Response) -> T?) throws -> T {
        switch response {
        case .error(let code): throw MeshError.device(code, command)
        case .disabled: throw MeshError.disabled(command)
        default:
            guard let value = extract(response) else { throw MeshError.unexpectedResponse(response, command) }
            return value
        }
    }

    /// Core request/response exchange: waits its turn, sends, then collects reply frames until
    /// `isComplete` says the reply is whole. An `.error` reply always completes it.
    func exchange(
        _ command: Command,
        accepts: @escaping @Sendable (Response) -> Bool,
        isComplete: @escaping @Sendable ([Response]) -> Bool
    ) async throws -> [Response] {
        await acquire()
        defer { release() }
        guard isOpen else { throw MeshError.notConnected }

        nextRequestID += 1
        let id = nextRequestID
        let frame = command.encoded()
        let transport = transport
        return try await withCheckedThrowingContinuation { continuation in
            pending = PendingRequest(
                id: id, command: command.code, collected: [], accepts: accepts, isComplete: isComplete, continuation: continuation
            )
            armTimeout(for: id)
            Task {
                do {
                    try await transport.send(frame)
                } catch {
                    self.fail(id: id, with: MeshError.transport(error.localizedDescription))
                }
            }
        }
    }

    // MARK: - Receiving

    private func handle(_ data: Data) {
        let frame: Frame
        do {
            frame = try Frame.decode(data)
        } catch let error as FrameDecodingError {
            logger.error("Undecodable frame \(data.hexString, privacy: .public): \(String(describing: error), privacy: .public)")
            if let first = data.first, first < MeshCoreProtocol.firstPushCode, let pending {
                fail(id: pending.id, with: MeshError.decoding(error))
            }
            return
        } catch {
            return
        }

        switch frame {
        case .push(let push):
            pushContinuation.yield(push)
        case .response(let response):
            guard var request = pending, request.accepts(response) else {
                logger.notice("Unsolicited response \(data.hexString, privacy: .public)")
                return
            }
            request.collected.append(response)
            let isError = if case .error = response { true } else { false }
            if isError || request.isComplete(request.collected) {
                pending = nil
                timeoutTask?.cancel()
                request.continuation.resume(returning: request.collected)
            } else {
                pending = request
                armTimeout(for: request.id)
            }
        }
    }

    private func armTimeout(for id: UInt64) {
        timeoutTask?.cancel()
        let timeout = responseTimeout
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.timeOut(id: id)
        }
    }

    private func timeOut(id: UInt64) {
        guard let request = pending, request.id == id else { return }
        fail(id: id, with: MeshError.timeout(request.command))
    }

    private func fail(id: UInt64, with error: Error) {
        guard let request = pending, request.id == id else { return }
        pending = nil
        timeoutTask?.cancel()
        request.continuation.resume(throwing: error)
    }

    private func end(reason: Error?) {
        guard !hasEnded else { return }
        hasEnded = true
        isOpen = false
        if let reason { logger.notice("Session ended: \(String(describing: reason), privacy: .public)") }
        readerTask?.cancel()
        timeoutTask?.cancel()
        if let request = pending {
            pending = nil
            request.continuation.resume(throwing: MeshError.notConnected)
        }
        pushContinuation.finish()
        endedContinuations.forEach { $0.resume() }
        endedContinuations.removeAll()
    }

    // MARK: - One-at-a-time queue

    private func acquire() async {
        if !isBusy {
            isBusy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            isBusy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
