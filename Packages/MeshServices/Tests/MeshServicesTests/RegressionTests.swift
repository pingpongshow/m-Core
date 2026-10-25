import Foundation
import MeshCoreKit
import MeshStore
import MeshTools
import Synchronization
import Testing
@testable import MeshServices

/// Regression tests for defects found in review; each failed before its fix.
@MainActor
struct PushWaiterRegressionTests {
    @Test func earlierRequestsTimeoutDoesNotEndALaterWait() async throws {
        let waiter = PushWaiter<String>()
        // First request to the node is answered quickly…
        let first = Task { try await waiter.wait(for: "node", timeout: .milliseconds(150)) }
        try await waitUntil { waiter.isWaiting }
        waiter.resolve("node", with: .success("one"))
        #expect(try await first.value == "one")

        // …and the next one, still in flight when the first one's timeout fires, must survive it.
        let second = Task { try await waiter.wait(for: "node", timeout: .seconds(5)) }
        try await waitUntil { waiter.isWaiting }
        try await Task.sleep(for: .milliseconds(300))
        #expect(waiter.isWaiting)
        waiter.resolve("node", with: .success("two"))
        #expect(try await second.value == "two")
    }

    @Test func waitStillTimesOutOnItsOwn() async throws {
        let waiter = PushWaiter<Int>()
        await #expect(throws: RemoteRequestError.timedOut) {
            try await waiter.wait(for: "node", timeout: .milliseconds(50))
        }
        #expect(!waiter.isWaiting)
    }
}

@MainActor
struct RemoteCommandTimestampTests {
    @Test func commandsInTheSameSecondGetIncreasingTimestamps() async throws {
        let mock = MockRadio(state: MockRadio.demoState)
        let radio = RadioController(defaults: UserDefaults(suiteName: "ts.\(UUID().uuidString)")!, simulatedRadio: mock)
        let messaging = MessagingService(
            radio: radio, defaults: UserDefaults(suiteName: "ts.\(UUID().uuidString)")!,
            storeFactory: { try RadioStore(radioKeyHex: $0, inMemory: true) }
        )
        let fixed = Date(timeIntervalSince1970: 1_800_000_000.4)
        let remote = RemoteNodeService(radio: radio, messaging: messaging, now: { fixed })
        await radio.connect(to: .simulator)
        try await waitUntil { messaging.store != nil && !messaging.isSyncing && messaging.revision > 0 }

        let repeater = MockRadio.demoKey(0x10).hex
        _ = try await remote.login(keyHex: repeater, password: "password")
        // The login used this second, so the first command needs the next one, and so on: the firmware ignores a
        // command whose timestamp equals the previous one as a retry.
        #expect(remote.nextCommandTimestamp(keyHex: repeater) == 1_800_000_001)
        #expect(remote.nextCommandTimestamp(keyHex: repeater) == 1_800_000_002)
        // Each node keeps its own sequence.
        #expect(remote.nextCommandTimestamp(keyHex: MockRadio.demoKey(0x11).hex) == 1_800_000_000)

        // Reading every setting back to back still fills them all in.
        let settings = try await remote.readSettings(keyHex: repeater)
        #expect(settings.name == "Charlie Node")
        #expect(settings.repeatEnabled == true)
        await radio.disconnect()
    }
}

@MainActor
struct LateAckTests {
    @Test func ackForAnEarlierAttemptStillMarksDelivered() async throws {
        var state = MockRadio.demoState
        state.autoAck = false
        let mock = MockRadio(state: state)
        let radio = RadioController(defaults: UserDefaults(suiteName: "ack.\(UUID().uuidString)")!, simulatedRadio: mock)
        let messaging = MessagingService(
            radio: radio, defaults: UserDefaults(suiteName: "ack.\(UUID().uuidString)")!, ackWait: { _ in 0.05 },
            storeFactory: { try RadioStore(radioKeyHex: $0, inMemory: true) }
        )
        await radio.connect(to: .simulator)
        try await waitUntil { messaging.store != nil && !messaging.isSyncing && messaging.revision > 0 }

        let conversation = ConversationID.direct(keyHex: MockRadio.demoKey(0x14).hex).description
        let message = try await messaging.send("anyone?", to: conversation)
        let firstTag = try #require(message.ackTag)
        try await waitUntil(timeout: .seconds(5)) { message.status == .failed }
        #expect(message.ackTag != firstTag)

        // The ACK for the first attempt arrives late, after the retries.
        mock.push(.sendConfirmed(SendConfirmation(ackCode: UInt32(firstTag), roundTripMs: 4_000)))
        try await waitUntil { message.status == .delivered }
        #expect(message.roundTripMs == 4_000)
        await radio.disconnect()
    }
}

struct GPSSourceDetectionTests {
    @Test func customVarsDecideTheSource() async {
        #expect(await GPSFeedService.detectSource { ["gps": "1"] } == .radioGPS(isOn: true))
        #expect(await GPSFeedService.detectSource { ["gps": "0"] } == .radioGPS(isOn: false))
        #expect(await GPSFeedService.detectSource { [:] } == .phone)
        // Firmware without the command has no GPS support.
        #expect(await GPSFeedService.detectSource { throw MeshError.device(nil, .getCustomVars) } == .phone)
    }

    @Test func unansweredQueryNeverFallsBackToThePhone() async {
        // A radio that doesn't answer may well have a GPS: its position must not be overwritten with the phone's.
        #expect(await GPSFeedService.detectSource { throw MeshError.timeout(.getCustomVars) } == .unknown)

        let calls = Mutex(0)
        let source = await GPSFeedService.detectSource {
            let call = calls.withLock { count in
                count += 1
                return count
            }
            if call == 1 { throw MeshError.timeout(.getCustomVars) }
            return ["gps": "1"]
        }
        #expect(source == .radioGPS(isOn: true))
    }

    @Test func settingsMissingNewerKeysKeepTheRest() throws {
        let json = Data(#"{"isEnabled":false,"preset":"driving","rounding":"approx1km"}"#.utf8)
        let settings = try JSONDecoder().decode(GPSFeedSettings.self, from: json)
        #expect(!settings.isEnabled)
        #expect(settings.preset == .driving)
        #expect(settings.rounding == .approx1km)
        #expect(settings.maxFixAge == GPSFeedSettings().maxFixAge)
        let roundTrip = try JSONDecoder().decode(GPSFeedSettings.self, from: JSONEncoder().encode(settings))
        #expect(roundTrip == settings)
    }
}

@MainActor
struct CoverageRegressionTests {
    @Test func pingWithoutARadioIsNotRecordedAsAGap() async throws {
        let radio = RadioController(defaults: UserDefaults(suiteName: "cov.\(UUID().uuidString)")!)
        let traces = TraceService(radio: radio)
        let coverage = CoverageService(radio: radio, traces: traces, location: { GeoCoordinate(latitude: 37.75, longitude: -122.45) })
        coverage.start(target: .repeater(hashHex: "A3", name: "Twin Peaks"), interval: .seconds(60))
        try await waitUntil { coverage.lastError != nil }
        #expect(coverage.samples.isEmpty)
        coverage.stop()
    }
}

/// Opens only when `release()` is called, to hold a connect in progress.
final class GatedMQTTTransport: MQTTTransport {
    private let inner = FakeMQTTTransport()
    private let gate = Mutex<(open: Bool, waiter: CheckedContinuation<Void, Never>?)>((false, nil))

    func release() {
        let waiter = gate.withLock { state in
            state.open = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
    }

    func open() async throws {
        await withCheckedContinuation { continuation in
            let isOpen = gate.withLock { state in
                if !state.open { state.waiter = continuation }
                return state.open
            }
            if isOpen { continuation.resume() }
        }
        try await inner.open()
    }

    func send(_ data: Data) async throws { try await inner.send(data) }
    func receive() async throws -> Data? { try await inner.receive() }
    func close() async { await inner.close() }
}

@MainActor
struct ObserverRegressionTests {
    private func connectedRadio() async throws -> RadioController {
        let mock = MockRadio(state: MockRadio.demoState)
        let radio = RadioController(defaults: UserDefaults(suiteName: "obsr.\(UUID().uuidString)")!, simulatedRadio: mock)
        await radio.connect(to: .simulator)
        try await waitUntil { radio.isConnected }
        return radio
    }

    private func customSettings(_ observer: ObserverService) -> ObserverSettings {
        var settings = observer.settings
        settings.isEnabled = true
        settings.iata = "SFO"
        settings.broker = .custom
        settings.customHost = "broker.test"
        return settings
    }

    @Test func turningOffWhileConnectingStaysOff() async throws {
        let radio = try await connectedRadio()
        let transport = GatedMQTTTransport()
        let observer = ObserverService(
            radio: radio, defaults: UserDefaults(suiteName: "obsr.\(UUID().uuidString)")!, secrets: MemorySecrets(),
            reachability: FakeReachability(isOnWiFi: true), clientVersion: "m-Core test", makeTransport: { _ in transport }
        )
        let settings = customSettings(observer)
        observer.update(settings)
        try await waitUntil { observer.status == .connecting }

        var off = settings
        off.isEnabled = false
        observer.update(off)
        transport.release()
        try await Task.sleep(for: .milliseconds(200))
        #expect(observer.status == .off)
        await radio.disconnect()
    }

    @Test func brokerThatDropsAtOnceIsNotRedialledInALoop() async throws {
        let radio = try await connectedRadio()
        let transports = Mutex<[FakeMQTTTransport]>([])
        let observer = ObserverService(
            radio: radio, defaults: UserDefaults(suiteName: "obsr.\(UUID().uuidString)")!, secrets: MemorySecrets(),
            reachability: FakeReachability(isOnWiFi: true), clientVersion: "m-Core test",
            makeTransport: { _ in
                let transport = FakeMQTTTransport()
                transports.withLock { $0.append(transport) }
                return transport
            },
            retryDelays: [.seconds(60)]
        )
        observer.update(customSettings(observer))
        try await waitUntil { if case .connected = observer.status { true } else { false } }

        // The broker closes the connection.
        await transports.withLock { $0[0] }.close()
        try await waitUntil { if case .retrying = observer.status { true } else { false } }
        try await Task.sleep(for: .milliseconds(200))
        #expect(transports.withLock { $0.count } == 1)
        await radio.disconnect()
    }
}

struct InternetMapDecodingRegressionTests {
    @Test func oneMalformedNodeDoesNotDiscardTheList() throws {
        let json = Data("""
        [{"public_key":"0A","type":2,"adv_name":"Good","adv_lat":37.75,"adv_lon":-122.45,"last_advert":"2026-10-17T21:28:21Z"},
         {"public_key":"0B","type":"repeater","adv_name":"Bad type","adv_lat":1,"adv_lon":1},
         {"public_key":"0C","type":2,"adv_name":"Bad params","adv_lat":2,"adv_lon":2,"params":{"freq":"910.525"}},
         {"type":2,"adv_name":"No key","adv_lat":3,"adv_lon":3}]
        """.utf8)
        let nodes = try InternetMapService.parseNodes(json)
        #expect(nodes.map(\.name) == ["Good"])
        // Dates without fractional seconds still parse.
        #expect(nodes.first?.lastAdvert == Date(timeIntervalSince1970: 1_792_272_501))
    }
}
