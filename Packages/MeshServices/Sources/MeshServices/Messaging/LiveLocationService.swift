import Foundation
import MeshTools
import Observation

/// How long a live location share runs.
public enum LiveLocationLength: Int, CaseIterable, Sendable {
    case fifteenMinutes = 900
    case oneHour = 3_600

    public var duration: TimeInterval { TimeInterval(rawValue) }

    public var title: String {
        switch self {
        case .fifteenMinutes: "15 minutes"
        case .oneHour: "1 hour"
        }
    }
}

/// Timed live location: while a share runs, the conversation gets a location message whenever the phone has moved
/// at least 50 m, and at least every 2 minutes, but never more often than every 30 s. Shares keep running when the
/// conversation is closed and stop at expiry or when stopped.
@MainActor
@Observable
public final class LiveLocationService {
    public struct Share: Equatable, Sendable {
        public let conversationID: String
        public let startedAt: Date
        public let expiresAt: Date
        public internal(set) var lastSentAt: Date?
        public internal(set) var lastSentPosition: GeoCoordinate?
        public internal(set) var updatesSent = 0
        var lastAttemptAt: Date?

        public func remaining(at date: Date) -> TimeInterval {
            max(0, expiresAt.timeIntervalSince(date))
        }
    }

    /// Movement that triggers an update, in metres.
    public static let minimumMove: Double = 50
    /// Updates never go out more often than this.
    public static let minimumInterval: TimeInterval = 30
    /// An update goes out at least this often, even when standing still.
    public static let maximumInterval: TimeInterval = 120
    /// Label on the location messages; other apps see "Live location: lat, lon".
    public static let label = "Live location"

    /// Running shares by conversation ID.
    public private(set) var shares: [String: Share] = [:]
    public private(set) var lastError: String?

    @ObservationIgnored private let send: (_ text: String, _ conversationID: String) async throws -> Void
    @ObservationIgnored private let location: () -> GeoCoordinate?
    @ObservationIgnored private let setTracking: (Bool) -> Void
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let tickInterval: Duration?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var isTicking = false
    @ObservationIgnored private var isTracking = false

    /// - Parameters:
    ///   - send: Sends a message to a conversation.
    ///   - location: The phone's latest position, or nil if there's no fix yet.
    ///   - setTracking: Turned on while any share runs, so the location source can start and stop.
    ///   - tickInterval: How often shares are checked; nil leaves it to the caller (tests call `tick()`).
    public init(
        send: @escaping (_ text: String, _ conversationID: String) async throws -> Void,
        location: @escaping () -> GeoCoordinate?,
        setTracking: @escaping (Bool) -> Void = { _ in },
        now: @escaping () -> Date = { Date() },
        tickInterval: Duration? = .seconds(5)
    ) {
        self.send = send
        self.location = location
        self.setTracking = setTracking
        self.now = now
        self.tickInterval = tickInterval
    }

    /// Shares through the messaging service.
    public convenience init(
        messaging: MessagingService,
        location: @escaping () -> GeoCoordinate?,
        setTracking: @escaping (Bool) -> Void = { _ in }
    ) {
        self.init(
            send: { [weak messaging] text, conversationID in
                guard let messaging else { throw MessagingError.notConnected }
                try await messaging.send(text, to: conversationID)
            },
            location: location,
            setTracking: setTracking
        )
    }

    public func share(for conversationID: String) -> Share? {
        shares[conversationID]
    }

    /// Starts (or restarts) sharing to a conversation; the first update goes out as soon as there's a fix.
    public func start(conversationID: String, length: LiveLocationLength) {
        let date = now()
        shares[conversationID] = Share(conversationID: conversationID, startedAt: date, expiresAt: date.addingTimeInterval(length.duration))
        lastError = nil
        if !isTracking {
            isTracking = true
            setTracking(true)
        }
        startTimer()
    }

    public func stop(conversationID: String) {
        guard shares.removeValue(forKey: conversationID) != nil else { return }
        if shares.isEmpty { stopAll() }
    }

    /// Ends expired shares and sends the updates that are due.
    func tick() async {
        guard !isTicking else { return }
        isTicking = true
        defer { isTicking = false }
        let date = now()
        for (id, share) in shares where share.expiresAt <= date {
            shares[id] = nil
        }
        guard !shares.isEmpty else {
            stopAll()
            return
        }
        guard let position = location() else { return }
        for id in shares.keys.sorted() {
            guard let share = shares[id], isDue(share, position: position, at: date) else { continue }
            shares[id]?.lastAttemptAt = date
            let text = MessageFormat.locationText(latitude: position.latitude, longitude: position.longitude, label: Self.label)
            do {
                try await send(text, id)
                // The share may have been stopped while sending.
                guard shares[id] != nil else { continue }
                shares[id]?.lastSentAt = date
                shares[id]?.lastSentPosition = position
                shares[id]?.updatesSent += 1
                lastError = nil
            } catch {
                lastError = "Couldn't send live location: \(error.readable)"
            }
        }
    }

    private func isDue(_ share: Share, position: GeoCoordinate, at date: Date) -> Bool {
        if let attempt = share.lastAttemptAt, date.timeIntervalSince(attempt) < Self.minimumInterval { return false }
        guard let sentAt = share.lastSentAt, let sent = share.lastSentPosition else { return true }
        let elapsed = date.timeIntervalSince(sentAt)
        if elapsed < Self.minimumInterval { return false }
        return elapsed >= Self.maximumInterval || sent.distance(to: position) >= Self.minimumMove
    }

    private func startTimer() {
        guard timer == nil, let tickInterval else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                try? await Task.sleep(for: tickInterval)
            }
        }
    }

    private func stopAll() {
        shares.removeAll()
        timer?.cancel()
        timer = nil
        if isTracking {
            isTracking = false
            setTracking(false)
        }
    }
}
