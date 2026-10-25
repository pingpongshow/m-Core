import Foundation
import MeshCoreKit
import Testing
@testable import mCore

@MainActor
struct RadioConnectionModelTests {
    private func freshDefaults() -> UserDefaults {
        let name = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
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
        let model = RadioConnectionModel(defaults: defaults)
        #expect(model.status == .disconnected)

        await model.connect(to: .simulator)
        for _ in 0..<100 where model.connectionInfo == nil {
            try await Task.sleep(for: .milliseconds(20))
        }

        let info = try #require(model.connectionInfo)
        #expect(info.selfInfo.name == "m-Core Sim")
        #expect(model.status == .connected(name: "m-Core Sim"))
        #expect(RadioConnectionModel(defaults: defaults).lastTarget == .simulator)

        await model.disconnect()
        #expect(model.status == .disconnected)
        #expect(!model.isActive)
    }

    @Test func transportMatchesTarget() {
        let radio = MockRadio()
        #expect(RadioConnectionModel.makeTransport(for: .tcp(host: "h", port: 1), simulatedRadio: radio) is TCPTransport)
        #expect(RadioConnectionModel.makeTransport(for: .bluetooth(id: UUID(), name: "x"), simulatedRadio: radio) is BLETransport)
        #expect(RadioConnectionModel.makeTransport(for: .simulator, simulatedRadio: radio) is MockTransport)
    }
}
