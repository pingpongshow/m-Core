import Foundation
import MeshCoreKit
import MeshStore
import MeshTools
import Testing
@testable import MeshServices

/// Mute levels, message routes, Retry flood and Request position, against the simulated radio.
@MainActor
struct MessagingFeatureTests {
    struct Harness {
        let mock: MockRadio
        let radio: RadioController
        let messaging: MessagingService
        let notifier: RecordingNotifier
    }

    private func connect(_ configure: (inout MockRadio.State) -> Void = { _ in }) async throws -> Harness {
        var state = MockRadio.demoState
        configure(&state)
        let mock = MockRadio(state: state)
        let radio = RadioController(defaults: UserDefaults(suiteName: "feature.\(UUID().uuidString)")!, simulatedRadio: mock)
        let notifier = RecordingNotifier()
        let messaging = MessagingService(
            radio: radio, notifier: notifier,
            defaults: UserDefaults(suiteName: "feature.\(UUID().uuidString)")!,
            ackWait: { _ in 0.05 },
            storeFactory: { try RadioStore(radioKeyHex: $0, inMemory: true) }
        )
        await radio.connect(to: .simulator)
        try await waitUntil { messaging.store != nil && !messaging.isSyncing && messaging.revision > 0 }
        return Harness(mock: mock, radio: radio, messaging: messaging, notifier: notifier)
    }

    private func dm(_ seed: UInt8) -> String {
        ConversationID.direct(keyHex: MockRadio.demoKey(seed).hex).description
    }

    // MARK: Mute levels

    @Test func notificationsFollowMuteLevel() async throws {
        let harness = try await connect()
        let store = try #require(harness.messaging.store)
        var timestamp: UInt32 = 100

        /// Receives a channel message and returns whether it posted a notification.
        func receive(_ text: String) async throws -> Bool {
            let before = harness.notifier.messages.count
            let stored = store.messages(conversationID: "ch:1").count
            timestamp += 1
            harness.mock.receive(.channelMessage(ChannelMessage(
                channelIndex: 1, routing: .flood(hops: 0), senderTimestamp: timestamp, text: "Zed: \(text)"
            )))
            try await waitUntil { store.messages(conversationID: "ch:1").count == stored + 1 }
            return harness.notifier.messages.count > before
        }

        #expect(harness.messaging.muteLevel(for: "ch:1") == .all)
        #expect(try await receive("hello"))
        #expect(try await receive("hi @[Sim]"))

        harness.messaging.setMuteLevel(.mentions, conversationID: "ch:1")
        #expect(harness.messaging.muteLevel(for: "ch:1") == .mentions)
        #expect(try await !receive("chatter"))
        #expect(try await receive("@[Sim] are you there?"))
        #expect(harness.notifier.messages.last?.isMention == true)

        harness.messaging.setMuteLevel(.muted, conversationID: "ch:1")
        #expect(try await !receive("more chatter"))
        #expect(try await !receive("@[Sim] urgent"))
        await harness.radio.disconnect()
    }

    // MARK: Routes

    @Test func floodedMessagesKeepThePathHeardInTheRxLog() async throws {
        let harness = try await connect()
        let store = try #require(harness.messaging.store)
        let bob = MockRadio.demoKey(0x14)
        let selfHash = MockRadio.samplePublicKey.bytes[0]

        // Text message, flood, two hops (10 then A3), addressed to us from Bob.
        harness.mock.push(.rxLog(RxLogEntry(snr: 5, rssi: -90, raw: Data([0x09, 0x02, 0x10, 0xA3, selfHash, bob.bytes[0], 0xDE, 0xAD]))))
        harness.mock.receive(.contactMessage(ContactMessage(
            senderPrefix: bob.prefix, routing: .flood(hops: 2), senderTimestamp: 500, text: "via two repeaters"
        )))
        try await waitUntil { !store.messages(conversationID: dm(0x14)).isEmpty }
        #expect(store.messages(conversationID: dm(0x14)).first?.routeHashes == ["10", "A3"])

        // Group text on #test, one hop.
        let channelHash = MessagingService.channelHash(secret: MessageFormat.hashtagSecret("#test"))
        harness.mock.push(.rxLog(RxLogEntry(snr: 5, rssi: -90, raw: Data([0x15, 0x01, 0x20, channelHash, 0x01, 0x02, 0x03]))))
        harness.mock.receive(.channelMessage(ChannelMessage(
            channelIndex: 1, routing: .flood(hops: 1), senderTimestamp: 501, text: "Zed: one hop"
        )))
        try await waitUntil { !store.messages(conversationID: "ch:1").isEmpty }
        #expect(store.messages(conversationID: "ch:1").first?.routeHashes == ["20"])

        // No matching packet: the route stays unknown.
        harness.mock.receive(.channelMessage(ChannelMessage(
            channelIndex: 1, routing: .flood(hops: 3), senderTimestamp: 502, text: "Zed: unknown path"
        )))
        try await waitUntil { store.messages(conversationID: "ch:1").count == 2 }
        #expect(store.messages(conversationID: "ch:1").last?.routeHashes == nil)
        await harness.radio.disconnect()
    }

    @Test func retryFloodResetsThePathAndResends() async throws {
        let harness = try await connect { $0.autoAck = false }
        let store = try #require(harness.messaging.store)
        let bob = MockRadio.demoKey(0x14)
        let message = try await harness.messaging.send("are you there?", to: dm(0x14))
        #expect(message.routeHashes == ["20"])
        #expect(MessagingService.canRetryFlood(message))

        await harness.messaging.retryFlood(message.id)
        #expect(harness.mock.current.pathResets == [bob])
        #expect(harness.mock.current.sentDirectMessages.last?.attempt == UInt8(MessagingService.maxAttempts - 1))
        #expect(message.routeHashes == nil)
        #expect(store.contact(keyHex: bob.hex)?.outPathLength == 0xFF)
        try await waitUntil { message.status == .failed }

        harness.mock.update { $0.autoAck = true }
        await harness.messaging.retryFlood(message.id)
        try await waitUntil { message.status == .delivered }
        #expect(!MessagingService.canRetryFlood(message))
        await harness.radio.disconnect()
    }

    // MARK: Request position

    @Test func requestPositionShowsTheReplyAsALocalLocationCard() async throws {
        let harness = try await connect()
        let store = try #require(harness.messaging.store)
        let telemetry = TelemetryService(radio: harness.radio, messaging: harness.messaging)
        let positions = PositionRequestService(messaging: harness.messaging) { try await telemetry.request(from: $0) }
        let alice = MockRadio.demoKey(0x0A)
        // Alice has moved since her last advert.
        harness.mock.update { state in
            state.contacts[0].latitudeE6 = 37_800_000
            state.contacts[0].longitudeE6 = -122_400_000
        }
        let sentBefore = harness.mock.current.sentDirectMessages.count

        let outcome = try await positions.requestPosition(from: alice.hex)
        #expect(outcome == .position(latitude: 37.8, longitude: -122.4))
        #expect(store.contact(keyHex: alice.hex)?.latitudeE6 == 37_800_000)
        #expect(store.positions(keyHex: alice.hex).last?.source == "telemetry")

        let card = try #require(store.messages(conversationID: dm(0x0A)).last)
        #expect(card.kind == .positionReport)
        #expect(!card.isOutgoing && card.isRead)
        #expect(card.senderName == "Alice Chen")
        let location = try #require(MessageFormat.location(in: card.text))
        #expect(abs(location.latitude - 37.8) < 1e-6 && abs(location.longitude + 122.4) < 1e-6)
        // Nothing went out as a chat message, and it doesn't count as unread.
        #expect(harness.mock.current.sentDirectMessages.count == sentBefore)
        #expect(store.conversation(id: dm(0x0A)).unreadCount == 1)
        #expect(positions.pending.isEmpty)
        await harness.radio.disconnect()
    }

    @Test func requestPositionWithoutGPSOrReply() async throws {
        let harness = try await connect { state in
            state.contacts.append(Contact(
                publicKey: MockRadio.demoKey(0x70), type: .chat, outPath: .empty, name: "No Fix", lastModified: state.clock
            ))
        }
        let store = try #require(harness.messaging.store)
        let telemetry = TelemetryService(radio: harness.radio, messaging: harness.messaging)
        let positions = PositionRequestService(messaging: harness.messaging) { try await telemetry.request(from: $0) }
        let noFix = MockRadio.demoKey(0x70)

        #expect(try await positions.requestPosition(from: noFix.hex) == .noPosition)
        let notice = try #require(store.messages(conversationID: dm(0x70)).last)
        #expect(notice.kind == .notice)
        #expect(notice.text == "No Fix didn't share a position.")
        #expect(store.contact(keyHex: noFix.hex)?.hasLocation == false)

        let silent = PositionRequestService(messaging: harness.messaging) { _ in throw RemoteRequestError.timedOut }
        #expect(try await silent.requestPosition(from: noFix.hex) == .noReply)
        #expect(store.messages(conversationID: dm(0x70)).last?.text == "No reply from No Fix to the position request.")

        // Only chat contacts can be asked.
        await #expect(throws: RemoteRequestError.unknownNode) {
            try await positions.requestPosition(from: MockRadio.demoKey(0x10).hex)
        }
        let failing = PositionRequestService(messaging: harness.messaging) { _ in throw RemoteRequestError.notConnected }
        await #expect(throws: RemoteRequestError.notConnected) {
            try await failing.requestPosition(from: noFix.hex)
        }
        #expect(failing.pending.isEmpty)
        await harness.radio.disconnect()
    }
}

// MARK: Live location

@MainActor
struct LiveLocationTests {
    final class Clock {
        var date = Date(timeIntervalSince1970: 1_800_000_000)
        func advance(_ seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
    }

    final class Recorder {
        var sent: [(text: String, conversationID: String)] = []
        var tracking: [Bool] = []
        var position: GeoCoordinate?
        var failing = false
    }

    private func makeService(_ clock: Clock, _ recorder: Recorder) -> LiveLocationService {
        LiveLocationService(
            send: { text, conversationID in
                if recorder.failing { throw MessagingError.notConnected }
                recorder.sent.append((text, conversationID))
            },
            location: { recorder.position },
            setTracking: { recorder.tracking.append($0) },
            now: { clock.date },
            tickInterval: nil
        )
    }

    /// About `metres` north of `origin`.
    private func north(of origin: GeoCoordinate, metres: Double) -> GeoCoordinate {
        GeoCoordinate(latitude: origin.latitude + metres / 111_195, longitude: origin.longitude)
    }

    @Test func sendsOnMovementAndHeartbeatWithinRateLimits() async {
        let clock = Clock()
        let recorder = Recorder()
        let service = makeService(clock, recorder)
        let start = GeoCoordinate(latitude: 37.7749, longitude: -122.4194)

        service.start(conversationID: "dm:aa", length: .fifteenMinutes)
        #expect(recorder.tracking == [true])
        #expect(service.share(for: "dm:aa")?.expiresAt == clock.date.addingTimeInterval(900))

        // No fix yet: nothing to send.
        await service.tick()
        #expect(recorder.sent.isEmpty)

        recorder.position = start
        await service.tick()
        #expect(recorder.sent.map(\.text) == ["Live location: 37.77490, -122.41940"])
        #expect(recorder.sent.first?.conversationID == "dm:aa")

        // Moved 100 m but only 10 s later: rate-limited.
        clock.advance(10)
        recorder.position = north(of: start, metres: 100)
        await service.tick()
        #expect(recorder.sent.count == 1)

        // 31 s after the first update: the move goes out.
        clock.advance(21)
        await service.tick()
        #expect(recorder.sent.count == 2)

        // A 10 m shuffle a minute later isn't worth an update.
        clock.advance(60)
        recorder.position = north(of: start, metres: 110)
        await service.tick()
        #expect(recorder.sent.count == 2)

        // Two minutes after the last update, it goes out even without moving far.
        clock.advance(60)
        await service.tick()
        #expect(recorder.sent.count == 3)
        #expect(service.share(for: "dm:aa")?.updatesSent == 3)

        service.stop(conversationID: "dm:aa")
        #expect(service.shares.isEmpty)
        #expect(recorder.tracking == [true, false])
        clock.advance(600)
        await service.tick()
        #expect(recorder.sent.count == 3)
    }

    @Test func expiresAndKeepsOtherShares() async {
        let clock = Clock()
        let recorder = Recorder()
        recorder.position = GeoCoordinate(latitude: 1, longitude: 1)
        let service = makeService(clock, recorder)

        service.start(conversationID: "ch:0", length: .fifteenMinutes)
        service.start(conversationID: "dm:bb", length: .oneHour)
        #expect(recorder.tracking == [true])
        await service.tick()
        #expect(Set(recorder.sent.map(\.conversationID)) == ["ch:0", "dm:bb"])
        #expect(service.share(for: "ch:0")?.remaining(at: clock.date.addingTimeInterval(60)) == 840)

        clock.advance(901)
        await service.tick()
        #expect(service.share(for: "ch:0") == nil)
        #expect(service.share(for: "dm:bb") != nil)
        #expect(recorder.sent.filter { $0.conversationID == "ch:0" }.count == 1)

        clock.advance(2_700)
        await service.tick()
        #expect(service.shares.isEmpty)
        #expect(recorder.tracking == [true, false])
    }

    @Test func failedSendsAreRetriedNoFasterThanTheRateLimit() async {
        let clock = Clock()
        let recorder = Recorder()
        recorder.position = GeoCoordinate(latitude: 1, longitude: 1)
        recorder.failing = true
        let service = makeService(clock, recorder)

        service.start(conversationID: "dm:aa", length: .fifteenMinutes)
        await service.tick()
        #expect(service.lastError != nil)
        #expect(service.share(for: "dm:aa")?.updatesSent == 0)

        recorder.failing = false
        clock.advance(5)
        await service.tick()
        #expect(recorder.sent.isEmpty)

        clock.advance(26)
        await service.tick()
        #expect(recorder.sent.count == 1)
        #expect(service.lastError == nil)
    }

    @Test func sharesThroughTheRadio() async throws {
        let mock = MockRadio(state: MockRadio.demoState)
        let radio = RadioController(defaults: UserDefaults(suiteName: "live.\(UUID().uuidString)")!, simulatedRadio: mock)
        let messaging = MessagingService(
            radio: radio, defaults: UserDefaults(suiteName: "live.\(UUID().uuidString)")!,
            storeFactory: { try RadioStore(radioKeyHex: $0, inMemory: true) }
        )
        await radio.connect(to: .simulator)
        try await waitUntil { messaging.store != nil && !messaging.isSyncing && messaging.revision > 0 }

        let service = LiveLocationService(messaging: messaging, location: { GeoCoordinate(latitude: 37.5, longitude: -122.25) })
        service.start(conversationID: "ch:2", length: .oneHour)
        try await waitUntil { mock.current.sentChannelMessages.contains { $0.text == "Live location: 37.50000, -122.25000" } }
        #expect(messaging.store?.messages(conversationID: "ch:2").last?.isOutgoing == true)
        service.stop(conversationID: "ch:2")
        await radio.disconnect()
    }
}
