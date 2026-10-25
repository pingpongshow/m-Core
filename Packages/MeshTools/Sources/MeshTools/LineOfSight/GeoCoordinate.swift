import Foundation

/// A WGS-84 latitude/longitude in degrees.
public struct GeoCoordinate: Equatable, Hashable, Sendable, Codable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Mean Earth radius in metres, used for distances and curvature.
    public static let earthRadius = 6_371_000.0

    /// Great-circle (haversine) distance in metres.
    public func distance(to other: GeoCoordinate) -> Double {
        Self.earthRadius * centralAngle(to: other)
    }

    /// Angle between the two points as seen from Earth's centre, in radians.
    func centralAngle(to other: GeoCoordinate) -> Double {
        let lat1 = latitude * .pi / 180
        let lat2 = other.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (other.longitude - longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * atan2(sqrt(a), sqrt(max(0, 1 - a)))
    }

    /// The point a `fraction` (0…1) of the way along the great circle to `other`.
    public func intermediate(to other: GeoCoordinate, fraction: Double) -> GeoCoordinate {
        let delta = centralAngle(to: other)
        guard delta > 1e-12 else { return self }
        let lat1 = latitude * .pi / 180
        let lon1 = longitude * .pi / 180
        let lat2 = other.latitude * .pi / 180
        let lon2 = other.longitude * .pi / 180
        let a = sin((1 - fraction) * delta) / sin(delta)
        let b = sin(fraction * delta) / sin(delta)
        let x = a * cos(lat1) * cos(lon1) + b * cos(lat2) * cos(lon2)
        let y = a * cos(lat1) * sin(lon1) + b * cos(lat2) * sin(lon2)
        let z = a * sin(lat1) + b * sin(lat2)
        return GeoCoordinate(
            latitude: atan2(z, sqrt(x * x + y * y)) * 180 / .pi,
            longitude: atan2(y, x) * 180 / .pi
        )
    }

    /// `count` evenly spaced points along the great circle from `start` to `end`, both included.
    /// Fewer than two points yields the endpoints that fit.
    public static func greatCircle(from start: GeoCoordinate, to end: GeoCoordinate, count: Int) -> [GeoCoordinate] {
        guard count >= 2 else { return count == 1 ? [start] : [] }
        return (0..<count).map { index in
            if index == 0 { return start }
            if index == count - 1 { return end }
            return start.intermediate(to: end, fraction: Double(index) / Double(count - 1))
        }
    }
}
