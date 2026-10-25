import Foundation

/// Absolute byte range of a tile payload within an archive.
public struct TileLocation: Hashable, Sendable {
    public let offset: UInt64
    public let length: UInt64

    public init(offset: UInt64, length: UInt64) {
        self.offset = offset
        self.length = length
    }
}

/// Reads a PMTiles v3 archive through a ``RangeFetcher``: header, root directory and metadata on open,
/// leaf directories on demand (cached in memory, up to `maxCachedLeaves`).
public actor PMTilesReader {
    /// Bytes fetched on open; spec-conformant archives have header and root directory inside it.
    public static let initialFetchLength: UInt64 = 16_384
    /// Leaf nesting limit; the spec discourages more than one level.
    public static let maxDirectoryDepth = 4
    private static let maxConcurrentLeafFetches = 8

    nonisolated public let fetcher: any RangeFetcher
    nonisolated public let header: PMTilesHeader
    nonisolated public let rootDirectory: [PMTilesEntry]
    /// Decompressed JSON metadata.
    nonisolated public let metadata: Data

    private var leafCache: [LeafKey: [PMTilesEntry]] = [:]
    /// Leaf directories are a few KB to ~100 KB each; past this many the cache starts over.
    static let maxCachedLeaves = 512

    public init(fetcher: any RangeFetcher) async throws {
        let initial = try await fetcher.fetch(offset: 0, length: Self.initialFetchLength)
        let header = try PMTilesHeader(data: initial)
        let rootBytes = try await Self.section(
            offset: header.rootDirectoryOffset, length: header.rootDirectoryLength, initial: initial, fetcher: fetcher
        )
        let metadataBytes = try await Self.section(
            offset: header.metadataOffset, length: header.metadataLength, initial: initial, fetcher: fetcher
        )
        self.fetcher = fetcher
        self.header = header
        self.rootDirectory = try PMTilesDirectory.decode(header.internalCompression.decompress(rootBytes))
        self.metadata = header.metadataLength == 0 ? Data("{}".utf8) : try header.internalCompression.decompress(metadataBytes)
    }

    /// Resolves one tile ID; `nil` when the archive has no such tile.
    public func locate(_ tileID: UInt64) async throws -> TileLocation? {
        try await locate([tileID])[0]
    }

    /// Resolves many tile IDs at once, fetching each needed leaf directory once (in parallel).
    /// Results align with `tileIDs`.
    public func locate(_ tileIDs: [UInt64]) async throws -> [TileLocation?] {
        var results = [TileLocation?](repeating: nil, count: tileIDs.count)
        var pending: [(directory: [PMTilesEntry], indices: [Int])] = [(rootDirectory, Array(tileIDs.indices))]
        for _ in 0..<Self.maxDirectoryDepth {
            var leafRequests: [LeafKey: [Int]] = [:]
            for (directory, indices) in pending {
                for index in indices {
                    guard let entry = PMTilesDirectory.find(tileIDs[index], in: directory) else { continue }
                    if entry.isLeaf {
                        leafRequests[LeafKey(offset: entry.offset, length: entry.length), default: []].append(index)
                    } else {
                        results[index] = TileLocation(offset: header.tileDataOffset + entry.offset, length: UInt64(entry.length))
                    }
                }
            }
            if leafRequests.isEmpty { return results }
            let leaves = try await loadLeaves(Array(leafRequests.keys))
            pending = leafRequests.compactMap { key, indices in leaves[key].map { ($0, indices) } }
        }
        throw PMTilesError.directoryTooDeep
    }

    /// Fetches the payload for `tileID` verbatim (still tile-compressed), or `nil` if absent.
    public func tileData(for tileID: UInt64) async throws -> Data? {
        guard let location = try await locate(tileID) else { return nil }
        return try await fetcher.fetch(offset: location.offset, length: location.length)
    }

    /// Number of leaf directories currently cached.
    public var cachedLeafCount: Int { leafCache.count }

    private func loadLeaves(_ keys: [LeafKey]) async throws -> [LeafKey: [PMTilesEntry]] {
        var result: [LeafKey: [PMTilesEntry]] = [:]
        var missing: [LeafKey] = []
        for key in keys {
            if let cached = leafCache[key] { result[key] = cached } else { missing.append(key) }
        }
        let fetcher = fetcher
        let base = header.leafDirectoryOffset
        let compression = header.internalCompression
        let fetched = try await withThrowingTaskGroup(of: (LeafKey, [PMTilesEntry]).self) { group in
            var iterator = missing.makeIterator()
            func addNext() -> Bool {
                guard let key = iterator.next() else { return false }
                group.addTask {
                    let bytes = try await fetcher.fetch(offset: base + key.offset, length: UInt64(key.length))
                    guard bytes.count == Int(key.length) else { throw PMTilesError.truncatedData }
                    return (key, try PMTilesDirectory.decode(compression.decompress(bytes)))
                }
                return true
            }
            for _ in 0..<Self.maxConcurrentLeafFetches {
                guard addNext() else { break }
            }
            var collected: [(LeafKey, [PMTilesEntry])] = []
            while let item = try await group.next() {
                collected.append(item)
                _ = addNext()
            }
            return collected
        }
        // Bound memory when a long-lived reader (size estimates) wanders over large areas.
        if leafCache.count + fetched.count > Self.maxCachedLeaves { leafCache.removeAll(keepingCapacity: true) }
        for (key, entries) in fetched {
            leafCache[key] = entries
            result[key] = entries
        }
        return result
    }

    private static func section(offset: UInt64, length: UInt64, initial: Data, fetcher: any RangeFetcher) async throws -> Data {
        // Header values come from the file; a damaged or hostile one must fail here rather than overflow.
        let (end, overflow) = offset.addingReportingOverflow(length)
        guard !overflow, end <= UInt64(Int.max) else { throw PMTilesError.truncatedData }
        if end <= UInt64(initial.count) {
            return initial.subdata(in: Int(offset)..<Int(offset + length))
        }
        let data = try await fetcher.fetch(offset: offset, length: length)
        guard UInt64(data.count) == length else { throw PMTilesError.truncatedData }
        return data
    }
}

private struct LeafKey: Hashable, Sendable {
    let offset: UInt64
    let length: UInt32
}
