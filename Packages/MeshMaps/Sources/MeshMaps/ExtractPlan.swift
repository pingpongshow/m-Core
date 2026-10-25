import Foundation

/// The result of planning an extract: which source payloads to copy and the exact output layout.
/// Built by ``PMTilesExtractor/plan(bounds:zoomRange:)`` without downloading any tile data.
public struct ExtractPlan: Sendable {
    /// Requested area, clamped to the Web Mercator world.
    public let bounds: GeoBounds
    /// Zooms actually extracted (the request intersected with the source's zooms).
    public let zoomRange: ClosedRange<Int>
    /// Tiles addressed in the output.
    public let tileCount: Int
    /// Distinct payloads stored after de-duplication.
    public let uniqueTileCount: Int
    /// Tiles inside the area that the source archive does not contain.
    public let missingTileCount: Int
    /// Exact bytes of tile data to download and store (unique payloads only).
    public let payloadBytes: Int64
    /// Output file size: header, directories and metadata plus ``payloadBytes``. Exact for this plan.
    public let estimatedFileSize: Int64
    /// Header of the archive that will be written.
    public let outputHeader: PMTilesHeader

    let prefix: Data
    /// Unique payload copies sorted by source offset.
    let copies: [ContentCopy]
}

/// One unique payload: where it lives in the source and where it goes in the output tile data section.
struct ContentCopy: Hashable, Sendable {
    let sourceOffset: UInt64
    let length: UInt64
    let outputOffset: UInt64
}

/// A coalesced source read covering one or more payload copies.
struct FetchBatch: Hashable, Sendable {
    let offset: UInt64
    let length: UInt64
    /// Indices into ``ExtractPlan/copies``.
    let copies: Range<Int>
    let payloadBytes: Int64

    /// Groups copies (sorted by source offset) into reads, merging when the gap is below `maxGap`
    /// and the merged span stays within `maxBytes`.
    static func coalesce(_ copies: [ContentCopy], maxGap: UInt64, maxBytes: UInt64) -> [FetchBatch] {
        var batches: [FetchBatch] = []
        var start = 0
        while start < copies.count {
            let begin = copies[start].sourceOffset
            var end = begin + copies[start].length
            var payload = Int64(copies[start].length)
            var next = start + 1
            while next < copies.count {
                let copy = copies[next]
                let newEnd = max(end, copy.sourceOffset + copy.length)
                guard copy.sourceOffset <= end + maxGap, newEnd - begin <= maxBytes else { break }
                end = newEnd
                payload += Int64(copy.length)
                next += 1
            }
            batches.append(FetchBatch(offset: begin, length: end - begin, copies: start..<next, payloadBytes: payload))
            start = next
        }
        return batches
    }
}
