import Foundation
import MeshCoreKit
import MeshStore
import Testing
@testable import MeshServices

@MainActor
struct ToolsTests {
    private func connect(defaults: UserDefaults? = nil) async throws -> (MockRadio, RadioController) {
        let mock = MockRadio(state: MockRadio.demoState)
        let radio = RadioController(defaults: defaults ?? UserDefaults(suiteName: "tools.\(UUID().uuidString)")!, simulatedRadio: mock)
        await radio.connect(to: .simulator)
        try await waitUntil { radio.isConnected }
        return (mock, radio)
    }

    @Test func statsRefreshAndMonitoring() async throws {
        let (_, radio) = try await connect()
        let stats = RadioStatsService(radio: radio)
        await stats.refresh()
        #expect(stats.core?.uptimeSeconds == 3_600)
        #expect(stats.packets?.received == 1_204)
        #expect(stats.radioStats?.lastSNR == 7.25)
        #expect(stats.samples.count == 1)

        stats.startMonitoring(interval: .milliseconds(20))
        try await waitUntil { stats.samples.count >= 3 }
        stats.stopMonitoring()
        #expect(!stats.isMonitoring)
        await radio.disconnect()
    }

    @Test func traceReportsHops() async throws {
        let (_, radio) = try await connect()
        let traces = TraceService(radio: radio)
        let outcome = try await traces.trace(path: [[0x10], [0xA3]])
        #expect(outcome.hops == [TraceHop(hashHex: "10", snr: 8), TraceHop(hashHex: "A3", snr: 6)])
        #expect(outcome.finalSNR == 5.5)
        #expect(traces.history.count == 1)
        await radio.disconnect()
    }

    @Test func discoveryVisitsPresetsAndRestores() async throws {
        let (mock, radio) = try await connect()
        let original = mock.current.selfInfo.radio
        let discovery = MeshDiscoveryService(radio: radio, defaults: UserDefaults(suiteName: "disc.\(UUID().uuidString)")!)
        let presets = Array(RadioPreset.all.filter { $0.radio != original }.prefix(2))

        discovery.start(presets: presets, dwell: .milliseconds(200))
        try await waitUntil { if case .listening(_, 0, _, _) = discovery.state { true } else { false } }
        #expect(mock.current.selfInfo.radio == presets[0].radio)
        mock.push(.newAdvert(Contact(publicKey: MockRadio.demoKey(0x88), type: .repeater, name: "Far Hill")))
        mock.push(.rxLog(RxLogEntry(snr: 4, rssi: -100, raw: Data([0x11]))))

        try await waitUntil(timeout: .seconds(5)) { discovery.state == .finished }
        #expect(discovery.results.count == 2)
        #expect(discovery.results[0].nodes.map(\.name) == ["Far Hill"])
        #expect(discovery.results[0].packetsHeard == 1)
        #expect(mock.current.selfInfo.radio == original)
        await radio.disconnect()
    }

    @Test func interruptedDiscoveryRestoresOnNextConnect() async throws {
        let defaults = UserDefaults(suiteName: "disc.\(UUID().uuidString)")!
        let (mock, radio) = try await connect()
        let original = mock.current.selfInfo.radio
        let discovery = MeshDiscoveryService(radio: radio, defaults: defaults)
        let preset = try #require(RadioPreset.all.first { $0.radio != original })

        discovery.start(presets: [preset], dwell: .seconds(30))
        try await waitUntil { mock.current.selfInfo.radio == preset.radio }
        // The app goes away mid-scan.
        await radio.disconnect()
        discovery.cancel()

        await radio.connect(to: .simulator)
        try await waitUntil { mock.current.selfInfo.radio == original }
        await radio.disconnect()
    }
}
