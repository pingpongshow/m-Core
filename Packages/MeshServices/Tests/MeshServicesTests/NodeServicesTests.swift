import Foundation
import MeshCoreKit
import MeshStore
import Testing
@testable import MeshServices

@MainActor
struct NodeServicesTests {
    struct Harness {
        let mock: MockRadio
        let radio: RadioController
        let messaging: MessagingService
        let contacts: ContactsService
        let telemetry: TelemetryService
        @MainActor var store: RadioStore { messaging.store! }
    }

    private func connect() async throws -> Harness {
        let mock = MockRadio(state: MockRadio.demoState)
        let radio = RadioController(defaults: UserDefaults(suiteName: "nodes.\(UUID().uuidString)")!, simulatedRadio: mock)
        let messaging = MessagingService(
            radio: radio, defaults: UserDefaults(suiteName: "nodes.\(UUID().uuidString)")!,
            storeFactory: { try RadioStore(radioKeyHex: $0, inMemory: true) }
        )
        let contacts = ContactsService(radio: radio, messaging: messaging)
        let telemetry = TelemetryService(radio: radio, messaging: messaging)
        await radio.connect(to: .simulator)
        try await waitUntil { messaging.store != nil && !messaging.isSyncing && messaging.revision > 0 }
        return Harness(mock: mock, radio: radio, messaging: messaging, contacts: contacts, telemetry: telemetry)
    }

    private let bob = MockRadio.demoKey(0x14).hex
    private let hannah = MockRadio.demoKey(0x50).hex

    @Test func favouriteRoundTripsThroughRadio() async throws {
        let harness = try await connect()
        try await harness.contacts.setFavourite(true, keyHex: bob)
        #expect(harness.store.contact(keyHex: bob)?.isFavourite == true)
        #expect(harness.mock.current.contacts.first { $0.publicKey.hex == bob }?.isFavourite == true)

        try await harness.contacts.setFavourite(false, keyHex: hannah)
        #expect(harness.store.contact(keyHex: hannah)?.isFavourite == false)
        await harness.radio.disconnect()
    }

    @Test func contactConversionPreservesFields() async throws {
        let harness = try await connect()
        let record = try #require(harness.store.contact(keyHex: MockRadio.demoKey(0x0A).hex))
        let original = try #require(harness.mock.current.contacts.first { $0.publicKey.hex == record.keyHex })
        #expect(ContactsService.contact(from: record) == original)
        await harness.radio.disconnect()
    }

    @Test func removeResetAndShare() async throws {
        let harness = try await connect()
        try await harness.contacts.resetPath(keyHex: bob)
        #expect(harness.store.contact(keyHex: bob)?.outPathLength == 0xFF)
        #expect(harness.mock.current.pathResets.map(\.hex) == [bob])

        try await harness.contacts.shareViaAdvert(keyHex: bob)
        try await harness.contacts.sendAdvert(flood: true)
        #expect(harness.mock.current.advertsSent == 2)

        try await harness.contacts.remove(keyHex: bob)
        #expect(harness.store.contact(keyHex: bob) == nil)
        #expect(!harness.mock.current.contacts.contains { $0.publicKey.hex == bob })
        await harness.radio.disconnect()
    }

    @Test func addContactFromLink() async throws {
        let harness = try await connect()
        let key = MockRadio.demoKey(0x99).hex
        try await harness.contacts.add(name: "Quinn", keyHex: key, type: .chat)
        #expect(harness.store.contact(keyHex: key)?.name == "Quinn")
        await harness.radio.disconnect()
    }

    @Test func pathDiscoveryUpdatesPath() async throws {
        let harness = try await connect()
        let alice = MockRadio.demoKey(0x0A).hex
        let (result, roundTrip) = try await harness.contacts.discoverPath(keyHex: alice)
        #expect(result.outPath?.hashes == [[0x10], [0xA3]])
        #expect(result.inPath?.hashes == [[0xA3], [0x10]])
        #expect(roundTrip < .seconds(5))
        #expect(harness.store.contact(keyHex: alice)?.outPathLength == 2)
        await harness.radio.disconnect()
    }

    @Test func remoteTelemetryUpdatesLocationAndHistory() async throws {
        let harness = try await connect()
        harness.mock.update { state in
            if let index = state.contacts.firstIndex(where: { $0.publicKey.hex == bob }) {
                state.contacts[index].latitudeE6 = 37_800_000
                state.contacts[index].longitudeE6 = -122_400_000
            }
        }
        let readings = try await harness.telemetry.request(from: bob)
        #expect(readings.first { $0.kind == .voltage }?.value == 3.9)
        let contact = try #require(harness.store.contact(keyHex: bob))
        #expect(contact.latitudeE6 == 37_800_000)
        #expect(harness.store.telemetry(keyHex: bob).map(\.kind) == ["voltage"])
        #expect(harness.store.positions(keyHex: bob).last?.source == "telemetry")
        #expect(harness.telemetry.latest[bob]?.count == 2)
        await harness.radio.disconnect()
    }

    @Test func selfTelemetry() async throws {
        let harness = try await connect()
        let readings = try await harness.telemetry.requestSelf()
        #expect(readings.first?.value == 4.05)
        let selfKey = try #require(harness.radio.selfInfo?.publicKey.hex)
        #expect(harness.telemetry.latest[selfKey] != nil)
        await harness.radio.disconnect()
    }

    @Test func localOnlyDetails() async throws {
        let harness = try await connect()
        harness.contacts.setNickname("Bobby", keyHex: bob)
        harness.contacts.setBlocked(true, keyHex: bob)
        harness.contacts.setAlertWhenHeard(true, keyHex: bob)
        let record = try #require(harness.store.contact(keyHex: bob))
        #expect(record.displayName == "Bobby")
        #expect(record.isBlocked && record.alertWhenHeard)
        harness.contacts.setNickname("", keyHex: bob)
        #expect(record.displayName == "Bob Martinez")
        await harness.radio.disconnect()
    }
}
