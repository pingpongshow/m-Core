import Foundation
import Testing
@testable import MeshMaps

struct PMTilesReaderTests {
    @Test(arguments: [PMTilesCompression.gzip, .none])
    func resolvesTilesThroughLeafDirectories(compression: PMTilesCompression) async throws {
        let directory = try TemporaryDirectory()
        let url = directory.file("source.pmtiles")
        let tiles = SyntheticArchive.worldTiles(zooms: 0...5)
        let written = try SyntheticArchive.write(tiles, to: url, internalCompression: compression, leafEntryCount: 64)
        #expect(written.leafDirectoryLength > 0)

        let counting = CountingFetcher(FileRangeFetcher(fileURL: url))
        let reader = try await PMTilesReader(fetcher: counting)
        #expect(reader.header == written)
        #expect(reader.rootDirectory.allSatisfy { $0.isLeaf })
        #expect(reader.metadata == SyntheticArchive.metadata)

        for tile in tiles {
            #expect(try await reader.tileData(for: tile.id) == tile.data)
        }
        #expect(try await reader.locate(UInt64(tiles.count)) == nil)

        // Each leaf is fetched once, then served from the cache.
        let leafCount = reader.rootDirectory.count
        #expect(await reader.cachedLeafCount == leafCount)
        let before = await counting.requests.count
        _ = try await reader.locate(tiles.map(\.id))
        #expect(await counting.requests.count == before)
    }

    @Test func batchLocateMatchesSingleLookups() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.file("source.pmtiles")
        try SyntheticArchive.write(SyntheticArchive.worldTiles(zooms: 0...4), to: url, leafEntryCount: 10)
        let reader = try await PMTilesReader(fetcher: FileRangeFetcher(fileURL: url))
        let ids = Array(UInt64(0)..<400)
        let batch = try await reader.locate(ids)
        for (index, id) in ids.enumerated() {
            #expect(try await reader.locate(id) == batch[index])
        }
        #expect(batch[340] != nil && batch[341] == nil)
    }

    @Test func rejectsNonPMTiles() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.file("junk.bin")
        try Data(repeating: 7, count: 500).write(to: url)
        await #expect(throws: PMTilesError.invalidMagic) { _ = try await PMTilesReader(fetcher: FileRangeFetcher(fileURL: url)) }
    }

    /// A damaged or hostile file (e.g. one AirDropped for import) must fail to open, not trap on overflow.
    @Test(arguments: [(UInt64(127), UInt64.max), (UInt64.max, UInt64(10)), (UInt64(0), UInt64(Int.max) + 1)])
    func rejectsSectionRangesOutsideUInt64(offset: UInt64, length: UInt64) async throws {
        let directory = try TemporaryDirectory()
        let url = directory.file("hostile.pmtiles")
        try SyntheticArchive.write(SyntheticArchive.worldTiles(zooms: 0...2), to: url)
        var data = try Data(contentsOf: url)
        var header = try PMTilesHeader(data: data)
        header.metadataOffset = offset
        header.metadataLength = length
        data.replaceSubrange(0..<PMTilesHeader.length, with: header.serialized())
        try data.write(to: url)
        await #expect(throws: PMTilesError.truncatedData) { _ = try await PMTilesReader(fetcher: FileRangeFetcher(fileURL: url)) }
    }
}
