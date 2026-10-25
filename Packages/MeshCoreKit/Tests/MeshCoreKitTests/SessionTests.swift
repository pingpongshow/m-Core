import Foundation
import Synchronization
import Testing
@testable import MeshCoreKit

struct SessionTests {
    private func openSession(
        _ radio: MockRadio = MockRadio(),
        timeout: Duration = .seconds(2)
    ) async throws -> (MeshSession, MockTransport) {
        let transport = radio.makeTransport()
        let session = MeshSession(transport: transport, responseTimeout: timeout)
        try await session.open()
        return (session, transport)
    }

    @Test func handshakeQueriesDeviceStartsAppAndSetsClock() async throws {
        let radio = MockRadio()
        let (session, transport) = try await openSession(radio)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let info = try await session.handshake(appName: "m-Core", now: now)

        #expect(info.device.model == "Heltec V3")
        #expect(info.selfInfo.name == "m-Core Sim")
        #expect(info.clockSync == .updated(to: 1_800_000_000))
        #expect(radio.current.clock == 1_800_000_000)
        #expect(transport.sentFrames.map { $0.first } == [0x16, 0x01, 0x06])
        #expect(transport.sentFrames[0] == hex("1603"))
    }

    @Test func clockSyncReportsRadioAhead() async throws {
        let radio = MockRadio()
        radio.update { $0.clock = 1_900_000_000 }
        let (session, _) = try await openSession(radio)

        let result = try await session.syncClock(to: Date(timeIntervalSince1970: 1_800_000_000))

        #expect(result == .radioAhead(radioTime: 1_900_000_000))
        #expect(radio.current.clock == 1_900_000_000)
    }

    @Test func getContactsCollectsAllFramesAndRespectsSince() async throws {
        let radio = MockRadio()
        radio.update { state in
            state.contacts = [
                Contact(publicKey: sampleKey, type: .chat, name: "Alice", lastModified: 100),
                Contact(publicKey: otherKey, type: .repeater, name: "Hill", lastModified: 200),
            ]
        }
        let (session, _) = try await openSession(radio)

        let all = try await session.getContacts()
        #expect(all.contacts.map(\.name) == ["Alice", "Hill"])
        #expect(all.totalCount == 2)
        #expect(all.lastModified == 200)

        let changed = try await session.getContacts(since: 150)
        #expect(changed.contacts.map(\.name) == ["Hill"])
        #expect(changed.lastModified == 200)

        let none = try await session.getContacts(since: 200)
        #expect(none.contacts.isEmpty)
        #expect(none.lastModified == 200)
    }

    @Test func syncNextMessageDrainsQueue() async throws {
        let radio = MockRadio()
        let message = ContactMessage(senderPrefix: samplePrefix, routing: .direct, senderTimestamp: 1, text: "hi", snr: 2)
        radio.update { $0.queuedMessages = [.contactMessage(message)] }
        let (session, _) = try await openSession(radio)

        #expect(try await session.syncNextMessage() == .contactMessage(message))
        #expect(try await session.syncNextMessage() == nil)
    }

    @Test func deviceErrorsAreThrown() async throws {
        let (session, _) = try await openSession()
        await #expect(throws: MeshError.device(.illegalArgument, .setAdvertLatLon)) {
            try await session.perform(.setAdvertLatLon(latitudeE6: 91_000_000, longitudeE6: 0))
        }
        await #expect(throws: MeshError.device(.unsupportedCommand, .getChannel)) {
            _ = try await session.getChannel(index: 0)
        }
    }

    @Test func setAdvertLatLonUpdatesRadio() async throws {
        let radio = MockRadio()
        let (session, _) = try await openSession(radio)
        try await session.perform(.setAdvertLatLon(latitudeE6: 37_774_900, longitudeE6: -122_419_400))
        #expect(radio.current.selfInfo.latitudeE6 == 37_774_900)
        #expect(try await session.appStart(appName: "x").longitude == -122.4194)
    }

    @Test func commandsRunOneAtATimeInOrder() async throws {
        let inFlight = Mutex(0)
        let maxInFlight = Mutex(0)
        let radio = MockRadio()
        // Count overlapping sends: a send "completes" when its reply is produced.
        let transport = MockTransport(responder: { frame in
            let now = inFlight.withLock { $0 += 1; return $0 }
            maxInFlight.withLock { $0 = max($0, now) }
            defer { inFlight.withLock { $0 -= 1 } }
            return radio.respond(to: frame)
        })
        let session = MeshSession(transport: transport)
        try await session.open()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask { _ = try await session.getBatteryAndStorage() }
                group.addTask { _ = try await session.getDeviceTime() }
            }
            try await group.waitForAll()
        }
        #expect(maxInFlight.withLock { $0 } == 1)
        #expect(transport.sentFrames.count == 40)
    }

    @Test func timesOutWhenRadioIsSilent() async throws {
        let transport = MockTransport(responder: { _ in [] })
        let session = MeshSession(transport: transport, responseTimeout: .milliseconds(50))
        try await session.open()
        await #expect(throws: MeshError.timeout(.getDeviceTime)) {
            _ = try await session.getDeviceTime()
        }
        // The queue keeps working after a timeout.
        await #expect(throws: MeshError.timeout(.getBatteryAndStorage)) {
            _ = try await session.getBatteryAndStorage()
        }
    }

    @Test func pushesArriveWhileACommandIsInFlight() async throws {
        let radio = MockRadio()
        let transport = MockTransport(responder: { frame in
            // A push lands between the command and its reply, as on real radios.
            [RadioFrameEncoder.encode(Push.messagesWaiting)!] + radio.respond(to: frame)
        })
        let session = MeshSession(transport: transport)
        try await session.open()

        let time = try await session.getDeviceTime()
        #expect(time == radio.current.clock)

        var iterator = session.pushes.makeAsyncIterator()
        #expect(await iterator.next() == .messagesWaiting)
    }

    @Test func injectedPushIsDelivered() async throws {
        let (session, transport) = try await openSession()
        transport.inject(RadioFrameEncoder.encode(Push.advert(otherKey))!)
        var iterator = session.pushes.makeAsyncIterator()
        #expect(await iterator.next() == .advert(otherKey))
    }

    @Test func disconnectFailsPendingCommandAndEndsSession() async throws {
        let transport = MockTransport(responder: { _ in [] })
        let session = MeshSession(transport: transport, responseTimeout: .seconds(5))
        try await session.open()

        let pending = Task { try await session.getDeviceTime() }
        try await Task.sleep(for: .milliseconds(20))
        transport.simulateDisconnect()

        await #expect(throws: MeshError.notConnected) { _ = try await pending.value }
        await session.waitUntilEnded()
        await #expect(throws: MeshError.notConnected) { _ = try await session.getDeviceTime() }

        var iterator = session.pushes.makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }

    @Test func openFailureIsReported() async throws {
        let transport = MockTransport(openError: { _ in TransportError.peripheralNotFound })
        let session = MeshSession(transport: transport)
        await #expect(throws: MeshError.self) { try await session.open() }
    }

    @Test func unsolicitedResponsesAreIgnored() async throws {
        let (session, transport) = try await openSession()
        transport.inject(hex("00"))
        #expect(try await session.getDeviceTime() == MockRadio.sampleState.clock)
    }
}

struct ConnectionTests {
    private let fastBackoff = ReconnectBackoff(initial: .milliseconds(10), maximum: .milliseconds(40))

    private func waitFor(
        _ connection: MeshConnection,
        timeout: Duration = .seconds(2),
        where predicate: @escaping @Sendable (MeshConnection.State) -> Bool
    ) async -> MeshConnection.State? {
        let states = connection.states
        return await withTaskGroup(of: MeshConnection.State?.self) { group in
            group.addTask {
                for await state in states where predicate(state) { return state }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let result = await group.next().flatMap { $0 }
            group.cancelAll()
            return result
        }
    }

    @Test func connectsAndRunsHandshake() async throws {
        let radio = MockRadio()
        let connection = MeshConnection(backoff: fastBackoff) { radio.makeTransport() }
        await connection.start()

        let state = await waitFor(connection) { if case .connected = $0 { true } else { false } }
        guard case .connected(let info) = state else {
            Issue.record("never connected: \(String(describing: state))")
            return
        }
        #expect(info.selfInfo.publicKey == MockRadio.samplePublicKey)
        #expect(await connection.session != nil)
        await connection.stop()
        #expect(await connection.state == .idle)
    }

    @Test func retriesUntilTheRadioIsReachable() async throws {
        let radio = MockRadio()
        let attempts = Mutex(0)
        let connection = MeshConnection(backoff: fastBackoff) {
            let attempt = attempts.withLock { $0 += 1; return $0 }
            return MockTransport(
                openError: { _ in attempt < 3 ? TransportError.connectionFailed("offline") : nil },
                responder: { radio.respond(to: $0) }
            )
        }
        await connection.start()

        let state = await waitFor(connection) { if case .connected = $0 { true } else { false } }
        #expect(state != nil)
        #expect(attempts.withLock { $0 } == 3)
        await connection.stop()
    }

    @Test func reconnectsAfterTheLinkDrops() async throws {
        let radio = MockRadio()
        let transports = Mutex<[MockTransport]>([])
        let connection = MeshConnection(backoff: fastBackoff) {
            let transport = radio.makeTransport()
            transports.withLock { $0.append(transport) }
            return transport
        }
        await connection.start()
        _ = await waitFor(connection) { if case .connected = $0 { true } else { false } }

        transports.withLock { $0.last }?.simulateDisconnect()

        let waiting = await waitFor(connection) { if case .waitingToReconnect = $0 { true } else { false } }
        #expect(waiting != nil)
        let reconnected = await waitFor(connection) { if case .connected = $0 { true } else { false } }
        #expect(reconnected != nil)
        #expect(transports.withLock { $0.count } == 2)
        await connection.stop()
    }

    @Test func pushesSurviveReconnects() async throws {
        let radio = MockRadio()
        let transports = Mutex<[MockTransport]>([])
        let connection = MeshConnection(backoff: fastBackoff) {
            let transport = radio.makeTransport()
            transports.withLock { $0.append(transport) }
            return transport
        }
        await connection.start()
        _ = await waitFor(connection) { if case .connected = $0 { true } else { false } }
        var pushes = connection.pushes.makeAsyncIterator()

        transports.withLock { $0.last }?.inject(RadioFrameEncoder.encode(Push.messagesWaiting)!)
        #expect(await pushes.next() == .messagesWaiting)

        transports.withLock { $0.last }?.simulateDisconnect()
        _ = await waitFor(connection) { if case .waitingToReconnect = $0 { true } else { false } }
        _ = await waitFor(connection) { if case .connected = $0 { true } else { false } }
        transports.withLock { $0.last }?.inject(RadioFrameEncoder.encode(Push.contactsFull)!)
        #expect(await pushes.next() == .contactsFull)
        await connection.stop()
    }

    @Test func backoffGrowsAndCaps() {
        let backoff = ReconnectBackoff(initial: .seconds(1), maximum: .seconds(30))
        #expect(backoff.delay(afterFailedAttempt: 1) == .seconds(1))
        #expect(backoff.delay(afterFailedAttempt: 2) == .seconds(2))
        #expect(backoff.delay(afterFailedAttempt: 5) == .seconds(16))
        #expect(backoff.delay(afterFailedAttempt: 10) == .seconds(30))
    }
}

/// A transport whose `open()` never finishes until `close()`, like BLE waiting on a pairing prompt.
private final class HangingTransport: MeshTransport {
    private let opened = Mutex<CheckedContinuation<AsyncThrowingStream<Data, Error>, Error>?>(nil)

    func open() async throws -> AsyncThrowingStream<Data, Error> {
        try await withCheckedThrowingContinuation { continuation in
            opened.withLock { $0 = continuation }
        }
    }

    func send(_ frame: Data) async throws {
        throw TransportError.notOpen
    }

    func close() async {
        opened.withLock { continuation in
            continuation?.resume(throwing: TransportError.disconnected(nil))
            continuation = nil
        }
    }
}

struct ConnectionStopTests {
    @Test func stopDuringASlowOpenReturnsPromptly() async throws {
        let connection = MeshConnection { HangingTransport() }
        await connection.start()
        try await Task.sleep(for: .milliseconds(50))

        let clock = ContinuousClock()
        let elapsed = await clock.measure { await connection.stop() }

        #expect(elapsed < .seconds(1))
        #expect(await connection.state == .idle)
    }
}
