import Foundation
import MeshCoreKit
import MeshTools
import Synchronization
import Testing
@testable import MeshServices

/// Answers CONNECT, PINGREQ and QoS 0 PUBLISH like a broker, recording what the client sent.
final class FakeMQTTTransport: MQTTTransport {
    struct Published: Equatable {
        var topic: String
        var payload: String
    }

    private struct State {
        var inbox: [Data] = []
        var waiter: CheckedContinuation<Data?, Never>?
        var closed = false
        var connectPacket: Data?
        var published: [Published] = []
    }

    private let state = Mutex(State())
    private let refuse: Bool

    init(refuse: Bool = false) {
        self.refuse = refuse
    }

    var published: [Published] { state.withLock { $0.published } }
    var connectPacket: Data? { state.withLock { $0.connectPacket } }

    func open() async throws {}

    func send(_ data: Data) async throws {
        let bytes = [UInt8](data)
        guard let first = bytes.first else { return }
        switch first >> 4 {
        case 1:
            state.withLock { $0.connectPacket = data }
            deliver(Data([0x20, 0x02, 0x00, refuse ? 0x05 : 0x00]))
        case 3:
            var index = 1
            var length = 0
            var multiplier = 1
            while true {
                let byte = Int(bytes[index]); index += 1
                length += (byte & 0x7F) * multiplier
                multiplier *= 128
                if byte & 0x80 == 0 { break }
            }
            let topicLength = Int(bytes[index]) << 8 | Int(bytes[index + 1])
            let topic = String(decoding: bytes[(index + 2)..<(index + 2 + topicLength)], as: UTF8.self)
            let payload = String(decoding: bytes[(index + 2 + topicLength)..<(index + length)], as: UTF8.self)
            state.withLock { $0.published.append(Published(topic: topic, payload: payload)) }
        case 12:
            deliver(Data([0xD0, 0x00]))
        default:
            break
        }
    }

    func receive() async throws -> Data? {
        await withCheckedContinuation { continuation in
            let ready: Data?? = state.withLock { state in
                if !state.inbox.isEmpty { return .some(state.inbox.removeFirst()) }
                if state.closed { return .some(nil) }
                state.waiter = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    func close() async {
        let waiter = state.withLock { state in
            state.closed = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: nil)
    }

    private func deliver(_ data: Data) {
        let waiter: CheckedContinuation<Data?, Never>? = state.withLock { state in
            if let waiter = state.waiter {
                state.waiter = nil
                return waiter
            }
            state.inbox.append(data)
            return nil
        }
        waiter?.resume(returning: data)
    }
}

final class MemorySecrets: SecretStore, @unchecked Sendable {
    private var values: [String: String] = [:]
    func secret(for key: String) -> String? { values[key] }
    func setSecret(_ value: String?, for key: String) { values[key] = value }
}

@MainActor
final class FakeReachability: NetworkReachability {
    var isOnWiFi: Bool { didSet { onChange?() } }
    var onChange: (() -> Void)?
    init(isOnWiFi: Bool) { self.isOnWiFi = isOnWiFi }
}

/// A flood TXT_MSG packet with a 4-byte payload.
let sampleRawPacket = Data([0x09, 0x00, 0xA1, 0xB2, 0xC3, 0xD4])

@MainActor
struct ObserverAndLogTests {
    private func connect() async throws -> (MockRadio, RadioController) {
        let mock = MockRadio(state: MockRadio.demoState)
        let radio = RadioController(defaults: UserDefaults(suiteName: "obs.\(UUID().uuidString)")!, simulatedRadio: mock)
        await radio.connect(to: .simulator)
        try await waitUntil { radio.isConnected }
        return (mock, radio)
    }

    @Test func rxLogDecodesKeepsNewestFirstAndCaps() async throws {
        let (mock, radio) = try await connect()
        let log = RxLogService(radio: radio, limit: 2)
        mock.push(.rxLog(RxLogEntry(snr: 5.5, rssi: -90, raw: sampleRawPacket)))
        mock.push(.rxLog(RxLogEntry(snr: 1, rssi: -110, raw: Data([0xFF]))))
        mock.push(.rxLog(RxLogEntry(snr: 2, rssi: -100, raw: sampleRawPacket)))
        try await waitUntil { log.totalHeard == 3 }
        #expect(log.records.count == 2)
        #expect(log.records[0].snr == 2)
        #expect(log.records[0].packet?.payloadType == .textMessage)
        #expect(log.records[1].packet == nil)

        log.isPaused = true
        mock.push(.rxLog(RxLogEntry(snr: 3, rssi: -95, raw: sampleRawPacket)))
        try await waitUntil { log.totalHeard == 4 }
        #expect(log.records.count == 2)
        await radio.disconnect()
    }

    @Test func observerIsOffByDefaultAndNeedsSetup() async throws {
        let (_, radio) = try await connect()
        let observer = ObserverService(
            radio: radio, defaults: UserDefaults(suiteName: "obs.\(UUID().uuidString)")!, secrets: MemorySecrets(),
            reachability: FakeReachability(isOnWiFi: true), clientVersion: "m-Core test",
            makeTransport: { _ in FakeMQTTTransport() }
        )
        #expect(observer.status == .off)
        var settings = observer.settings
        settings.isEnabled = true
        observer.update(settings)
        #expect(observer.status == .needsSetup("Enter your region's three-letter airport code."))
        await radio.disconnect()
    }

    @Test func letsMeshSignsTokenOnRadioAndForwardsPackets() async throws {
        let (mock, radio) = try await connect()
        let transport = FakeMQTTTransport()
        let reachability = FakeReachability(isOnWiFi: true)
        let observer = ObserverService(
            radio: radio, defaults: UserDefaults(suiteName: "obs.\(UUID().uuidString)")!, secrets: MemorySecrets(),
            reachability: reachability, clientVersion: "m-Core test", makeTransport: { _ in transport }
        )
        var settings = observer.settings
        settings.isEnabled = true
        settings.iata = "sfo"
        observer.update(settings)
        try await waitUntil { if case .connected = observer.status { true } else { false } }

        // Username and a radio-signed JWT went in CONNECT.
        let connect = String(decoding: try #require(transport.connectPacket), as: UTF8.self)
        let keyHex = mock.current.selfInfo.publicKey.hex.uppercased()
        #expect(connect.contains("v1_\(keyHex)"))
        // The JWT's header is base64url of {"alg":"Ed25519",...}.
        #expect(connect.contains("eyJhbGciOiJFZDI1NTE5Ii"))

        try await waitUntil { transport.published.contains { $0.topic.hasSuffix("/status") } }
        #expect(observer.packetsTopic == "meshcore/SFO/\(keyHex)/packets")

        mock.push(.rxLog(RxLogEntry(snr: 6.75, rssi: -88, raw: sampleRawPacket)))
        try await waitUntil { observer.packetsSent == 1 }
        let packet = try #require(transport.published.first { $0.topic.hasSuffix("/packets") })
        #expect(packet.payload.contains("\"SNR\":\"6\""))
        #expect(packet.payload.contains("\"RSSI\":\"-88\""))

        // Leaving Wi-Fi pauses the uplink.
        reachability.isOnWiFi = false
        #expect(observer.status == .waitingForWiFi)
        await radio.disconnect()
    }

    @Test func refusedConnectionRetries() async throws {
        let (_, radio) = try await connect()
        let observer = ObserverService(
            radio: radio, defaults: UserDefaults(suiteName: "obs.\(UUID().uuidString)")!, secrets: MemorySecrets(),
            reachability: FakeReachability(isOnWiFi: true), clientVersion: "m-Core test",
            makeTransport: { _ in FakeMQTTTransport(refuse: true) }, retryDelays: [.seconds(60)]
        )
        var settings = observer.settings
        settings.isEnabled = true
        settings.iata = "LAX"
        settings.broker = .custom
        settings.customHost = "broker.example"
        observer.update(settings)
        try await waitUntil { if case .retrying = observer.status { true } else { false } }
        await radio.disconnect()
        #expect(observer.status == .waitingForRadio)
    }

    @Test func coverageWalkPingsRepeaterAndLogsHeardPackets() async throws {
        let (mock, radio) = try await connect()
        let traces = TraceService(radio: radio)
        let coverage = CoverageService(radio: radio, traces: traces, location: { GeoCoordinate(latitude: 37.75, longitude: -122.45) })
        coverage.start(target: .repeater(hashHex: "A3", name: "Twin Peaks"), interval: .seconds(60))
        try await waitUntil { coverage.samples.count == 1 }
        #expect(coverage.samples[0].success)
        #expect(coverage.samples[0].snr == 5.5)

        mock.push(.rxLog(RxLogEntry(snr: 4, rssi: -101, raw: sampleRawPacket)))
        try await waitUntil { coverage.samples.count == 2 }
        #expect(coverage.samples[1].rssi == -101)
        #expect(coverage.csv().split(whereSeparator: \.isNewline).count == 3)
        #expect(coverage.gpx().contains("<wpt"))

        coverage.stop()
        #expect(!coverage.isRunning)
        await radio.disconnect()
    }

    @Test func brokerRefusalsReadPlainly() {
        #expect(ObserverService.refusalMessage(.notAuthorized) == "The broker didn't accept the sign-in.")
        #expect(!ObserverService.refusalMessage(.serverUnavailable).contains("serverUnavailable"))
    }

    @Test func coverageWalkPingsAsSoonAsTheFirstFixArrives() async throws {
        let (_, radio) = try await connect()
        let traces = TraceService(radio: radio)
        // No fix for the first ping, as when the phone's GPS has only just started.
        var fix: GeoCoordinate?
        let coverage = CoverageService(radio: radio, traces: traces, location: { fix })
        coverage.start(target: .repeater(hashHex: "A3", name: "Twin Peaks"), interval: .seconds(600))
        try await waitUntil { coverage.lastError == "Waiting for your location." }
        fix = GeoCoordinate(latitude: 37.75, longitude: -122.45)
        // Long before the 10-minute interval.
        try await waitUntil { coverage.samples.count == 1 }
        #expect(coverage.lastError == nil)
        coverage.stop()
        await radio.disconnect()
    }
}
