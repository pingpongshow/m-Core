import Foundation

/// Everything that precedes the tile data in an output archive.
struct PMTilesArchiveLayout: Sendable {
    /// Final header with all offsets filled in.
    var header: PMTilesHeader
    /// Header, root directory, metadata and leaf directories; tile data starts at `prefix.count`.
    var prefix: Data
}

/// Lays out header, root directory, metadata and leaf directories (in that order) for a set of entries.
///
/// If all entries fit in the root (header + root ≤ 16 KiB) no leaves are written. Otherwise entries are split
/// into leaves of `leafEntryCount` entries, growing by 20% until the root of leaf pointers fits.
enum PMTilesArchiveBuilder {
    static let defaultLeafEntryCount = 4096

    /// - Parameters:
    ///   - entries: Tile entries sorted by tile ID, offsets relative to the tile data section.
    ///   - template: Header carrying tile counts, data length, zoom, bounds, center and types. Offsets are overwritten.
    ///   - compress: Encoder matching `template.internalCompression`, applied to root, metadata and each leaf.
    ///   - forcedLeafEntryCount: Splits into leaves of this size even when the root would fit (tests).
    static func layout(
        entries: [PMTilesEntry],
        metadata: Data,
        template: PMTilesHeader,
        compress: (Data) throws -> Data = { $0 },
        forcedLeafEntryCount: Int? = nil
    ) throws -> PMTilesArchiveLayout {
        guard !entries.isEmpty else { throw PMTilesError.noTilesInArea }
        let rootLimit = PMTilesHeader.rootSectionLimit - PMTilesHeader.length
        var root = Data()
        var leaves = Data()
        if forcedLeafEntryCount == nil {
            root = try compress(PMTilesDirectory.encode(entries))
        }
        if forcedLeafEntryCount != nil || root.count > rootLimit {
            var leafSize = max(1, forcedLeafEntryCount ?? defaultLeafEntryCount)
            while true {
                (root, leaves) = try split(entries, leafSize: leafSize, compress: compress)
                if root.count <= rootLimit { break }
                leafSize += max(1, leafSize / 5)
            }
        }
        let compressedMetadata = try compress(metadata)
        var header = template
        header.rootDirectoryOffset = UInt64(PMTilesHeader.length)
        header.rootDirectoryLength = UInt64(root.count)
        header.metadataOffset = header.rootDirectoryOffset + header.rootDirectoryLength
        header.metadataLength = UInt64(compressedMetadata.count)
        header.leafDirectoryOffset = header.metadataOffset + header.metadataLength
        header.leafDirectoryLength = UInt64(leaves.count)
        header.tileDataOffset = header.leafDirectoryOffset + header.leafDirectoryLength

        var prefix = header.serialized()
        prefix.append(root)
        prefix.append(compressedMetadata)
        prefix.append(leaves)
        return PMTilesArchiveLayout(header: header, prefix: prefix)
    }

    private static func split(
        _ entries: [PMTilesEntry], leafSize: Int, compress: (Data) throws -> Data
    ) throws -> (root: Data, leaves: Data) {
        var rootEntries: [PMTilesEntry] = []
        var leaves = Data()
        for start in stride(from: 0, to: entries.count, by: leafSize) {
            let chunk = Array(entries[start..<min(start + leafSize, entries.count)])
            let leaf = try compress(PMTilesDirectory.encode(chunk))
            let pointer = PMTilesEntry(tileID: chunk[0].tileID, offset: UInt64(leaves.count), length: UInt32(leaf.count), runLength: 0)
            rootEntries.append(pointer)
            leaves.append(leaf)
        }
        return (try compress(PMTilesDirectory.encode(rootEntries)), leaves)
    }
}
