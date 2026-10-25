import Foundation
import Testing
@testable import MeshMaps

struct PMTilesHeaderTests {
    @Test func roundTripsEveryField() throws {
        var header = PMTilesHeader()
        header.rootDirectoryOffset = 127
        header.rootDirectoryLength = 1_000
        header.metadataOffset = 1_127
        header.metadataLength = 250
        header.leafDirectoryOffset = 1_377
        header.leafDirectoryLength = 0x1_0000_0000
        header.tileDataOffset = 0x1_0000_0561
        header.tileDataLength = 120_000_000_000
        header.addressedTileCount = 1 << 40
        header.tileEntryCount = 12_345
        header.tileContentCount = 6_789
        header.isClustered = true
        header.internalCompression = .gzip
        header.tileCompression = .zstd
        header.tileType = .mlt
        header.minZoom = 2
        header.maxZoom = 15
        header.minLongitudeE7 = -1_800_000_000
        header.minLatitudeE7 = -850_511_287
        header.maxLongitudeE7 = 1_800_000_000
        header.maxLatitudeE7 = 850_511_287
        header.centerZoom = 7
        header.centerLongitudeE7 = -1_223_000_000
        header.centerLatitudeE7 = 376_000_000

        let bytes = header.serialized()
        #expect(bytes.count == 127)
        #expect(Array(bytes.prefix(8)) == Array("PMTiles".utf8) + [3])
        #expect(try PMTilesHeader(data: bytes) == header)
        // Spot-check little-endian placement against the spec layout.
        #expect(bytes[8] == 127 && bytes[9] == 0)
        #expect(bytes[96] == 1 && bytes[97] == 2 && bytes[98] == 4 && bytes[99] == 6)
        #expect(bytes[100] == 2 && bytes[101] == 15 && bytes[118] == 7)
    }

    @Test func rejectsBadMagicVersionAndTruncation() {
        var bytes = PMTilesHeader().serialized()
        #expect(throws: PMTilesError.truncatedData) { try PMTilesHeader(data: bytes.prefix(100)) }
        bytes[7] = 2
        #expect(throws: PMTilesError.unsupportedVersion(2)) { try PMTilesHeader(data: bytes) }
        bytes[0] = 0x51
        #expect(throws: PMTilesError.invalidMagic) { try PMTilesHeader(data: bytes) }
    }

    @Test func positionsUseE7() {
        var header = PMTilesHeader()
        header.bounds = GeoBounds(minLongitude: -122.5, minLatitude: 37.25, maxLongitude: -121.75, maxLatitude: 38)
        #expect(header.minLongitudeE7 == -1_225_000_000)
        #expect(header.maxLatitudeE7 == 380_000_000)
        #expect(header.bounds.minLatitude == 37.25)
    }
}

struct VarintTests {
    @Test(arguments: [UInt64(0), 1, 127, 128, 300, 16_383, 16_384, UInt64(UInt32.max), UInt64.max - 1, UInt64.max])
    func roundTrips(value: UInt64) throws {
        let bytes = Varint.encode(value)
        var index = 0
        #expect(try Varint.read(from: bytes, at: &index) == value)
        #expect(index == bytes.count)
    }

    @Test func knownEncodings() {
        #expect(Varint.encode(0) == [0])
        #expect(Varint.encode(300) == [0xAC, 0x02])
        #expect(Varint.encode(UInt64.max).count == 10)
    }

    @Test func rejectsMalformed() {
        var index = 0
        #expect(throws: PMTilesError.truncatedData) { try Varint.read(from: [0x80, 0x80], at: &index) }
        index = 0
        let overlong = [UInt8](repeating: 0xFF, count: 10) + [0x01]
        #expect(throws: PMTilesError.malformedVarint) { try Varint.read(from: overlong, at: &index) }
    }
}

struct PMTilesDirectoryTests {
    let entries = [
        PMTilesEntry(tileID: 0, offset: 0, length: 100, runLength: 1),
        PMTilesEntry(tileID: 1, offset: 100, length: 50, runLength: 3),    // contiguous → offset encoded as 0
        PMTilesEntry(tileID: 5, offset: 0, length: 100, runLength: 1),     // dedup back-reference
        PMTilesEntry(tileID: 6, offset: 150, length: 70_000, runLength: 1),
        PMTilesEntry(tileID: 1_000_000, offset: 5_000, length: 300, runLength: 0),  // leaf pointer
    ]

    @Test func roundTrips() throws {
        let encoded = PMTilesDirectory.encode(entries)
        #expect(try PMTilesDirectory.decode(encoded) == entries)
    }

    @Test func usesColumnLayout() {
        let bytes = [UInt8](PMTilesDirectory.encode([
            PMTilesEntry(tileID: 5, offset: 1337, length: 42, runLength: 1),
            PMTilesEntry(tileID: 42, offset: 1379, length: 8, runLength: 2),
        ]))
        // count, Δids (5, 37), runs (1, 2), lengths (42, 8), offsets (1338 as varint, 0 = contiguous)
        #expect(bytes == [2, 5, 37, 1, 2, 42, 8, 0xBA, 0x0A, 0])
    }

    @Test func rejectsEmptyAndGarbage() {
        #expect(throws: PMTilesError.malformedDirectory) { try PMTilesDirectory.decode(Data([0])) }
        #expect(throws: (any Error).self) { try PMTilesDirectory.decode(Data([200, 1, 2])) }
    }

    @Test func findsRunsAndLeaves() {
        #expect(PMTilesDirectory.find(0, in: entries)?.tileID == 0)
        #expect(PMTilesDirectory.find(3, in: entries)?.tileID == 1)
        #expect(PMTilesDirectory.find(4, in: entries) == nil)
        #expect(PMTilesDirectory.find(7, in: entries) == nil)
        #expect(PMTilesDirectory.find(2_000_000, in: entries)?.isLeaf == true)
        #expect(PMTilesDirectory.find(0, in: Array(entries.dropFirst())) == nil)
    }
}

struct TileCoordinateTests {
    @Test func matchesSpecTable() throws {
        #expect(TileCoordinate(z: 0, x: 0, y: 0).tileID == 0)
        #expect(TileCoordinate(z: 1, x: 0, y: 0).tileID == 1)
        #expect(TileCoordinate(z: 1, x: 0, y: 1).tileID == 2)
        #expect(TileCoordinate(z: 1, x: 1, y: 1).tileID == 3)
        #expect(TileCoordinate(z: 1, x: 1, y: 0).tileID == 4)
        #expect(TileCoordinate(z: 2, x: 0, y: 0).tileID == 5)
        #expect(TileCoordinate(z: 12, x: 3423, y: 1763).tileID == 19_078_479)
        #expect(try #require(TileCoordinate(tileID: 19_078_479)) == TileCoordinate(z: 12, x: 3423, y: 1763))
    }

    @Test func zoomBlocksAreContiguous() {
        #expect(TileCoordinate.firstTileID(atZoom: 2) == 5)
        #expect(TileCoordinate.firstTileID(atZoom: 3) == 21)
        #expect(TileCoordinate.firstTileID(atZoom: 15) == 357_913_941)
        #expect(TileCoordinate(z: 2, x: 0, y: 3).tileID == 20 || TileCoordinate(z: 2, x: 3, y: 0).tileID == 20)
    }

    @Test func roundTripsEveryTileThroughZoom7() throws {
        for zoom in 0...7 {
            var seen = Set<UInt64>()
            for x in 0..<(1 << zoom) {
                for y in 0..<(1 << zoom) {
                    let coordinate = TileCoordinate(z: zoom, x: x, y: y)
                    let id = coordinate.tileID
                    seen.insert(id)
                    #expect(TileCoordinate(tileID: id) == coordinate)
                }
            }
            let first = TileCoordinate.firstTileID(atZoom: zoom)
            #expect(seen == Set(first..<first + UInt64(1 << (2 * zoom))))
        }
    }

    @Test func roundTripsHighZooms() throws {
        for coordinate in [TileCoordinate(z: 20, x: 123_456, y: 654_321), TileCoordinate(z: 31, x: (1 << 31) - 1, y: 12_345)] {
            #expect(TileCoordinate(tileID: coordinate.tileID) == coordinate)
        }
        #expect(TileCoordinate(tileID: UInt64.max) == nil)
    }
}

struct TileRangeTests {
    @Test func worldCoversWholeGrid() {
        #expect(TileRange(bounds: .world, zoom: 0) == TileRange(zoom: 0, minX: 0, maxX: 0, minY: 0, maxY: 0))
        let z3 = TileRange(bounds: .world, zoom: 3)
        #expect(z3.count == 64)
        #expect(z3.tileIDs() == Array(21..<85))
    }

    @Test func knownLocation() {
        // London at z10 is tile 511/340.
        #expect(WebMercator.tileX(longitude: -0.1278, zoom: 10) == 511)
        #expect(WebMercator.tileY(latitude: 51.5074, zoom: 10) == 340)
    }

    @Test func clampsLatitudeAndLongitude() {
        #expect(WebMercator.tileY(latitude: 90, zoom: 4) == 0)
        #expect(WebMercator.tileY(latitude: -90, zoom: 4) == 15)
        #expect(WebMercator.tileX(longitude: 180, zoom: 4) == 15)
        #expect(WebMercator.tileX(longitude: -200, zoom: 4) == 0)
    }

    @Test func boundingBoxRange() {
        // San Francisco Bay Area.
        let bounds = GeoBounds(minLongitude: -122.6, minLatitude: 37.2, maxLongitude: -121.7, maxLatitude: 38.0)
        let range = TileRange(bounds: bounds, zoom: 10)
        #expect(range.minX == 163 && range.maxX == 165)
        #expect(range.minY == 394 && range.maxY == 397)
        #expect(range.count == 12)
        #expect(range.tileIDs().count == 12)
        // Swapped corners are normalized.
        let swapped = GeoBounds(minLongitude: -121.7, minLatitude: 38.0, maxLongitude: -122.6, maxLatitude: 37.2)
        #expect(TileRange(bounds: swapped, zoom: 10) == range)
    }
}
