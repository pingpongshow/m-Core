import Foundation
import MeshCoreKit
import MeshStore
import Observation

/// Requests and records CayenneLPP telemetry from nodes and from the connected radio.
@MainActor
@Observable
public final class TelemetryService: RadioEventHandler {
    /// Latest readings per node key (hex). The connected radio is keyed by its own key.
    public private(set) var latest: [String: [LPPReading]] = [:]
    public private(set) var updatedAt: [String: Date] = [:]

    @ObservationIgnored private let radio: RadioController
    @ObservationIgnored private let messaging: MessagingService
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let waiter = PushWaiter<[LPPReading]>()

    public init(radio: RadioController, messaging: MessagingService, now: @escaping () -> Date = { Date() }) {
        self.radio = radio
        self.messaging = messaging
        self.now = now
        radio.addHandler(self)
    }

    /// Asks a node for telemetry. Its location comes back only if it allows that (telemetry location permission).
    @discardableResult
    public func request(from keyHex: String) async throws -> [LPPReading] {
        guard let session = await radio.session() else { throw RemoteRequestError.notConnected }
        guard let key = PublicKey(hex: keyHex) else { throw RemoteRequestError.unknownNode }
        let sent = try await session.request(.sendTelemetryRequest(key)) { response -> SentInfo? in
            if case .sent(let info) = response { return info }
            return nil
        }
        return try await waiter.wait(for: key.prefix.hex, timeout: meshTimeout(estimatedMs: sent.estimatedTimeoutMs))
    }

    /// Reads the connected radio's own sensors (battery, temperature, GPS if fitted).
    @discardableResult
    public func requestSelf() async throws -> [LPPReading] {
        guard let session = await radio.session(), let selfKey = radio.selfInfo?.publicKey else { throw RemoteRequestError.notConnected }
        let pending = Task { try await waiter.wait(for: selfKey.prefix.hex, timeout: .seconds(10)) }
        do {
            try await session.sendExpectingPush(.sendTelemetryRequest(nil))
        } catch {
            // Nothing will answer; don't leave the wait running until its timeout.
            waiter.resolve(selfKey.prefix.hex, with: .failure(error))
            throw error
        }
        return try await pending.value
    }

    public func radioDidConnect(_ info: ConnectionInfo, session: MeshSession) async {}

    public func radioDidDisconnect() {
        waiter.cancelAll()
    }

    public func radioDidReceive(_ push: Push, session: MeshSession) async {
        guard case .telemetryResponse(let response) = push else { return }
        let readings = CayenneLPP.decode(response.lpp)
        record(readings, prefix: response.senderPrefix)
        waiter.resolve(response.senderPrefix.hex, with: .success(readings))
    }

    private func record(_ readings: [LPPReading], prefix: KeyPrefix) {
        let date = now()
        let selfKey = radio.selfInfo?.publicKey
        let keyHex: String
        if let selfKey, prefix.matches(selfKey) {
            keyHex = selfKey.hex
        } else if let contact = messaging.store?.contact(prefixHex: prefix.hex) {
            keyHex = contact.keyHex
            if let gps = readings.first(where: { $0.kind == .gps }), gps.values[0] != 0 || gps.values[1] != 0 {
                let latitudeE6 = Int((gps.values[0] * 1e6).rounded())
                let longitudeE6 = Int((gps.values[1] * 1e6).rounded())
                if latitudeE6 != contact.latitudeE6 || longitudeE6 != contact.longitudeE6 {
                    messaging.store?.addPosition(
                        keyHex: keyHex, latitudeE6: latitudeE6, longitudeE6: longitudeE6, at: date, source: "telemetry"
                    )
                }
                contact.latitudeE6 = latitudeE6
                contact.longitudeE6 = longitudeE6
            }
            contact.lastHeard = date
        } else {
            keyHex = prefix.hex
        }
        latest[keyHex] = readings
        updatedAt[keyHex] = date
        guard let store = messaging.store else { return }
        for reading in readings where reading.kind != .gps {
            store.addTelemetry(keyHex: keyHex, at: date, channel: Int(reading.channel), kind: reading.kind.name, value: reading.value)
        }
        store.save()
    }
}
