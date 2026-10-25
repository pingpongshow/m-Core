import Foundation

/// PMTiles compression enum (spec §3.3). Raw values are preserved so unknown codes round-trip.
public struct PMTilesCompression: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let unknown = Self(rawValue: 0)
    public static let none = Self(rawValue: 1)
    public static let gzip = Self(rawValue: 2)
    public static let brotli = Self(rawValue: 3)
    public static let zstd = Self(rawValue: 4)

    public var description: String {
        switch rawValue {
        case 0: "unknown"
        case 1: "none"
        case 2: "gzip"
        case 3: "brotli"
        case 4: "zstd"
        default: "compression(\(rawValue))"
        }
    }
}

/// PMTiles tile type enum (spec §3.2). Raw values are preserved so unknown codes round-trip.
public struct PMTilesTileType: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let unknown = Self(rawValue: 0)
    public static let mvt = Self(rawValue: 1)
    public static let png = Self(rawValue: 2)
    public static let jpeg = Self(rawValue: 3)
    public static let webp = Self(rawValue: 4)
    public static let avif = Self(rawValue: 5)
    public static let mlt = Self(rawValue: 6)
}

/// The fixed 127-byte PMTiles v3 header. Positions are stored as E7 integers exactly as on disk.
public struct PMTilesHeader: Hashable, Sendable {
    /// Header size in bytes.
    public static let length = 127
    /// Header plus root directory must fit in this many leading bytes.
    public static let rootSectionLimit = 16_384
    static let magic: [UInt8] = Array("PMTiles".utf8)

    public var rootDirectoryOffset: UInt64 = 0
    public var rootDirectoryLength: UInt64 = 0
    public var metadataOffset: UInt64 = 0
    public var metadataLength: UInt64 = 0
    public var leafDirectoryOffset: UInt64 = 0
    public var leafDirectoryLength: UInt64 = 0
    public var tileDataOffset: UInt64 = 0
    public var tileDataLength: UInt64 = 0
    /// Tiles addressed before run-length encoding (0 = unknown).
    public var addressedTileCount: UInt64 = 0
    /// Directory entries with a run length > 0 (0 = unknown).
    public var tileEntryCount: UInt64 = 0
    /// Distinct blobs in the tile data section (0 = unknown).
    public var tileContentCount: UInt64 = 0
    public var isClustered = false
    public var internalCompression: PMTilesCompression = .none
    public var tileCompression: PMTilesCompression = .unknown
    public var tileType: PMTilesTileType = .unknown
    public var minZoom: UInt8 = 0
    public var maxZoom: UInt8 = 0
    public var minLongitudeE7: Int32 = 0
    public var minLatitudeE7: Int32 = 0
    public var maxLongitudeE7: Int32 = 0
    public var maxLatitudeE7: Int32 = 0
    public var centerZoom: UInt8 = 0
    public var centerLongitudeE7: Int32 = 0
    public var centerLatitudeE7: Int32 = 0

    public init() {}

    /// Parses the first 127 bytes of `data`.
    public init(data: Data) throws {
        guard data.count >= Self.length else { throw PMTilesError.truncatedData }
        var reader = ByteReader(Array(data.prefix(Self.length)))
        guard Array(reader.bytes[0..<7]) == Self.magic else { throw PMTilesError.invalidMagic }
        reader.position = 7
        let version = try reader.readUInt8()
        guard version == 3 else { throw PMTilesError.unsupportedVersion(version) }
        rootDirectoryOffset = try reader.readUInt64()
        rootDirectoryLength = try reader.readUInt64()
        metadataOffset = try reader.readUInt64()
        metadataLength = try reader.readUInt64()
        leafDirectoryOffset = try reader.readUInt64()
        leafDirectoryLength = try reader.readUInt64()
        tileDataOffset = try reader.readUInt64()
        tileDataLength = try reader.readUInt64()
        addressedTileCount = try reader.readUInt64()
        tileEntryCount = try reader.readUInt64()
        tileContentCount = try reader.readUInt64()
        isClustered = try reader.readUInt8() == 1
        internalCompression = PMTilesCompression(rawValue: try reader.readUInt8())
        tileCompression = PMTilesCompression(rawValue: try reader.readUInt8())
        tileType = PMTilesTileType(rawValue: try reader.readUInt8())
        minZoom = try reader.readUInt8()
        maxZoom = try reader.readUInt8()
        minLongitudeE7 = try reader.readInt32()
        minLatitudeE7 = try reader.readInt32()
        maxLongitudeE7 = try reader.readInt32()
        maxLatitudeE7 = try reader.readInt32()
        centerZoom = try reader.readUInt8()
        centerLongitudeE7 = try reader.readInt32()
        centerLatitudeE7 = try reader.readInt32()
    }

    /// Serializes the header to exactly 127 bytes.
    public func serialized() -> Data {
        var writer = ByteWriter(capacity: Self.length)
        writer.append(contentsOf: Self.magic)
        writer.append(3)
        for value in [
            rootDirectoryOffset, rootDirectoryLength, metadataOffset, metadataLength,
            leafDirectoryOffset, leafDirectoryLength, tileDataOffset, tileDataLength,
            addressedTileCount, tileEntryCount, tileContentCount,
        ] {
            writer.appendUInt64(value)
        }
        writer.append(isClustered ? 1 : 0)
        writer.append(internalCompression.rawValue)
        writer.append(tileCompression.rawValue)
        writer.append(tileType.rawValue)
        writer.append(minZoom)
        writer.append(maxZoom)
        writer.appendInt32(minLongitudeE7)
        writer.appendInt32(minLatitudeE7)
        writer.appendInt32(maxLongitudeE7)
        writer.appendInt32(maxLatitudeE7)
        writer.append(centerZoom)
        writer.appendInt32(centerLongitudeE7)
        writer.appendInt32(centerLatitudeE7)
        return Data(writer.bytes)
    }

    /// Header bounds decoded to degrees.
    public var bounds: GeoBounds {
        get {
            GeoBounds(
                minLongitude: Self.degrees(minLongitudeE7), minLatitude: Self.degrees(minLatitudeE7),
                maxLongitude: Self.degrees(maxLongitudeE7), maxLatitude: Self.degrees(maxLatitudeE7)
            )
        }
        set {
            minLongitudeE7 = Self.e7(newValue.minLongitude)
            minLatitudeE7 = Self.e7(newValue.minLatitude)
            maxLongitudeE7 = Self.e7(newValue.maxLongitude)
            maxLatitudeE7 = Self.e7(newValue.maxLatitude)
        }
    }

    /// Encodes degrees as a spec E7 integer, clamped to the Int32 range.
    public static func e7(_ degrees: Double) -> Int32 {
        let scaled = (degrees * 10_000_000).rounded()
        return Int32(max(Double(Int32.min), min(Double(Int32.max), scaled)))
    }

    /// Decodes a spec E7 integer to degrees.
    public static func degrees(_ e7: Int32) -> Double {
        Double(e7) / 10_000_000
    }
}
