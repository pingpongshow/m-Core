import Foundation

/// Extracts an area of a (remote) PMTiles archive into a small local PMTiles v3 file.
///
/// Output is clustered, keeps the source's payload de-duplication, uses uncompressed directories and
/// copies tile payloads verbatim (tile compression and type are inherited from the source).
public struct PMTilesExtractor: Sendable {
    /// Tuning for tile data downloads.
    public struct Configuration: Sendable, Hashable {
        /// Adjacent payloads closer than this are fetched in one request (gap bytes are discarded).
        public var maxGapBytes: UInt64
        /// Upper bound on a single coalesced request (a larger single tile still gets its own request).
        public var maxBatchBytes: UInt64
        /// Parallel range requests during extraction.
        public var maxConcurrentRequests: Int

        public init(maxGapBytes: UInt64 = 64 * 1024, maxBatchBytes: UInt64 = 4 * 1024 * 1024, maxConcurrentRequests: Int = 4) {
            self.maxGapBytes = maxGapBytes
            self.maxBatchBytes = maxBatchBytes
            self.maxConcurrentRequests = max(1, maxConcurrentRequests)
        }
    }

    public let reader: PMTilesReader
    public var configuration: Configuration
    /// Splits output into leaves of this many entries even when the root would fit (tests only).
    var forcedLeafEntryCount: Int?

    public init(reader: PMTilesReader, configuration: Configuration = Configuration()) {
        self.reader = reader
        self.configuration = configuration
    }

    /// Enumerates every tile covering `bounds` in `zoomRange`, resolves source byte ranges through the
    /// directory tree (no tile data is downloaded) and computes the exact output layout.
    public func plan(bounds: GeoBounds, zoomRange: ClosedRange<Int>) async throws -> ExtractPlan {
        let source = reader.header
        let box = bounds.normalized
        let lower = max(zoomRange.lowerBound, Int(source.minZoom))
        let upper = min(zoomRange.upperBound, Int(source.maxZoom), TileCoordinate.maxZoom)
        guard lower <= upper else { throw PMTilesError.zoomRangeOutsideSource }

        var tileIDs: [UInt64] = []
        for zoom in lower...upper {
            try Task.checkCancellation()
            // Zoom blocks occupy ascending, disjoint ID ranges, so appending sorted blocks keeps the array sorted.
            tileIDs.append(contentsOf: TileRange(bounds: box, zoom: zoom).tileIDs())
        }
        let locations = try await reader.locate(tileIDs)
        try Task.checkCancellation()

        let output = Self.outputEntries(tileIDs: tileIDs, locations: locations)
        guard output.tileCount > 0 else { throw PMTilesError.noTilesInArea }
        var template = Self.outputHeader(source: source, bounds: box, zooms: lower...upper)
        template.tileDataLength = output.payloadBytes
        template.addressedTileCount = UInt64(output.tileCount)
        template.tileEntryCount = UInt64(output.entries.count)
        template.tileContentCount = UInt64(output.copies.count)

        let metadata = Self.outputMetadata(source: reader.metadata, bounds: box, zoomRange: lower...upper, centerZoom: template.centerZoom)
        let layout = try PMTilesArchiveBuilder.layout(
            entries: output.entries, metadata: metadata, template: template, forcedLeafEntryCount: forcedLeafEntryCount
        )
        return ExtractPlan(
            bounds: box,
            zoomRange: lower...upper,
            tileCount: output.tileCount,
            uniqueTileCount: output.copies.count,
            missingTileCount: tileIDs.count - output.tileCount,
            payloadBytes: Int64(output.payloadBytes),
            estimatedFileSize: Int64(layout.prefix.count) + Int64(output.payloadBytes),
            outputHeader: layout.header,
            prefix: layout.prefix,
            copies: output.copies
        )
    }

    /// Output directory entries and unique payload copies. Payloads are numbered in tile ID order (clustered);
    /// repeated source ranges reuse the first output offset, and consecutive repeats become runs.
    static func outputEntries(tileIDs: [UInt64], locations: [TileLocation?]) -> OutputEntries {
        var entries: [PMTilesEntry] = []
        var copies: [ContentCopy] = []
        var outputOffsets: [TileLocation: UInt64] = [:]
        var nextOffset: UInt64 = 0
        var tileCount = 0
        for (index, tileID) in tileIDs.enumerated() {
            guard let location = locations[index] else { continue }
            tileCount += 1
            let outputOffset: UInt64
            if let existing = outputOffsets[location] {
                outputOffset = existing
            } else {
                outputOffset = nextOffset
                outputOffsets[location] = outputOffset
                copies.append(ContentCopy(sourceOffset: location.offset, length: location.length, outputOffset: outputOffset))
                nextOffset += location.length
            }
            if let last = entries.last, last.offset == outputOffset, last.tileID + UInt64(last.runLength) == tileID,
               last.runLength < UInt32.max {
                entries[entries.count - 1].runLength += 1
            } else {
                entries.append(PMTilesEntry(tileID: tileID, offset: outputOffset, length: UInt32(location.length), runLength: 1))
            }
        }
        copies.sort { $0.sourceOffset < $1.sourceOffset }
        return OutputEntries(entries: entries, copies: copies, tileCount: tileCount, payloadBytes: nextOffset)
    }

    /// Header fields that do not depend on the layout: clustered, uncompressed directories, source tile format,
    /// extracted zooms, bounds and center.
    static func outputHeader(source: PMTilesHeader, bounds: GeoBounds, zooms: ClosedRange<Int>) -> PMTilesHeader {
        var header = PMTilesHeader()
        header.isClustered = true
        header.internalCompression = .none
        header.tileCompression = source.tileCompression
        header.tileType = source.tileType
        header.minZoom = UInt8(zooms.lowerBound)
        header.maxZoom = UInt8(zooms.upperBound)
        header.bounds = bounds
        header.centerZoom = UInt8(centerZoom(for: bounds, in: zooms))
        header.centerLongitudeE7 = PMTilesHeader.e7(bounds.center.longitude)
        header.centerLatitudeE7 = PMTilesHeader.e7(bounds.center.latitude)
        return header
    }

    /// Downloads the plan's payloads in coalesced batches and writes the archive to `fileURL` (replacing it).
    ///
    /// Data goes to a hidden temporary file beside `fileURL` that is moved into place only on success; on
    /// error or cancellation it is deleted. `progress` receives (payload bytes done, payload bytes total).
    public func extract(
        plan: ExtractPlan,
        to fileURL: URL,
        progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }
    ) async throws {
        let directory = fileURL.deletingLastPathComponent()
        let tempURL = directory.appending(path: ".\(fileURL.lastPathComponent).\(UUID().uuidString).partial")
        do {
            try await extract(plan: plan, partialURL: tempURL, completedBatches: IndexSet(), progress: progress)
            try Self.finish(partialURL: tempURL, plan: plan, to: fileURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    /// Resumable form of ``extract(plan:to:progress:)``: writes into `partialURL` (created if needed, kept on
    /// failure), skipping the batches in `completedBatches`.
    ///
    /// Every `checkpointInterval`, and once more when it stops for any reason, the file is flushed to disk and
    /// `checkpoint` receives the batches written so far and their payload bytes, so a later call can carry on.
    /// Call ``finish(partialURL:plan:to:)`` once this returns.
    public func extract(
        plan: ExtractPlan,
        partialURL: URL,
        completedBatches: IndexSet,
        checkpointInterval: Duration = .seconds(1),
        checkpoint: @escaping @Sendable (IndexSet, Int64) async -> Void = { _, _ in },
        progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }
    ) async throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: partialURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: partialURL.path) {
            guard fileManager.createFile(atPath: partialURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: partialURL.path])
            }
        }
        let handle = try FileHandle(forWritingTo: partialURL)
        do {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: plan.prefix)
            try await writeTileData(
                plan: plan, handle: handle, base: UInt64(plan.prefix.count), completed: completedBatches,
                checkpointInterval: checkpointInterval, checkpoint: checkpoint, progress: progress
            )
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        try Task.checkCancellation()
    }

    /// Moves a completely written partial file into place at `fileURL` (replacing it), trimmed to the plan's size.
    public static func finish(partialURL: URL, plan: ExtractPlan, to fileURL: URL) throws {
        let fileManager = FileManager.default
        let handle = try FileHandle(forWritingTo: partialURL)
        try handle.truncate(atOffset: UInt64(plan.estimatedFileSize))
        try handle.close()
        if fileManager.fileExists(atPath: fileURL.path) {
            _ = try fileManager.replaceItemAt(fileURL, withItemAt: partialURL)
        } else {
            try fileManager.moveItem(at: partialURL, to: fileURL)
        }
    }

    /// Number of coalesced reads ``extract(plan:partialURL:completedBatches:checkpointInterval:checkpoint:progress:)``
    /// makes for `plan` with this configuration; batch indices run from 0 to this count.
    public func batchCount(for plan: ExtractPlan) -> Int {
        batches(for: plan).count
    }

    /// Identifies a plan and how it is batched, so a resumed download can check it re-planned exactly the same work.
    public func fingerprint(of plan: ExtractPlan) -> ExtractFingerprint {
        let batches = batches(for: plan)
        return ExtractFingerprint(
            zoomRange: [plan.zoomRange.lowerBound, plan.zoomRange.upperBound],
            tileCount: plan.tileCount,
            uniqueTileCount: plan.uniqueTileCount,
            payloadBytes: plan.payloadBytes,
            estimatedFileSize: plan.estimatedFileSize,
            batchCount: batches.count,
            lastBatchEnd: batches.last.map { $0.offset + $0.length } ?? 0,
            maxGapBytes: configuration.maxGapBytes,
            maxBatchBytes: configuration.maxBatchBytes,
            prefixChecksum: CRC32.checksum(plan.prefix)
        )
    }

    /// Payload bytes covered by `batches` of `plan`.
    public func payloadBytes(of batchIndices: IndexSet, in plan: ExtractPlan) -> Int64 {
        let batches = batches(for: plan)
        return batchIndices.reduce(Int64(0)) { sum, index in
            index < batches.count ? sum + batches[index].payloadBytes : sum
        }
    }

    private func batches(for plan: ExtractPlan) -> [FetchBatch] {
        FetchBatch.coalesce(plan.copies, maxGap: configuration.maxGapBytes, maxBytes: configuration.maxBatchBytes)
    }

    // swiftlint:disable:next function_parameter_count
    private func writeTileData(
        plan: ExtractPlan, handle: FileHandle, base: UInt64, completed initial: IndexSet,
        checkpointInterval: Duration, checkpoint: @escaping @Sendable (IndexSet, Int64) async -> Void,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        let batches = batches(for: plan)
        let pending = batches.indices.filter { !initial.contains($0) }
        let fetcher = reader.fetcher
        let total = plan.payloadBytes
        var completed = initial
        var done = payloadBytes(of: initial, in: plan)
        let clock = ContinuousClock()
        var lastCheckpoint = clock.now
        progress(done, total)
        do {
            try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                var next = 0
                func addNext() {
                    guard next < pending.count else { return }
                    let index = pending[next]
                    let batch = batches[index]
                    next += 1
                    group.addTask {
                        try Task.checkCancellation()
                        let data = try await fetcher.fetch(offset: batch.offset, length: batch.length)
                        guard UInt64(data.count) == batch.length else { throw PMTilesError.truncatedData }
                        return (index, data)
                    }
                }
                for _ in 0..<configuration.maxConcurrentRequests { addNext() }
                while let (index, data) = try await group.next() {
                    try Task.checkCancellation()
                    let batch = batches[index]
                    for copy in plan.copies[batch.copies] {
                        let start = data.startIndex + Int(copy.sourceOffset - batch.offset)
                        try handle.seek(toOffset: base + copy.outputOffset)
                        try handle.write(contentsOf: data[start..<start + Int(copy.length)])
                    }
                    completed.insert(index)
                    done += batch.payloadBytes
                    progress(done, total)
                    if clock.now - lastCheckpoint >= checkpointInterval {
                        try handle.synchronize()
                        await checkpoint(completed, done)
                        lastCheckpoint = clock.now
                    }
                    addNext()
                }
            }
        } catch {
            // Record what did reach the file, so a resumed download skips it.
            if (try? handle.synchronize()) != nil { await checkpoint(completed, done) }
            throw error
        }
        await checkpoint(completed, done)
    }

    /// A zoom at which the area spans roughly one or two tiles, clamped to the extracted zooms.
    static func centerZoom(for bounds: GeoBounds, in zooms: ClosedRange<Int>) -> Int {
        let span = max(bounds.maxLongitude - bounds.minLongitude, 1e-6)
        let zoom = Int(log2(360 / span).rounded(.down))
        return min(max(zoom, zooms.lowerBound), zooms.upperBound)
    }

    /// Source metadata with TileJSON-style `bounds`, `center`, `minzoom` and `maxzoom` set for the extract.
    /// Non-object metadata is copied verbatim.
    static func outputMetadata(source: Data, bounds: GeoBounds, zoomRange: ClosedRange<Int>, centerZoom: UInt8) -> Data {
        guard var object = (try? JSONSerialization.jsonObject(with: source)) as? [String: Any] else { return source }
        object["bounds"] = [bounds.minLongitude, bounds.minLatitude, bounds.maxLongitude, bounds.maxLatitude]
        object["center"] = [bounds.center.longitude, bounds.center.latitude, Double(centerZoom)]
        object["minzoom"] = zoomRange.lowerBound
        object["maxzoom"] = zoomRange.upperBound
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? source
    }
}

extension PMTilesExtractor {
    /// Smallest partial file that can contain `batchIndices` of `plan`: the prefix plus the furthest byte they write.
    public func minimumPartialSize(for batchIndices: IndexSet, in plan: ExtractPlan) -> Int64 {
        let batches = batches(for: plan)
        let base = UInt64(plan.prefix.count)
        var end = base
        for index in batchIndices where index < batches.count {
            for copy in plan.copies[batches[index].copies] {
                end = max(end, base + copy.outputOffset + copy.length)
            }
        }
        return Int64(end)
    }
}

/// What a plan downloads and how it is batched; equal fingerprints mean batch indices refer to the same bytes.
public struct ExtractFingerprint: Hashable, Sendable, Codable {
    public var zoomRange: [Int]
    public var tileCount: Int
    public var uniqueTileCount: Int
    public var payloadBytes: Int64
    public var estimatedFileSize: Int64
    public var batchCount: Int
    public var lastBatchEnd: UInt64
    public var maxGapBytes: UInt64
    public var maxBatchBytes: UInt64
    /// CRC-32 of the header, directories and metadata.
    public var prefixChecksum: UInt32
}

/// Output directory content computed while planning.
struct OutputEntries {
    let entries: [PMTilesEntry]
    let copies: [ContentCopy]
    let tileCount: Int
    let payloadBytes: UInt64
}
