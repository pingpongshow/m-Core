import Foundation
import Synchronization

/// In-memory transport for tests and UI previews. A responder turns each sent frame into reply frames.
public final class MockTransport: MeshTransport {
    public typealias Responder = @Sendable (Data) -> [Data]

    private struct State {
        var continuation: AsyncThrowingStream<Data, Error>.Continuation?
        var sentFrames: [Data] = []
        var openCount = 0
    }

    private let state = Mutex(State())
    private let responder: Responder
    private let openError: (@Sendable (Int) -> Error?)

    /// - Parameters:
    ///   - openError: Called with the attempt number (1-based); return an error to make that `open()` fail.
    public init(
        openError: @escaping @Sendable (Int) -> Error? = { _ in nil },
        responder: @escaping Responder = { _ in [] }
    ) {
        self.openError = openError
        self.responder = responder
    }

    public var sentFrames: [Data] { state.withLock { $0.sentFrames } }
    public var openCount: Int { state.withLock { $0.openCount } }
    public var isOpen: Bool { state.withLock { $0.continuation != nil } }

    public func open() async throws -> AsyncThrowingStream<Data, Error> {
        let attempt = state.withLock { state in
            state.openCount += 1
            return state.openCount
        }
        if let error = openError(attempt) { throw error }
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        try state.withLock { state in
            guard state.continuation == nil else { throw TransportError.alreadyOpen }
            state.continuation = continuation
        }
        return stream
    }

    public func send(_ frame: Data) async throws {
        let continuation = try state.withLock { state in
            guard let continuation = state.continuation else { throw TransportError.notOpen }
            state.sentFrames.append(frame)
            return continuation
        }
        for reply in responder(frame) {
            continuation.yield(reply)
        }
    }

    public func close() async {
        let continuation = state.withLock { state in
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.finish()
    }

    /// Delivers a frame as if the radio sent it unprompted.
    public func inject(_ frame: Data) {
        _ = state.withLock { $0.continuation }?.yield(frame)
    }

    /// Drops the link, as if the radio went out of range.
    public func simulateDisconnect(error: Error = TransportError.disconnected("simulated")) {
        let continuation = state.withLock { state in
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.finish(throwing: error)
    }
}
