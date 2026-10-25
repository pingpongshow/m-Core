/// Errors raised while decoding, planning or writing PMTiles archives.
public enum PMTilesError: Error, Sendable, Equatable {
    /// The first seven bytes are not `PMTiles`.
    case invalidMagic
    /// The archive is not spec version 3.
    case unsupportedVersion(UInt8)
    /// A buffer ended before a structure was complete.
    case truncatedData
    /// A varint ran past 10 bytes or overflowed 64 bits.
    case malformedVarint
    /// A directory was empty or its fields are out of range.
    case malformedDirectory
    /// Directory/metadata compression this package cannot decode.
    case unsupportedCompression(PMTilesCompression)
    /// The gzip stream is invalid (bad header, checksum or length).
    case invalidGzip(String)
    /// Leaf directories nest deeper than ``PMTilesReader/maxDirectoryDepth``.
    case directoryTooDeep
    /// No source tiles intersect the requested area and zoom range.
    case noTilesInArea
    /// The requested zoom range does not overlap the source archive.
    case zoomRangeOutsideSource
}
