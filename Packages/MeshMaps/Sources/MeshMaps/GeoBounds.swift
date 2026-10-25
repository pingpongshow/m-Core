import Foundation

/// A WGS84 bounding box in degrees. Areas crossing the antimeridian are not supported.
public struct GeoBounds: Hashable, Sendable, Codable {
    public var minLongitude: Double
    public var minLatitude: Double
    public var maxLongitude: Double
    public var maxLatitude: Double

    public init(minLongitude: Double, minLatitude: Double, maxLongitude: Double, maxLatitude: Double) {
        self.minLongitude = minLongitude
        self.minLatitude = minLatitude
        self.maxLongitude = maxLongitude
        self.maxLatitude = maxLatitude
    }

    /// The whole Web Mercator world.
    public static let world = GeoBounds(
        minLongitude: -180, minLatitude: -WebMercator.maxLatitude,
        maxLongitude: 180, maxLatitude: WebMercator.maxLatitude
    )

    /// Bounds with corners ordered and clamped to the Web Mercator world.
    public var normalized: GeoBounds {
        let lon = (Self.clamp(Swift.min(minLongitude, maxLongitude), 180), Self.clamp(Swift.max(minLongitude, maxLongitude), 180))
        let limit = WebMercator.maxLatitude
        let lat = (Self.clamp(Swift.min(minLatitude, maxLatitude), limit), Self.clamp(Swift.max(minLatitude, maxLatitude), limit))
        return GeoBounds(minLongitude: lon.0, minLatitude: lat.0, maxLongitude: lon.1, maxLatitude: lat.1)
    }

    /// Midpoint as (longitude, latitude).
    public var center: (longitude: Double, latitude: Double) {
        ((minLongitude + maxLongitude) / 2, (minLatitude + maxLatitude) / 2)
    }

    private static func clamp(_ value: Double, _ limit: Double) -> Double {
        Swift.max(-limit, Swift.min(limit, value))
    }
}

/// Spherical Web Mercator tile math (slippy-map / XYZ scheme, y = 0 at the north edge).
public enum WebMercator {
    /// Latitude where the Mercator square ends.
    public static let maxLatitude = 85.0511287798066

    /// Tile column containing `longitude` at `zoom`, clamped to the grid.
    public static func tileX(longitude: Double, zoom: Int) -> Int {
        let side = Double(1 << zoom)
        let lon = max(-180, min(180, longitude))
        return clampIndex(Int(((lon + 180) / 360 * side).rounded(.down)), zoom: zoom)
    }

    /// Tile row containing `latitude` at `zoom`; latitude is clamped to ±``maxLatitude``.
    public static func tileY(latitude: Double, zoom: Int) -> Int {
        let side = Double(1 << zoom)
        let radians = max(-maxLatitude, min(maxLatitude, latitude)) * .pi / 180
        let mercator = log(tan(radians) + 1 / cos(radians))
        return clampIndex(Int(((1 - mercator / .pi) / 2 * side).rounded(.down)), zoom: zoom)
    }

    private static func clampIndex(_ value: Int, zoom: Int) -> Int {
        max(0, min((1 << zoom) - 1, value))
    }
}

/// An inclusive rectangle of tiles at one zoom.
public struct TileRange: Hashable, Sendable {
    public let zoom: Int
    public let minX: Int
    public let maxX: Int
    public let minY: Int
    public let maxY: Int

    public init(zoom: Int, minX: Int, maxX: Int, minY: Int, maxY: Int) {
        self.zoom = zoom
        self.minX = minX
        self.maxX = maxX
        self.minY = minY
        self.maxY = maxY
    }

    /// Tiles covering `bounds` at `zoom` (bounds are normalized first; edges touching a tile include it).
    public init(bounds: GeoBounds, zoom: Int) {
        let box = bounds.normalized
        self.init(
            zoom: zoom,
            minX: WebMercator.tileX(longitude: box.minLongitude, zoom: zoom),
            maxX: WebMercator.tileX(longitude: box.maxLongitude, zoom: zoom),
            minY: WebMercator.tileY(latitude: box.maxLatitude, zoom: zoom),
            maxY: WebMercator.tileY(latitude: box.minLatitude, zoom: zoom)
        )
    }

    /// Number of tiles in the range.
    public var count: Int { (maxX - minX + 1) * (maxY - minY + 1) }

    /// Hilbert tile IDs of every tile in the range, in ascending order.
    public func tileIDs() -> [UInt64] {
        var ids: [UInt64] = []
        ids.reserveCapacity(count)
        let base = TileCoordinate.firstTileID(atZoom: zoom)
        for x in minX...maxX {
            for y in minY...maxY {
                ids.append(base + TileCoordinate.hilbertDistance(x: UInt64(x), y: UInt64(y), zoom: zoom))
            }
        }
        ids.sort()
        return ids
    }
}
