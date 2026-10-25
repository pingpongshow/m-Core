import Foundation
import MeshCoreKit
import Testing
@testable import MeshServices

@MainActor
struct RadioControllerTests {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "radio.\(UUID().uuidString)")!
    }

    @Test func targetRoundTripsThroughCodable() throws {
        let targets: [RadioTarget] = [
            .bluetooth(id: UUID(), name: "MeshCore-Alice"),
            .tcp(host: "10.1.1.50", port: 5000),
            .simulator,
        ]
        for target in targets {
            let data = try JSONEncoder().encode(target)
            #expect(try JSONDecoder().decode(RadioTarget.self, from: data) == target)
        }
    }

    @Test func connectsToSimulatorAndRemembersTarget() async throws {
        let defaults = freshDefaults()
        let mock = MockRadio()
        let controller = RadioController(defaults: defaults, simulatedRadio: mock)
        #expect(!controller.isActive)

        await controller.connect(to: .simulator)
        try await waitUntil { controller.isConnected && controller.battery != nil }

        #expect(controller.connectionInfo?.selfInfo.name == "m-Core Sim")
        #expect(controller.selfInfo?.name == "m-Core Sim")
        #expect(controller.battery?.millivolts == 4050)
        #expect(RadioController(defaults: defaults, simulatedRadio: mock).lastTarget == .simulator)

        await controller.disconnect()
        #expect(!controller.isActive)
        #expect(controller.selfInfo == nil)
    }

    @Test func handlersHearConnectPushAndDisconnect() async throws {
        let mock = MockRadio()
        let controller = RadioController(defaults: freshDefaults(), simulatedRadio: mock)
        let handler = RecordingHandler()
        controller.addHandler(handler)

        await controller.connect(to: .simulator)
        try await waitUntil { handler.connects == 1 }

        await controller.disconnect()
        #expect(handler.disconnects == 1)
    }

    @Test func refreshSelfInfoPicksUpChanges() async throws {
        let mock = MockRadio()
        let controller = RadioController(defaults: freshDefaults(), simulatedRadio: mock)
        await controller.connect(to: .simulator)
        try await waitUntil { controller.isConnected }

        mock.update { $0.selfInfo.name = "Renamed" }
        await controller.refreshSelfInfo()
        #expect(controller.selfInfo?.name == "Renamed")
        await controller.disconnect()
    }

    @Test func withoutASimulatedRadioTheSimulatorIsRefusedAndForgotten() async throws {
        let defaults = UserDefaults(suiteName: "radio.\(UUID().uuidString)")!
        defaults.set(try JSONEncoder().encode(RadioTarget.simulator), forKey: "radio.lastTarget")
        let radio = RadioController(defaults: defaults)
        #expect(radio.lastTarget == nil)
        #expect(defaults.data(forKey: "radio.lastTarget") == nil)
        #expect(radio.knownRadios.isEmpty)

        await radio.connect(to: .simulator)
        #expect(!radio.isActive)
        #expect(radio.connectionProblem != nil)
        #expect(RadioController.makeTransport(for: .simulator, simulatedRadio: nil) is UnavailableTransport)
    }

    @Test func transportMatchesTarget() {
        let radio = MockRadio()
        #expect(RadioController.makeTransport(for: .tcp(host: "h", port: 1), simulatedRadio: radio) is TCPTransport)
        #expect(RadioController.makeTransport(for: .bluetooth(id: UUID(), name: "x"), simulatedRadio: radio) is BLETransport)
        #expect(RadioController.makeTransport(for: .simulator, simulatedRadio: radio) is MockTransport)
    }
}

@MainActor
final class RecordingHandler: RadioEventHandler {
    private(set) var connects = 0
    private(set) var disconnects = 0
    private(set) var pushes: [Push] = []

    func radioDidConnect(_ info: ConnectionInfo, session: MeshSession) async { connects += 1 }
    func radioDidDisconnect() { disconnects += 1 }
    func radioDidReceive(_ push: Push, session: MeshSession) async { pushes.append(push) }
}
