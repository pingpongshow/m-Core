import Foundation
import Testing
@testable import MeshTools

struct GreatCircleTests {
    @Test func distances() {
        let origin = GeoCoordinate(latitude: 0, longitude: 0)
        #expect(abs(origin.distance(to: GeoCoordinate(latitude: 0, longitude: 1)) - 111_194.9) < 1)
        // Seattle → Portland ≈ 234 km.
        let seattle = GeoCoordinate(latitude: 47.6062, longitude: -122.3321)
        let portland = GeoCoordinate(latitude: 45.5152, longitude: -122.6784)
        #expect(abs(seattle.distance(to: portland) / 1000 - 233.8) < 1)
    }

    @Test func samplesAreEvenAndIncludeEndpoints() {
        let start = GeoCoordinate(latitude: 0, longitude: 0)
        let end = GeoCoordinate(latitude: 0, longitude: 90)
        let points = GeoCoordinate.greatCircle(from: start, to: end, count: 3)
        #expect(points.count == 3)
        #expect(points.first == start && points.last == end)
        #expect(abs(points[1].latitude) < 1e-9 && abs(points[1].longitude - 45) < 1e-9)

        // Over the pole: the great circle from (60, 0) to (60, 180) passes through 90° N.
        let polar = GeoCoordinate.greatCircle(
            from: GeoCoordinate(latitude: 60, longitude: 0), to: GeoCoordinate(latitude: 60, longitude: 180), count: 3
        )
        #expect(abs(polar[1].latitude - 90) < 1e-6)

        #expect(GeoCoordinate.greatCircle(from: start, to: end, count: 1) == [start])
        #expect(GeoCoordinate.greatCircle(from: start, to: end, count: 0).isEmpty)
        #expect(GeoCoordinate.greatCircle(from: start, to: start, count: 4).allSatisfy { $0 == start })
    }

    @Test func relaySplitsIntoTwoSegments() {
        let a = GeoCoordinate(latitude: 47.0, longitude: -122.0)
        let r = GeoCoordinate(latitude: 47.1, longitude: -122.1)
        let b = GeoCoordinate(latitude: 47.2, longitude: -122.0)
        let paths = LinkPlanner.samplePaths(from: a, via: r, to: b, samplesPerSegment: 5)
        #expect(paths.count == 2)
        #expect(paths[0].first == a && paths[0].last == r)
        #expect(paths[1].first == r && paths[1].last == b)
        #expect(LinkPlanner.samplePaths(from: a, to: b, samplesPerSegment: 5).count == 1)
    }
}

struct LineOfSightTests {
    let parameters = LineOfSightParameters(frequencyMHz: 915)

    @Test func formulas() {
        // 10 km link at 915 MHz: r = 17.32·√(5·5 / (0.915·10)) ≈ 28.63 m at mid-path.
        #expect(abs(LineOfSight.fresnelRadius(d1: 5000, d2: 5000, frequencyMHz: 915) - 28.628) < 0.01)
        #expect(LineOfSight.fresnelRadius(d1: 0, d2: 10_000, frequencyMHz: 915) == 0)
        // Bulge = d1·d2 / (2kR): 5 km × 5 km with k = 4/3 ≈ 1.47 m.
        #expect(abs(LineOfSight.earthBulge(d1: 5000, d2: 5000, kFactor: 1.333) - 1.4719) < 0.001)
    }

    @Test func flatShortLinkIsClear() {
        let segment = LineOfSight.analyze(
            elevations: Array(repeating: 100, count: 101), distance: 10_000, startHeight: 30, endHeight: 30, parameters: parameters
        )
        #expect(segment.profile.count == 101)
        #expect(!segment.isObstructed)
        #expect(segment.isClear)
        #expect(segment.worstPointIndex == 50)
        let mid = segment.profile[50]
        #expect(abs(mid.distance - 5000) < 1e-6)
        #expect(mid.lineOfSight == 130)
        #expect(abs(mid.fresnelRadius - 28.628) < 0.01)
        #expect(abs(mid.fresnelLower - (130 - mid.fresnelRadius)) < 1e-9)
        #expect(abs(mid.adjustedTerrain - (100 + mid.bulge)) < 1e-9)
        #expect(abs((segment.minimumClearancePercent ?? 0) - (130 - mid.adjustedTerrain) / mid.fresnelRadius * 100) < 1e-9)
        // Endpoints have no Fresnel zone.
        #expect(segment.profile[0].fresnelRadius == 0 && segment.profile[100].fresnelRadius == 0)
    }

    @Test func lowAntennasClipTheFresnelZone() {
        let segment = LineOfSight.analyze(
            elevations: Array(repeating: 0, count: 51), distance: 10_000, startHeight: 10, endHeight: 10, parameters: parameters
        )
        #expect(!segment.isObstructed)
        #expect(!segment.isClear)
        #expect(abs((segment.minimumClearancePercent ?? 0) - 29.8) < 0.5)
    }

    @Test func hillInTheMiddleBlocks() {
        var terrain = Array(repeating: 0.0, count: 101)
        for index in 45...55 {
            terrain[index] = 100
        }
        let segment = LineOfSight.analyze(elevations: terrain, distance: 10_000, startHeight: 20, endHeight: 20, parameters: parameters)
        #expect(segment.isObstructed)
        #expect(!segment.isClear)
        #expect((segment.minimumClearancePercent ?? 0) < 0)
        // The hill's edges are tightest relative to the (narrower) Fresnel zone there.
        #expect((45...55).contains(segment.worstPointIndex ?? -1))
        #expect(segment.profile[50].clearance < 0)
    }

    @Test func curvatureMattersOverLongDistances() {
        let flat = Array(repeating: 0.0, count: 201)
        // 60 km over flat ground: mid-path bulge ≈ 53 m at k = 4/3, ≈ 70.6 m at k = 1.
        let low = LineOfSight.analyze(elevations: flat, distance: 60_000, startHeight: 30, endHeight: 30, parameters: parameters)
        #expect(low.isObstructed)
        #expect(abs(low.profile[100].bulge - 52.99) < 0.05)

        let tall = LineOfSight.analyze(elevations: flat, distance: 60_000, startHeight: 100, endHeight: 100, parameters: parameters)
        #expect(!tall.isObstructed)
        #expect(tall.isClear)

        var noRefraction = parameters
        noRefraction.kFactor = 1.0
        let strict = LineOfSight.analyze(elevations: flat, distance: 60_000, startHeight: 100, endHeight: 100, parameters: noRefraction)
        #expect(abs(strict.profile[100].bulge - 70.64) < 0.05)
        #expect(!strict.isObstructed)
        #expect(!strict.isClear)
    }

    @Test func degenerateInput() {
        let empty = LineOfSight.analyze(elevations: [5], distance: 100, startHeight: 1, endHeight: 1, parameters: parameters)
        #expect(empty.profile.isEmpty)
        let ends = LineOfSight.analyze(elevations: [0, 0], distance: 100, startHeight: 1, endHeight: 1, parameters: parameters)
        #expect(ends.minimumClearancePercent == nil)
        #expect(ends.isClear)
    }
}

/// Synthetic terrain: a 200 m ridge along longitude −122.05, flat elsewhere.
struct RidgeTerrain: ElevationProvider {
    func elevations(for coordinates: [GeoCoordinate]) async throws -> [Double] {
        coordinates.map { abs($0.longitude + 122.05) < 0.003 ? 200 : 10 }
    }
}

struct LinkPlannerTests {
    @Test func relayHopsOverRidge() async throws {
        let planner = LinkPlanner(elevation: RidgeTerrain())
        let west = LinkSite(coordinate: GeoCoordinate(latitude: 47.0, longitude: -122.10), antennaHeight: 10)
        let east = LinkSite(coordinate: GeoCoordinate(latitude: 47.0, longitude: -122.00), antennaHeight: 10)
        let parameters = LineOfSightParameters(frequencyMHz: 915)

        let direct = try await planner.analyze(from: west, to: east, parameters: parameters, samplesPerSegment: 201)
        #expect(direct.segments.count == 1)
        #expect(!direct.isClear)
        #expect(direct.segments[0].isObstructed)
        #expect(abs(direct.totalDistance - west.coordinate.distance(to: east.coordinate)) < 1e-6)

        let relay = LinkSite(coordinate: GeoCoordinate(latitude: 47.0, longitude: -122.05), antennaHeight: 30)
        let viaRelay = try await planner.analyze(from: west, via: relay, to: east, parameters: parameters, samplesPerSegment: 201)
        #expect(viaRelay.segments.count == 2)
        #expect(viaRelay.segments.allSatisfy { !$0.isObstructed })
        #expect(viaRelay.segments[0].profile.last?.coordinate == relay.coordinate)
    }
}

struct OpenMeteoTests {
    actor URLLog {
        var urls: [URL] = []
        func add(_ url: URL) { urls.append(url) }
    }

    @Test func batchesAtOneHundredPoints() async throws {
        let log = URLLog()
        let provider = OpenMeteoElevationProvider(fetch: { url in
            await log.add(url)
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let lats = query.first { $0.name == "latitude" }?.value?.split(separator: ",") ?? []
            let values = lats.map { String(Double($0) ?? 0) }.joined(separator: ",")
            return Data(#"{"elevation":[\#(values)]}"#.utf8)
        })
        let points = (0..<250).map { GeoCoordinate(latitude: Double($0) / 10, longitude: -122.5) }
        let elevations = try await provider.elevations(for: points)
        #expect(elevations.count == 250)
        #expect(elevations[123] == 12.3)
        let urls = await log.urls
        #expect(urls.count == 3)
        #expect(urls[0].absoluteString.hasPrefix("https://api.open-meteo.com/v1/elevation?latitude=0.000000,0.100000,"))
        #expect(urls[2].absoluteString.contains("longitude=-122.500000,"))
    }

    @Test func requestURLFormat() {
        let provider = OpenMeteoElevationProvider(fetch: { _ in Data() })
        let url = provider.requestURL(for: [
            GeoCoordinate(latitude: 52.52, longitude: 13.41), GeoCoordinate(latitude: 48.85, longitude: 2.35),
        ])
        #expect(url?.absoluteString
            == "https://api.open-meteo.com/v1/elevation?latitude=52.520000,48.850000&longitude=13.410000,2.350000")
    }

    @Test func errorsAndNulls() async throws {
        let mismatched = OpenMeteoElevationProvider(fetch: { _ in Data(#"{"elevation":[1]}"#.utf8) })
        await #expect(throws: ElevationError.countMismatch(expected: 2, received: 1)) {
            try await mismatched.elevations(for: [GeoCoordinate(latitude: 0, longitude: 0), GeoCoordinate(latitude: 1, longitude: 1)])
        }
        let failing = OpenMeteoElevationProvider(fetch: { _ in Data(#"{"error":true,"reason":"Latitude out of range"}"#.utf8) })
        await #expect(throws: ElevationError.badResponse("Latitude out of range")) {
            try await failing.elevations(for: [GeoCoordinate(latitude: 0, longitude: 0)])
        }
        let sea = OpenMeteoElevationProvider(fetch: { _ in Data(#"{"elevation":[null,4.5]}"#.utf8) })
        let pair = [GeoCoordinate(latitude: 0, longitude: 0), GeoCoordinate(latitude: 1, longitude: 1)]
        #expect(try await sea.elevations(for: pair) == [0, 4.5])
        #expect(try await sea.elevations(for: []).isEmpty)
    }
}
