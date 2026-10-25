import Foundation

/// A latitude/longitude pair in degrees.
public struct Coordinate: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// From the protocol's microdegrees.
    public init(latitudeE6: Int32, longitudeE6: Int32) {
        self.init(latitude: Double(latitudeE6) / 1e6, longitude: Double(longitudeE6) / 1e6)
    }

    public var latitudeE6: Int32 { Int32((latitude * 1e6).rounded()) }
    public var longitudeE6: Int32 { Int32((longitude * 1e6).rounded()) }

    /// (0, 0) is how the radio says "no position".
    public var isSet: Bool { latitude != 0 || longitude != 0 }

    public var isValid: Bool {
        isSet && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }

    /// Great-circle distance in metres (haversine).
    public func distance(to other: Coordinate) -> Double {
        let radius = 6_371_000.0
        let lat1 = latitude * .pi / 180
        let lat2 = other.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (other.longitude - longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * radius * atan2(sqrt(a), sqrt(1 - a))
    }

    /// Initial bearing in degrees (0 = north, clockwise).
    public func bearing(to other: Coordinate) -> Double {
        let lat1 = latitude * .pi / 180
        let lat2 = other.latitude * .pi / 180
        let dLon = (other.longitude - longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let degrees = atan2(y, x) * 180 / .pi
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }
}

/// One phone location reading.
public struct LocationFix: Equatable, Sendable {
    public var coordinate: Coordinate
    /// Metres; negative means invalid.
    public var horizontalAccuracy: Double
    public var timestamp: Date
    /// Metres above sea level, when the fix has a valid vertical component.
    public var altitude: Double?

    public init(coordinate: Coordinate, horizontalAccuracy: Double, timestamp: Date, altitude: Double? = nil) {
        self.coordinate = coordinate
        self.horizontalAccuracy = horizontalAccuracy
        self.timestamp = timestamp
        self.altitude = altitude
    }
}

/// How the GPS Feed decides when to write the phone's position to a radio without GPS (PLAN.md §4.1).
public struct GPSFeedSettings: Codable, Equatable, Sendable {
    public enum Preset: String, Codable, CaseIterable, Sendable {
        case walking
        case driving
        case stationary
        case custom
    }

    /// Precision applied before sending.
    public enum Rounding: String, Codable, CaseIterable, Sendable {
        case exact
        case approx100m
        case approx1km

        func apply(_ coordinate: Coordinate) -> Coordinate {
            let step: Double
            switch self {
            case .exact: return coordinate
            case .approx100m: step = 1000
            case .approx1km: step = 100
            }
            return Coordinate(
                latitude: (coordinate.latitude * step).rounded() / step,
                longitude: (coordinate.longitude * step).rounded() / step
            )
        }
    }

    public struct Thresholds: Codable, Equatable, Sendable {
        /// Ignore fixes less accurate than this (metres).
        public var maxAccuracy: Double
        /// Send when moved at least this far (metres)…
        public var minDistance: Double
        /// …and at least this long since the last send (seconds).
        public var minInterval: TimeInterval
        /// Re-send after this long if the radio's position drifted (seconds).
        public var heartbeat: TimeInterval

        public init(maxAccuracy: Double, minDistance: Double, minInterval: TimeInterval, heartbeat: TimeInterval) {
            self.maxAccuracy = maxAccuracy
            self.minDistance = minDistance
            self.minInterval = minInterval
            self.heartbeat = heartbeat
        }
    }

    public var isEnabled: Bool = true
    public var preset: Preset = .walking
    public var custom: Thresholds = Preset.walking.defaults
    public var rounding: Rounding = .exact
    /// Ignore fixes older than this (seconds).
    public var maxFixAge: TimeInterval = 30

    public var advertOnMove: Bool = false
    public var advertDistance: Double = 1_000
    public var advertMinInterval: TimeInterval = 900
    public var advertFlood: Bool = false

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case isEnabled, preset, custom, rounding, maxFixAge, advertOnMove, advertDistance, advertMinInterval, advertFlood
    }

    /// Missing keys keep their defaults, so settings saved by another version still load instead of resetting
    /// (which would, for one, turn a feed the user switched off back on).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = GPSFeedSettings()
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? defaults.isEnabled
        preset = try container.decodeIfPresent(Preset.self, forKey: .preset) ?? defaults.preset
        custom = try container.decodeIfPresent(Thresholds.self, forKey: .custom) ?? defaults.custom
        rounding = try container.decodeIfPresent(Rounding.self, forKey: .rounding) ?? defaults.rounding
        maxFixAge = try container.decodeIfPresent(TimeInterval.self, forKey: .maxFixAge) ?? defaults.maxFixAge
        advertOnMove = try container.decodeIfPresent(Bool.self, forKey: .advertOnMove) ?? defaults.advertOnMove
        advertDistance = try container.decodeIfPresent(Double.self, forKey: .advertDistance) ?? defaults.advertDistance
        advertMinInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .advertMinInterval) ?? defaults.advertMinInterval
        advertFlood = try container.decodeIfPresent(Bool.self, forKey: .advertFlood) ?? defaults.advertFlood
    }

    public var thresholds: Thresholds {
        preset == .custom ? custom : preset.defaults
    }
}

extension GPSFeedSettings.Preset {
    public var defaults: GPSFeedSettings.Thresholds {
        switch self {
        case .walking, .custom: .init(maxAccuracy: 30, minDistance: 25, minInterval: 30, heartbeat: 600)
        case .driving: .init(maxAccuracy: 50, minDistance: 150, minInterval: 30, heartbeat: 600)
        case .stationary: .init(maxAccuracy: 50, minDistance: 50, minInterval: 300, heartbeat: 1_800)
        }
    }

    public var title: String {
        switch self {
        case .walking: "Walking"
        case .driving: "Driving"
        case .stationary: "Stationary"
        case .custom: "Custom"
        }
    }
}

extension GPSFeedSettings.Rounding {
    public var title: String {
        switch self {
        case .exact: "Exact"
        case .approx100m: "About 100 m"
        case .approx1km: "About 1 km"
        }
    }
}
