import Foundation
import MeshCoreKit
import MeshStore
import Observation

/// "Request position": asks a contact for telemetry and, if the reply carries GPS, shows it in the conversation
/// as a location card and updates the contact's position. The entries are local; nothing is posted to the chat.
@MainActor
@Observable
public final class PositionRequestService {
    public enum Outcome: Equatable, Sendable {
        case position(latitude: Double, longitude: Double)
        /// The contact replied without a location (it doesn't share one, or has no fix).
        case noPosition
        /// No reply before the timeout.
        case noReply
    }

    /// Contacts (key hex) with a request in flight.
    public private(set) var pending: Set<String> = []

    @ObservationIgnored private let messaging: MessagingService
    @ObservationIgnored private let requestTelemetry: (String) async throws -> [LPPReading]

    /// - Parameter requestTelemetry: Sends a telemetry request to a contact (key hex) and returns the decoded reply,
    ///   throwing `RemoteRequestError.timedOut` if none comes.
    public init(messaging: MessagingService, requestTelemetry: @escaping (String) async throws -> [LPPReading]) {
        self.messaging = messaging
        self.requestTelemetry = requestTelemetry
    }

    /// Requests a chat contact's position and records the answer in its conversation.
    @discardableResult
    public func requestPosition(from keyHex: String) async throws -> Outcome {
        guard let store = messaging.store else { throw RemoteRequestError.notConnected }
        guard let contact = store.contact(keyHex: keyHex), AdvertType(rawValue: UInt8(clamping: contact.typeRaw)) == .chat else {
            throw RemoteRequestError.unknownNode
        }
        let key = contact.keyHex
        let name = contact.displayName
        let conversationID = ConversationID.direct(keyHex: key).description
        pending.insert(key)
        defer { pending.remove(key) }

        let outcome: Outcome
        do {
            outcome = Self.outcome(from: try await requestTelemetry(key))
        } catch RemoteRequestError.timedOut {
            outcome = .noReply
        }

        switch outcome {
        case .position(let latitude, let longitude):
            updatePosition(of: key, latitude: latitude, longitude: longitude)
            messaging.addLocalMessage(
                MessageFormat.locationText(latitude: latitude, longitude: longitude, label: "Position"),
                kind: .positionReport, senderName: name, to: conversationID
            )
        case .noPosition:
            messaging.addLocalMessage("\(name) didn't share a position.", kind: .notice, to: conversationID)
        case .noReply:
            messaging.addLocalMessage("No reply from \(name) to the position request.", kind: .notice, to: conversationID)
        }
        return outcome
    }

    static func outcome(from readings: [LPPReading]) -> Outcome {
        guard let gps = readings.first(where: { $0.kind == .gps }), gps.values.count >= 2,
              gps.values[0] != 0 || gps.values[1] != 0 else { return .noPosition }
        return .position(latitude: gps.values[0], longitude: gps.values[1])
    }

    /// Records the position on the contact, unless the telemetry service already did.
    private func updatePosition(of keyHex: String, latitude: Double, longitude: Double) {
        guard let store = messaging.store, let contact = store.contact(keyHex: keyHex) else { return }
        let latitudeE6 = Int((latitude * 1e6).rounded())
        let longitudeE6 = Int((longitude * 1e6).rounded())
        guard latitudeE6 != contact.latitudeE6 || longitudeE6 != contact.longitudeE6 else { return }
        store.addPosition(keyHex: keyHex, latitudeE6: latitudeE6, longitudeE6: longitudeE6, at: messaging.now(), source: "telemetry")
        contact.latitudeE6 = latitudeE6
        contact.longitudeE6 = longitudeE6
    }
}
