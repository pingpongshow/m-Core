import Foundation
import MeshCoreKit
import MeshStore
import Testing
@testable import MeshServices

@MainActor
struct RemoteNodeTests {
    struct Connection {
        let mock: MockRadio
        let radio: RadioController
        let messaging: MessagingService
        let remote: RemoteNodeService
    }

    private func connect() async throws -> Connection {
        let mock = MockRadio(state: MockRadio.demoState)
        let radio = RadioController(defaults: UserDefaults(suiteName: "remote.\(UUID().uuidString)")!, simulatedRadio: mock)
        let messaging = MessagingService(
            radio: radio, defaults: UserDefaults(suiteName: "remote.\(UUID().uuidString)")!,
            storeFactory: { try RadioStore(radioKeyHex: $0, inMemory: true) }
        )
        let remote = RemoteNodeService(radio: radio, messaging: messaging)
        await radio.connect(to: .simulator)
        try await waitUntil { messaging.store != nil && !messaging.isSyncing && messaging.revision > 0 }
        return Connection(mock: mock, radio: radio, messaging: messaging, remote: remote)
    }

    private let repeater = MockRadio.demoKey(0x10).hex

    @Test func parsesRepeaterStatus() async throws {
        let connection = try await connect()
        let radio = connection.radio
        let remote = connection.remote
        let status = try await remote.status(keyHex: repeater)
        #expect(status.batteryMillivolts == 4_120)
        #expect(status.noiseFloor == -112)
        #expect(status.uptimeSeconds == 259_200)
        #expect(status.lastSNR == 9.5)
        #expect(status.floodDuplicates == 410)
        #expect(status.receiveErrors == 7)
        await radio.disconnect()
    }

    @Test func statusWithoutNewerFields() {
        var bytes = [UInt8](repeating: 0, count: 48)
        bytes[0] = 0x10
        bytes[1] = 0x10
        let status = RepeaterStatus(payload: Data(bytes))
        #expect(status?.batteryMillivolts == 0x1010)
        #expect(status?.rxAirtimeSeconds == nil)
        #expect(RepeaterStatus(payload: Data(count: 10)) == nil)
    }

    @Test func listsNeighbours() async throws {
        let connection = try await connect()
        let mock = connection.mock
        let radio = connection.radio
        let remote = connection.remote
        let neighbours = try await remote.neighbours(keyHex: repeater)
        #expect(neighbours.count == 2)
        #expect(neighbours[0].keyPrefixHex == Data(mock.current.contacts[0].publicKey.bytes.prefix(6)).hexString)
        #expect(neighbours[0].heardSecondsAgo == 30)
        #expect(neighbours[0].snr == 6)
        #expect(neighbours[1].snr == 3)
        await radio.disconnect()
    }

    @Test func remoteCommandLine() async throws {
        let connection = try await connect()
        let radio = connection.radio
        let messaging = connection.messaging
        let remote = connection.remote
        let login = try await remote.login(keyHex: repeater, password: "password")
        #expect(login.isAdmin)
        #expect(remote.logins[repeater] != nil)

        let reply = try await remote.runCommand("ver", keyHex: repeater)
        #expect(reply == "v1.18.0 (Build: 15 Oct 2026)")
        #expect(remote.transcripts[repeater]?.map(\.isCommand) == [true, false])
        // CLI replies don't become chat messages.
        #expect(messaging.store?.messages(conversationID: ConversationID.direct(keyHex: repeater).description).isEmpty == true)
        await radio.disconnect()
    }

    @Test func localCommandLine() async throws {
        let connection = try await connect()
        let radio = connection.radio
        let remote = connection.remote
        #expect(try await remote.runLocalCommand("ver") == "v1.18.0 (Build: 15 Oct 2026)")
        await radio.disconnect()
    }
}
