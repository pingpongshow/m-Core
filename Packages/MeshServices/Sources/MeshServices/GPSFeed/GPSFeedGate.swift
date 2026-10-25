import Foundation

/// Decides which phone fixes are written to the radio. Every write is a flash write on the radio,
/// so fixes are filtered for quality and gated by distance and time.
public struct GPSFeedGate: Sendable {
    public enum Decision: Equatable, Sendable {
        case send(Coordinate)
        case skip(SkipReason)
    }

    public enum SkipReason: Equatable, Sendable {
        case invalid
        case inaccurate
        case stale
        case notMovedEnough
        case tooSoon
    }

    public var settings: GPSFeedSettings
    public private(set) var lastSent: Coordinate?
    public private(set) var lastSentAt: Date?

    public init(settings: GPSFeedSettings) {
        self.settings = settings
    }

    /// Starts from the position the radio already holds, so an unchanged position isn't rewritten on connect.
    public mutating func reset(radioPosition: Coordinate?, at date: Date) {
        if let radioPosition, radioPosition.isValid {
            lastSent = radioPosition
            lastSentAt = date
        } else {
            lastSent = nil
            lastSentAt = nil
        }
    }

    public mutating func recordSent(_ coordinate: Coordinate, at date: Date) {
        lastSent = coordinate
        lastSentAt = date
    }

    /// - Parameter radioPosition: What the radio last reported, used to spot drift for the heartbeat.
    public func evaluate(_ fix: LocationFix, now: Date, radioPosition: Coordinate?) -> Decision {
        guard fix.coordinate.isValid else { return .skip(.invalid) }
        let limits = settings.thresholds
        guard fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= limits.maxAccuracy else { return .skip(.inaccurate) }
        guard now.timeIntervalSince(fix.timestamp) <= settings.maxFixAge else { return .skip(.stale) }

        let coordinate = settings.rounding.apply(fix.coordinate)
        guard let lastSent, let lastSentAt else { return .send(coordinate) }

        let elapsed = now.timeIntervalSince(lastSentAt)
        if coordinate.distance(to: lastSent) >= limits.minDistance {
            return elapsed >= limits.minInterval ? .send(coordinate) : .skip(.tooSoon)
        }
        if elapsed >= limits.heartbeat, let radioPosition, radioPosition.distance(to: lastSent) >= limits.minDistance {
            return .send(coordinate)
        }
        return .skip(.notMovedEnough)
    }
}
