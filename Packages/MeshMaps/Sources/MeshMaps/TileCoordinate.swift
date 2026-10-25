/// A slippy-map tile address with its PMTiles Hilbert tile ID.
public struct TileCoordinate: Hashable, Sendable, CustomStringConvertible {
    /// Highest zoom whose tile IDs fit in 64 bits.
    public static let maxZoom = 31

    public let z: Int
    public let x: Int
    public let y: Int

    public init(z: Int, x: Int, y: Int) {
        precondition((0...Self.maxZoom).contains(z), "zoom out of range")
        precondition(x >= 0 && y >= 0 && x < 1 << z && y < 1 << z, "tile outside zoom grid")
        self.z = z
        self.x = x
        self.y = y
    }

    /// Decodes a Hilbert tile ID; `nil` when it lies beyond ``maxZoom``.
    public init?(tileID: UInt64) {
        var base: UInt64 = 0
        for zoom in 0...Self.maxZoom {
            let count = UInt64(1) << UInt64(2 * zoom)
            if tileID - base < count {
                let (x, y) = Self.hilbertPoint(distance: tileID - base, zoom: zoom)
                self.init(z: zoom, x: Int(x), y: Int(y))
                return
            }
            base += count
        }
        return nil
    }

    /// First tile ID at `zoom`: the number of tiles in all lower zooms, (4^z − 1) / 3.
    public static func firstTileID(atZoom zoom: Int) -> UInt64 {
        precondition((0...Self.maxZoom).contains(zoom), "zoom out of range")
        return ((UInt64(1) << UInt64(2 * zoom)) - 1) / 3
    }

    /// Cumulative Hilbert tile ID (spec §4.1).
    public var tileID: UInt64 {
        Self.firstTileID(atZoom: z) + Self.hilbertDistance(x: UInt64(x), y: UInt64(y), zoom: z)
    }

    public var description: String { "\(z)/\(x)/\(y)" }

    static func hilbertDistance(x: UInt64, y: UInt64, zoom: Int) -> UInt64 {
        let side = UInt64(1) << UInt64(zoom)
        var x = x
        var y = y
        var distance: UInt64 = 0
        var step = side >> 1
        while step > 0 {
            let rx: UInt64 = x & step != 0 ? 1 : 0
            let ry: UInt64 = y & step != 0 ? 1 : 0
            distance += step * step * ((3 * rx) ^ ry)
            rotate(side: side, x: &x, y: &y, rx: rx, ry: ry)
            step >>= 1
        }
        return distance
    }

    static func hilbertPoint(distance: UInt64, zoom: Int) -> (x: UInt64, y: UInt64) {
        let side = UInt64(1) << UInt64(zoom)
        var remaining = distance
        var x: UInt64 = 0
        var y: UInt64 = 0
        var step: UInt64 = 1
        while step < side {
            let rx = 1 & (remaining / 2)
            let ry = 1 & (remaining ^ rx)
            rotate(side: step, x: &x, y: &y, rx: rx, ry: ry)
            x += step * rx
            y += step * ry
            remaining /= 4
            step <<= 1
        }
        return (x, y)
    }

    private static func rotate(side: UInt64, x: inout UInt64, y: inout UInt64, rx: UInt64, ry: UInt64) {
        guard ry == 0 else { return }
        if rx == 1 {
            x = side - 1 - x
            y = side - 1 - y
        }
        swap(&x, &y)
    }
}
