import Foundation
import Testing
@testable import MeshMaps

struct PMTilesExtractorTests {
    /// A small area in the northern hemisphere, west of Greenwich.
    let area = GeoBounds(minLongitude: -40, minLatitude: 10, maxLongitude: -5, maxLatitude: 50)

    private func makeSource(
        _ directory: TemporaryDirectory, zooms: ClosedRange<Int> = 0...6, leafEntryCount: Int? = 100
    ) throws -> (url: URL, tiles: [UInt64: Data]) {
        let url = directory.file("source.pmtiles")
        let tiles = SyntheticArchive.worldTiles(zooms: zooms)
        try SyntheticArchive.write(tiles, to: url, internalCompression: .gzip, leafEntryCount: leafEntryCount)
        return (url, Dictionary(uniqueKeysWithValues: tiles.map { ($0.id, $0.data) }))
    }

    /// Expected tile IDs, computed independently of the extractor.
    private func expectedIDs(_ bounds: GeoBounds, _ zooms: ClosedRange<Int>) -> [UInt64] {
        zooms.flatMap { zoom in
            let range = TileRange(bounds: bounds, zoom: zoom)
            return (range.minX...range.maxX).flatMap { x in
                (range.minY...range.maxY).map { y in TileCoordinate(z: zoom, x: x, y: y).tileID }
            }
        }
    }

    @Test func planCountsTilesAndBytesWithoutDownloadingTiles() async throws {
        let directory = try TemporaryDirectory()
        let source = try makeSource(directory)
        let counting = CountingFetcher(FileRangeFetcher(fileURL: source.url))
        let reader = try await PMTilesReader(fetcher: counting)
        let plan = try await PMTilesExtractor(reader: reader).plan(bounds: area, zoomRange: 0...6)

        let ids = expectedIDs(area, 0...6)
        let unique = Set(ids.compactMap { source.tiles[$0] })
        #expect(plan.zoomRange == 0...6)
        #expect(plan.tileCount == ids.count)
        #expect(plan.missingTileCount == 0)
        #expect(plan.uniqueTileCount == unique.count)
        #expect(plan.payloadBytes == Int64(unique.reduce(0) { $0 + $1.count }))
        #expect(plan.estimatedFileSize > plan.payloadBytes)

        // Only the initial read and leaf directories were fetched; nothing reached into tile data.
        let tileDataOffset = reader.header.tileDataOffset
        #expect(await counting.requests.allSatisfy { $0.offset < tileDataOffset })
    }

    @Test func planClampsZoomsAndRejectsEmptyRequests() async throws {
        let directory = try TemporaryDirectory()
        let source = try makeSource(directory, zooms: 0...4, leafEntryCount: nil)
        let extractor = PMTilesExtractor(reader: try await PMTilesReader(fetcher: FileRangeFetcher(fileURL: source.url)))
        let plan = try await extractor.plan(bounds: area, zoomRange: 2...13)
        #expect(plan.zoomRange == 2...4)
        #expect(plan.outputHeader.minZoom == 2 && plan.outputHeader.maxZoom == 4)
        await #expect(throws: PMTilesError.zoomRangeOutsideSource) { _ = try await extractor.plan(bounds: area, zoomRange: 5...9) }
    }

    @Test func reportsMissingTilesInSparseSources() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.file("sparse.pmtiles")
        // Only even tile IDs exist.
        let tiles = SyntheticArchive.worldTiles(zooms: 0...3).filter { $0.id.isMultiple(of: 2) }
        try SyntheticArchive.write(tiles, to: url)
        let extractor = PMTilesExtractor(reader: try await PMTilesReader(fetcher: FileRangeFetcher(fileURL: url)))
        let plan = try await extractor.plan(bounds: .world, zoomRange: 0...3)
        #expect(plan.tileCount == tiles.count)
        #expect(plan.missingTileCount == 85 - tiles.count)
    }

    @Test func extractWritesReadableArchiveWithIdenticalPayloads() async throws {
        let directory = try TemporaryDirectory()
        let source = try makeSource(directory)
        let reader = try await PMTilesReader(fetcher: FileRangeFetcher(fileURL: source.url))
        // Tiny batches force many coalesced requests.
        let configuration = PMTilesExtractor.Configuration(maxGapBytes: 40, maxBatchBytes: 300, maxConcurrentRequests: 3)
        let extractor = PMTilesExtractor(reader: reader, configuration: configuration)
        let plan = try await extractor.plan(bounds: area, zoomRange: 1...6)
        let output = directory.file("out/area.pmtiles")
        let updates = ProgressLog()
        try await extractor.extract(plan: plan, to: output) { done, total in updates.record(done, total) }

        let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
        #expect((attributes[.size] as? NSNumber)?.int64Value == plan.estimatedFileSize)
        let last = try #require(updates.values.last)
        #expect(last == ProgressLog.Pair(done: plan.payloadBytes, total: plan.payloadBytes))
        #expect(updates.values.count > 2)

        let extracted = try await PMTilesReader(fetcher: FileRangeFetcher(fileURL: output))
        let header = extracted.header
        #expect(header.isClustered)
        #expect(header.internalCompression == PMTilesCompression.none)
        #expect(header.tileCompression == reader.header.tileCompression)
        #expect(header.tileType == .mvt)
        #expect(header.minZoom == 1 && header.maxZoom == 6)
        #expect(header.addressedTileCount == UInt64(plan.tileCount))
        #expect(header.tileContentCount == UInt64(plan.uniqueTileCount))
        #expect(header.tileDataLength == UInt64(plan.payloadBytes))
        #expect(header.bounds.minLongitude == -40 && header.bounds.maxLatitude == 50)
        #expect(header.centerLongitudeE7 == PMTilesHeader.e7(-22.5))
        #expect(header.rootDirectoryOffset + header.rootDirectoryLength <= 16_384)

        let ids = expectedIDs(area, 1...6)
        for id in ids {
            #expect(try await extracted.tileData(for: id) == source.tiles[id])
        }
        // Tiles outside the area or zoom range are absent.
        #expect(try await extracted.locate(0) == nil)
        #expect(try await extracted.locate(TileCoordinate(z: 6, x: 63, y: 63).tileID) == nil)

        let metadata = try #require(try JSONSerialization.jsonObject(with: extracted.metadata) as? [String: Any])
        #expect(metadata["name"] as? String == "synthetic")
        #expect(metadata["vector_layers"] != nil)
        #expect(metadata["minzoom"] as? Int == 1 && metadata["maxzoom"] as? Int == 6)
    }

    @Test func outputKeepsDeduplication() async throws {
        let directory = try TemporaryDirectory()
        let source = try makeSource(directory)
        let reader = try await PMTilesReader(fetcher: FileRangeFetcher(fileURL: source.url))
        let extractor = PMTilesExtractor(reader: reader)
        let plan = try await extractor.plan(bounds: area, zoomRange: 2...6)
        #expect(plan.uniqueTileCount < plan.tileCount)
        let output = directory.file("dedup.pmtiles")
        try await extractor.extract(plan: plan, to: output)

        let extracted = try await PMTilesReader(fetcher: FileRangeFetcher(fileURL: output))
        let oceanIDs = expectedIDs(area, 2...6).filter { source.tiles[$0] == Data("ocean-blob".utf8) }
        #expect(oceanIDs.count > 10)
        let oceanLocations = Set(try await extracted.locate(oceanIDs).compactMap { $0 })
        #expect(oceanLocations.count == 1)
        #expect(extracted.header.tileContentCount < extracted.header.addressedTileCount)
    }

    @Test func repeatedNeighboursCollapseIntoRuns() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.file("ocean.pmtiles")
        // Everything from z3 up is the same blob, as in open ocean.
        let tiles = SyntheticArchive.worldTiles(zooms: 0...6) { coordinate in
            coordinate.z >= 3 ? Data("ocean".utf8) : Data("land \(coordinate)".utf8)
        }
        try SyntheticArchive.write(tiles, to: url)
        let extractor = PMTilesExtractor(reader: try await PMTilesReader(fetcher: FileRangeFetcher(fileURL: url)))
        let plan = try await extractor.plan(bounds: area, zoomRange: 3...6)
        #expect(plan.uniqueTileCount == 1)
        #expect(plan.payloadBytes == 5)
        let output = directory.file("out.pmtiles")
        try await extractor.extract(plan: plan, to: output)
        let extracted = try await PMTilesReader(fetcher: FileRangeFetcher(fileURL: output))
        #expect(extracted.header.tileEntryCount < extracted.header.addressedTileCount)
        #expect(extracted.header.tileDataLength == 5)
        for id in expectedIDs(area, 3...6) {
            #expect(try await extracted.tileData(for: id) == Data("ocean".utf8))
        }
    }

    @Test func manyTilesSplitIntoLeafDirectories() async throws {
        let directory = try TemporaryDirectory()
        // 21,845 distinct tiles: an uncompressed root of all entries would exceed 16 KiB.
        let source = try makeSource(directory, zooms: 0...7, leafEntryCount: nil)
        let reader = try await PMTilesReader(fetcher: FileRangeFetcher(fileURL: source.url))
        let extractor = PMTilesExtractor(reader: reader)
        let plan = try await extractor.plan(bounds: .world, zoomRange: 0...7)
        #expect(plan.tileCount == 21_845)
        let output = directory.file("world.pmtiles")
        try await extractor.extract(plan: plan, to: output)

        let extracted = try await PMTilesReader(fetcher: FileRangeFetcher(fileURL: output))
        let header = extracted.header
        #expect(header.leafDirectoryLength > 0)
        #expect(header.rootDirectoryOffset == 127)
        #expect(header.rootDirectoryOffset + header.rootDirectoryLength <= 16_384)
        #expect(extracted.rootDirectory.allSatisfy { $0.isLeaf })
        let ids = Array(source.tiles.keys).sorted()
        let locations = try await extracted.locate(ids)
        #expect(locations.allSatisfy { $0 != nil })
        for id in stride(from: 0, to: ids.count, by: 97) {
            #expect(try await extracted.tileData(for: ids[id]) == source.tiles[ids[id]])
        }
    }

    @Test func forcedLeavesStayReadable() async throws {
        let directory = try TemporaryDirectory()
        let source = try makeSource(directory, zooms: 0...5)
        var extractor = PMTilesExtractor(reader: try await PMTilesReader(fetcher: FileRangeFetcher(fileURL: source.url)))
        extractor.forcedLeafEntryCount = 7
        let plan = try await extractor.plan(bounds: area, zoomRange: 0...5)
        let output = directory.file("leaves.pmtiles")
        try await extractor.extract(plan: plan, to: output)
        let extracted = try await PMTilesReader(fetcher: FileRangeFetcher(fileURL: output))
        #expect(extracted.header.leafDirectoryLength > 0)
        for id in expectedIDs(area, 0...5) {
            #expect(try await extracted.tileData(for: id) == source.tiles[id])
        }
    }

    @Test func cancellationRemovesPartialFile() async throws {
        let directory = try TemporaryDirectory()
        let source = try makeSource(directory)
        let plain = try await PMTilesReader(fetcher: FileRangeFetcher(fileURL: source.url))
        let gated = GatedFetcher(base: FileRangeFetcher(fileURL: source.url), threshold: plain.header.tileDataOffset, behavior: .sleep)
        let extractor = PMTilesExtractor(reader: try await PMTilesReader(fetcher: gated))
        let plan = try await extractor.plan(bounds: area, zoomRange: 0...6)
        let outputDirectory = try TemporaryDirectory()
        let output = outputDirectory.file("area.pmtiles")

        let task = Task { try await extractor.extract(plan: plan, to: output) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try outputDirectory.contents().isEmpty)
    }

    @Test func failureRemovesPartialFileAndKeepsExistingOutput() async throws {
        let directory = try TemporaryDirectory()
        let source = try makeSource(directory)
        let plain = try await PMTilesReader(fetcher: FileRangeFetcher(fileURL: source.url))
        let gated = GatedFetcher(base: FileRangeFetcher(fileURL: source.url), threshold: plain.header.tileDataOffset, behavior: .fail)
        let extractor = PMTilesExtractor(reader: try await PMTilesReader(fetcher: gated))
        let plan = try await extractor.plan(bounds: area, zoomRange: 0...6)
        let outputDirectory = try TemporaryDirectory()
        let output = outputDirectory.file("area.pmtiles")
        try Data("previous".utf8).write(to: output)

        await #expect(throws: GatedFetcher.InjectedFailure.self) { try await extractor.extract(plan: plan, to: output) }
        #expect(try outputDirectory.contents() == ["area.pmtiles"])
        #expect(try Data(contentsOf: output) == Data("previous".utf8))
    }

    @Test func coalescesNearbyRanges() {
        let copies = [
            ContentCopy(sourceOffset: 0, length: 10, outputOffset: 0),
            ContentCopy(sourceOffset: 15, length: 10, outputOffset: 10),     // gap 5 → merged
            ContentCopy(sourceOffset: 100, length: 10, outputOffset: 20),    // gap 75 → new batch
            ContentCopy(sourceOffset: 110, length: 500, outputOffset: 30),   // would exceed max → new batch
        ]
        let batches = FetchBatch.coalesce(copies, maxGap: 10, maxBytes: 200)
        #expect(batches.map(\.offset) == [0, 100, 110])
        #expect(batches.map(\.length) == [25, 10, 500])
        #expect(batches.map(\.copies) == [0..<2, 2..<3, 3..<4])
        #expect(batches.map(\.payloadBytes) == [20, 10, 500])
    }
}

/// Thread-safe progress recorder.
final class ProgressLog: Sendable {
    struct Pair: Equatable, Sendable {
        let done: Int64
        let total: Int64
    }

    private let storage = LockedBox<[Pair]>([])

    func record(_ done: Int64, _ total: Int64) {
        storage.mutate { $0.append(Pair(done: done, total: total)) }
    }

    var values: [Pair] { storage.value }
}
