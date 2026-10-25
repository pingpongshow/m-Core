import Foundation
import MeshCoreKit
import MeshStore
import Observation

/// Contact actions that change the radio (favourite, remove, paths, adverts) or local details (nickname, block, alerts).
@MainActor
@Observable
public final class ContactsService: RadioEventHandler {
    public private(set) var lastError: String?

    @ObservationIgnored private let radio: RadioController
    @ObservationIgnored private let messaging: MessagingService
    @ObservationIgnored private let clock = ContinuousClock()
    @ObservationIgnored private let pathWaiter = PushWaiter<PathDiscoveryResult>()

    public init(radio: RadioController, messaging: MessagingService) {
        self.radio = radio
        self.messaging = messaging
        radio.addHandler(self)
    }

    private func session() async throws -> MeshSession {
        guard let session = await radio.session() else { throw RemoteRequestError.notConnected }
        return session
    }

    private func record(_ keyHex: String) throws -> ContactRecord {
        guard let record = messaging.store?.contact(keyHex: keyHex) else { throw RemoteRequestError.unknownNode }
        return record
    }

    /// Rebuilds the radio's view of a stored contact.
    public static func contact(from record: ContactRecord) -> Contact? {
        guard let key = PublicKey(hex: record.keyHex) else { return nil }
        let path = record.outPathLength == 0xFF ? nil : MeshPath(encodedLength: UInt8(record.outPathLength), bytes: [UInt8](record.outPath))
        return Contact(
            publicKey: key, type: AdvertType(rawValue: UInt8(clamping: record.typeRaw)), flags: UInt8(clamping: record.flags),
            outPath: path, name: record.name, lastAdvert: UInt32(clamping: record.lastAdvert),
            latitudeE6: Int32(clamping: record.latitudeE6), longitudeE6: Int32(clamping: record.longitudeE6),
            lastModified: UInt32(clamping: record.lastModified)
        )
    }

    // MARK: Radio-side

    public func setFavourite(_ favourite: Bool, keyHex: String) async throws {
        let record = try record(keyHex)
        guard var contact = Self.contact(from: record) else { throw RemoteRequestError.unknownNode }
        contact.flags = favourite ? contact.flags | 0x01 : contact.flags & ~0x01
        try await session().perform(.addUpdateContact(contact))
        record.flags = Int(contact.flags)
        await messaging.syncContacts()
    }

    /// Removes the contact from the radio and the app (conversation history is kept).
    public func remove(keyHex: String) async throws {
        guard let key = PublicKey(hex: keyHex) else { throw RemoteRequestError.unknownNode }
        try await session().perform(.removeContact(key))
        if let record = messaging.store?.contact(keyHex: keyHex) { messaging.store?.delete(record) }
        messaging.store?.save()
    }

    /// Forgets the direct path so the next message floods and finds a new one.
    public func resetPath(keyHex: String) async throws {
        guard let key = PublicKey(hex: keyHex) else { throw RemoteRequestError.unknownNode }
        try await session().perform(.resetPath(key))
        let record = try record(keyHex)
        record.outPathLength = 0xFF
        record.outPath = Data()
        messaging.store?.save()
    }

    /// Re-broadcasts the contact's advert (zero-hop) so nearby nodes can add it.
    public func shareViaAdvert(keyHex: String) async throws {
        guard let key = PublicKey(hex: keyHex) else { throw RemoteRequestError.unknownNode }
        try await session().perform(.shareContact(key))
    }

    /// Advertises this radio: zero-hop reaches neighbours, flood reaches the whole mesh.
    public func sendAdvert(flood: Bool) async throws {
        try await session().perform(.sendSelfAdvert(flood: flood))
    }

    /// Adds a contact (e.g. from a QR code) to the radio.
    public func add(name: String, keyHex: String, type: AdvertType) async throws {
        guard let key = PublicKey(hex: keyHex) else { throw RemoteRequestError.unknownNode }
        try await session().perform(.addUpdateContact(Contact(publicKey: key, type: type, name: name)))
        await messaging.syncContacts()
    }

    /// Floods a request to the node and returns the paths it was heard on, plus the round trip.
    public func discoverPath(keyHex: String) async throws -> (result: PathDiscoveryResult, roundTrip: Duration) {
        guard let key = PublicKey(hex: keyHex) else { throw RemoteRequestError.unknownNode }
        let started = clock.now
        let sent = try await session().request(.sendPathDiscoveryRequest(key)) { response -> SentInfo? in
            if case .sent(let info) = response { return info }
            return nil
        }
        let timeout = meshTimeout(estimatedMs: sent.estimatedTimeoutMs, minimum: .seconds(30))
        let result = try await pathWaiter.wait(for: key.prefix.hex, timeout: timeout)
        let roundTrip = clock.now - started
        if let outPath = result.outPath, let record = messaging.store?.contact(keyHex: keyHex) {
            record.outPathLength = Int(outPath.encodedLength)
            record.outPath = Data(outPath.bytes)
            record.lastHeard = Date()
            messaging.store?.save()
        }
        return (result, roundTrip)
    }

    // MARK: Local-only

    public func setNickname(_ nickname: String?, keyHex: String) {
        messaging.store?.contact(keyHex: keyHex)?.nickname = nickname?.isEmpty == true ? nil : nickname
        messaging.store?.save()
    }

    public func setBlocked(_ blocked: Bool, keyHex: String) {
        messaging.store?.contact(keyHex: keyHex)?.isBlocked = blocked
        messaging.store?.save()
    }

    public func setAlertWhenHeard(_ alert: Bool, keyHex: String) {
        messaging.store?.contact(keyHex: keyHex)?.alertWhenHeard = alert
        messaging.store?.save()
    }

    // MARK: RadioEventHandler

    public func radioDidConnect(_ info: ConnectionInfo, session: MeshSession) async {}

    public func radioDidDisconnect() {
        pathWaiter.cancelAll()
    }

    public func radioDidReceive(_ push: Push, session: MeshSession) async {
        if case .pathDiscoveryResponse(let result) = push {
            pathWaiter.resolve(result.senderPrefix.hex, with: .success(result))
        }
    }
}
