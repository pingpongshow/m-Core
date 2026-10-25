import Foundation

/// One end of a link (or a relay): where it is and how high its antenna sits above ground.
public struct LinkSite: Equatable, Hashable, Sendable {
    public var coordinate: GeoCoordinate
    /// Metres above ground level.
    public var antennaHeight: Double

    public init(coordinate: GeoCoordinate, antennaHeight: Double) {
        self.coordinate = coordinate
        self.antennaHeight = antennaHeight
    }
}

/// A full A→B (or A→R→B) analysis.
public struct LinkAnalysis: Equatable, Hashable, Sendable {
    /// One segment for a direct link, two (A→R, R→B) through a relay.
    public var segments: [LineOfSightSegment]

    public var isClear: Bool { !segments.isEmpty && segments.allSatisfy(\.isClear) }
    public var totalDistance: Double { segments.reduce(0) { $0 + $1.distance } }
}

/// Fetches terrain along a path and runs `LineOfSight.analyze` on each leg.
public struct LinkPlanner: Sendable {
    public let elevation: any ElevationProvider

    public init(elevation: any ElevationProvider) {
        self.elevation = elevation
    }

    /// Sample coordinates for each leg: `[A→B]`, or `[A→R, R→B]` through a relay.
    public static func samplePaths(
        from start: GeoCoordinate,
        via relay: GeoCoordinate? = nil,
        to end: GeoCoordinate,
        samplesPerSegment: Int
    ) -> [[GeoCoordinate]] {
        let stops = [start] + (relay.map { [$0] } ?? []) + [end]
        return zip(stops, stops.dropFirst()).map { GeoCoordinate.greatCircle(from: $0, to: $1, count: samplesPerSegment) }
    }

    /// Analyses the link, fetching elevations for every leg in one provider call.
    public func analyze(
        from start: LinkSite,
        via relay: LinkSite? = nil,
        to end: LinkSite,
        parameters: LineOfSightParameters,
        samplesPerSegment: Int = 128
    ) async throws -> LinkAnalysis {
        let sites = [start] + (relay.map { [$0] } ?? []) + [end]
        let paths = Self.samplePaths(
            from: start.coordinate, via: relay?.coordinate, to: end.coordinate,
            samplesPerSegment: max(2, samplesPerSegment)
        )
        let points = paths.flatMap { $0 }
        let heights = try await elevation.elevations(for: points)
        guard heights.count == points.count else {
            throw ElevationError.countMismatch(expected: points.count, received: heights.count)
        }
        var offset = 0
        var segments: [LineOfSightSegment] = []
        for (index, path) in paths.enumerated() {
            let slice = Array(heights[offset..<offset + path.count])
            offset += path.count
            segments.append(LineOfSight.analyze(
                elevations: slice,
                distance: sites[index].coordinate.distance(to: sites[index + 1].coordinate),
                startHeight: sites[index].antennaHeight,
                endHeight: sites[index + 1].antennaHeight,
                parameters: parameters,
                coordinates: path
            ))
        }
        return LinkAnalysis(segments: segments)
    }
}
