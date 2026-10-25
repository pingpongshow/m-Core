import Foundation

/// Radio and propagation settings for a line-of-sight check.
public struct LineOfSightParameters: Equatable, Hashable, Sendable {
    public var frequencyMHz: Double
    /// Effective Earth radius factor: 4/3 (≈1.333) for standard refraction, 1.0 for none.
    public var kFactor: Double
    /// Fraction of the first Fresnel zone that must be clear (0.6 is the usual rule).
    public var requiredClearance: Double

    public init(frequencyMHz: Double, kFactor: Double = 1.333, requiredClearance: Double = 0.6) {
        self.frequencyMHz = frequencyMHz
        self.kFactor = kFactor
        self.requiredClearance = requiredClearance
    }
}

/// One sample along a path, ready for charting. Heights are metres above sea level.
public struct LineOfSightProfilePoint: Equatable, Hashable, Sendable {
    /// Metres from the segment start.
    public var distance: Double
    public var coordinate: GeoCoordinate?
    public var terrain: Double
    /// Earth-curvature bulge at this point.
    public var bulge: Double
    /// Terrain raised by the bulge: what the straight radio line actually has to clear.
    public var adjustedTerrain: Double
    /// Height of the straight line between the two antennas.
    public var lineOfSight: Double
    public var fresnelRadius: Double
    /// `lineOfSight − fresnelRadius`.
    public var fresnelLower: Double

    /// `lineOfSight − adjustedTerrain`; negative when terrain blocks the line.
    public var clearance: Double { lineOfSight - adjustedTerrain }
}

/// Result for one A→B segment.
public struct LineOfSightSegment: Equatable, Hashable, Sendable {
    /// Great-circle length in metres.
    public var distance: Double
    public var profile: [LineOfSightProfilePoint]
    public var parameters: LineOfSightParameters
    /// Smallest clearance between the line and adjusted terrain, as a percentage of the first
    /// Fresnel radius at that point (negative when blocked). Nil when there are no interior points.
    public var minimumClearancePercent: Double?
    /// Index into `profile` of the tightest point.
    public var worstPointIndex: Int?
    /// True when some interior point's adjusted terrain rises above the line of sight.
    public var isObstructed: Bool

    public var distanceKm: Double { distance / 1000 }

    /// Clear when nothing pokes through the line and at least `requiredClearance` of the Fresnel zone is free.
    public var isClear: Bool {
        !isObstructed && (minimumClearancePercent ?? 100) >= parameters.requiredClearance * 100
    }

    /// Largest first Fresnel radius on the path (at its middle).
    public var maxFresnelRadius: Double { profile.map(\.fresnelRadius).max() ?? 0 }
}

/// Pure line-of-sight and Fresnel-zone geometry.
public enum LineOfSight {
    /// Earth-curvature bulge in metres at distances `d1`, `d2` (metres) from the two ends.
    public static func earthBulge(d1: Double, d2: Double, kFactor: Double) -> Double {
        d1 * d2 / (2 * kFactor * GeoCoordinate.earthRadius)
    }

    /// First Fresnel zone radius in metres: 17.32·√(d1·d2 / (f_GHz·D)) with distances in km.
    public static func fresnelRadius(d1: Double, d2: Double, frequencyMHz: Double) -> Double {
        let total = (d1 + d2) / 1000
        guard total > 0, frequencyMHz > 0, d1 > 0, d2 > 0 else { return 0 }
        return 17.32 * sqrt((d1 / 1000) * (d2 / 1000) / (frequencyMHz / 1000 * total))
    }

    /// Analyses evenly spaced terrain samples between two antennas.
    ///
    /// - Parameters:
    ///   - elevations: ground elevation at each sample, first and last at the antenna sites.
    ///   - distance: segment length in metres.
    ///   - startHeight: antenna height above ground at the first sample.
    ///   - endHeight: antenna height above ground at the last sample.
    ///   - coordinates: optional sample coordinates carried into the profile.
    public static func analyze(
        elevations: [Double],
        distance: Double,
        startHeight: Double,
        endHeight: Double,
        parameters: LineOfSightParameters,
        coordinates: [GeoCoordinate]? = nil
    ) -> LineOfSightSegment {
        let count = elevations.count
        guard count >= 2 else {
            return LineOfSightSegment(
                distance: distance, profile: [], parameters: parameters,
                minimumClearancePercent: nil, worstPointIndex: nil, isObstructed: false
            )
        }
        let startAntenna = elevations[0] + startHeight
        let endAntenna = elevations[count - 1] + endHeight
        var profile: [LineOfSightProfilePoint] = []
        profile.reserveCapacity(count)
        var minimumPercent: Double?
        var worstIndex: Int?
        var obstructed = false

        for (index, terrain) in elevations.enumerated() {
            let fraction = Double(index) / Double(count - 1)
            let d1 = distance * fraction
            let d2 = distance - d1
            let bulge = earthBulge(d1: d1, d2: d2, kFactor: parameters.kFactor)
            let line = startAntenna + (endAntenna - startAntenna) * fraction
            let radius = fresnelRadius(d1: d1, d2: d2, frequencyMHz: parameters.frequencyMHz)
            let point = LineOfSightProfilePoint(
                distance: d1,
                coordinate: coordinates.flatMap { index < $0.count ? $0[index] : nil },
                terrain: terrain,
                bulge: bulge,
                adjustedTerrain: terrain + bulge,
                lineOfSight: line,
                fresnelRadius: radius,
                fresnelLower: line - radius
            )
            profile.append(point)

            guard index > 0, index < count - 1, radius > 0 else { continue }
            if point.clearance < 0 { obstructed = true }
            let percent = point.clearance / radius * 100
            if minimumPercent.map({ percent < $0 }) ?? true {
                minimumPercent = percent
                worstIndex = index
            }
        }
        return LineOfSightSegment(
            distance: distance, profile: profile, parameters: parameters,
            minimumClearancePercent: minimumPercent, worstPointIndex: worstIndex, isObstructed: obstructed
        )
    }
}
