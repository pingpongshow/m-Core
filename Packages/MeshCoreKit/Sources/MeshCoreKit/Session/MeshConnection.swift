import Foundation

/// Exponential backoff between reconnect attempts.
public struct ReconnectBackoff: Equatable, Sendable {
    public var initial: Duration
    public var maximum: Duration
    public var multiplier: Double

    public init(initial: Duration = .seconds(1), maximum: Duration = .seconds(30), multiplier: Double = 2) {
        self.initial = initial
        self.maximum = maximum
        self.multiplier = multiplier
    }

    /// Delay before retry number `attempt` (1-based).
    public func delay(afterFailedAttempt attempt: Int) -> Duration {
        let factor = pow(multiplier, Double(max(0, attempt - 1)))
        // Compare in seconds first: `Duration * Double` traps once the product leaves Duration's range,
        // which a long outage reaches after a few dozen attempts.
        let seconds = initial / .seconds(1) * factor
        guard seconds.isFinite, seconds < maximum / .seconds(1) else { return maximum }
        return initial * factor
    }
}

/// Keeps a radio connected: opens a transport, runs the handshake, and reconnects with backoff
/// whenever the link drops, until `stop()`.
public actor MeshConnection {
    public enum State: Equatable, Sendable {
        case idle
        case connecting(attempt: Int)
        case connected(ConnectionInfo)
        case waitingToReconnect(attempt: Int, delay: Duration, lastError: String)
    }

    /// Connection state changes, starting with the current state.
    nonisolated public let states: AsyncStream<State>
    /// Pushes from whichever session is current; survives reconnects.
    nonisolated public let pushes: AsyncStream<Push>

    private let statesContinuation: AsyncStream<State>.Continuation
    private let pushesContinuation: AsyncStream<Push>.Continuation
    private let makeTransport: @Sendable () -> any MeshTransport
    private let appName: String
    private let backoff: ReconnectBackoff
    private let responseTimeout: Duration
    private let now: @Sendable () -> Date

    public private(set) var state: State = .idle
    /// The live session while connected.
    public private(set) var session: MeshSession?
    /// The session being opened or handshaken; closed by `stop()` so a slow BLE or TCP open doesn't block it.
    private var attemptSession: MeshSession?
    private var runTask: Task<Void, Never>?

    public init(
        appName: String = "m-Core",
        backoff: ReconnectBackoff = ReconnectBackoff(),
        responseTimeout: Duration = .seconds(5),
        now: @escaping @Sendable () -> Date = { Date() },
        makeTransport: @escaping @Sendable () -> any MeshTransport
    ) {
        self.appName = appName
        self.backoff = backoff
        self.responseTimeout = responseTimeout
        self.now = now
        self.makeTransport = makeTransport
        (states, statesContinuation) = AsyncStream<State>.makeStream(bufferingPolicy: .bufferingNewest(16))
        (pushes, pushesContinuation) = AsyncStream<Push>.makeStream(bufferingPolicy: .bufferingNewest(256))
        statesContinuation.yield(.idle)
    }

    /// Starts connecting (no-op if already running).
    public func start() {
        guard runTask == nil else { return }
        runTask = Task { await self.run() }
    }

    /// Disconnects and stops reconnecting.
    public func stop() async {
        let task = runTask
        runTask = nil
        task?.cancel()
        if let attemptSession { await attemptSession.close() }
        if let session { await session.close() }
        await task?.value
        session = nil
        setState(.idle)
    }

    private func run() async {
        var attempt = 0
        while !Task.isCancelled {
            attempt += 1
            setState(.connecting(attempt: attempt))
            let session = MeshSession(transport: makeTransport(), responseTimeout: responseTimeout)
            attemptSession = session
            var lastError = "connection lost"
            do {
                try await session.open()
                let info = try await session.handshake(appName: appName, now: now())
                attemptSession = nil
                attempt = 0
                self.session = session
                setState(.connected(info))
                for await push in session.pushes {
                    pushesContinuation.yield(push)
                }
                self.session = nil
            } catch {
                attemptSession = nil
                lastError = error.localizedDescription
                await session.close()
            }
            guard !Task.isCancelled else { break }
            let delay = backoff.delay(afterFailedAttempt: max(attempt, 1))
            setState(.waitingToReconnect(attempt: attempt, delay: delay, lastError: lastError))
            try? await Task.sleep(for: delay)
        }
    }

    private func setState(_ newState: State) {
        state = newState
        statesContinuation.yield(newState)
    }
}
