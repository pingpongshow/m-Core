import Foundation

/// One directory entry: a tile run (`runLength > 0`) or a leaf directory pointer (`runLength == 0`).
///
/// `offset` is relative to the tile data section for tiles and to the leaf directory section for leaves.
public struct PMTilesEntry: Hashable, Sendable {
    public var tileID: UInt64
    public var offset: UInt64
    public var length: UInt32
    public var runLength: UInt32

    public init(tileID: UInt64, offset: UInt64, length: UInt32, runLength: UInt32) {
        self.tileID = tileID
        self.offset = offset
        self.length = length
        self.runLength = runLength
    }

    /// True when this entry points at a leaf directory.
    public var isLeaf: Bool { runLength == 0 }
}

/// Directory encoding (spec §4.2/§4.3): count, delta tile IDs, run lengths, lengths, offsets — all varints.
public enum PMTilesDirectory {
    /// Encodes entries (sorted by tile ID) without compression.
    public static func encode(_ entries: [PMTilesEntry]) -> Data {
        var writer = ByteWriter(capacity: entries.count * 5 + 4)
        writer.appendVarint(UInt64(entries.count))
        var lastID: UInt64 = 0
        for entry in entries {
            writer.appendVarint(entry.tileID - lastID)
            lastID = entry.tileID
        }
        for entry in entries { writer.appendVarint(UInt64(entry.runLength)) }
        for entry in entries { writer.appendVarint(UInt64(entry.length)) }
        var nextByte: UInt64 = 0
        for (index, entry) in entries.enumerated() {
            if index > 0, entry.offset == nextByte {
                writer.appendVarint(0)
            } else {
                writer.appendVarint(entry.offset + 1)
            }
            nextByte = entry.offset + UInt64(entry.length)
        }
        return Data(writer.bytes)
    }

    /// Decodes an uncompressed directory.
    public static func decode(_ data: Data) throws -> [PMTilesEntry] {
        var reader = ByteReader([UInt8](data))
        let rawCount = try reader.readVarint()
        // Every entry needs at least four bytes, which also guards against absurd allocations.
        guard rawCount > 0, rawCount <= UInt64(reader.remaining / 4) else { throw PMTilesError.malformedDirectory }
        let count = Int(rawCount)
        var entries = [PMTilesEntry](repeating: PMTilesEntry(tileID: 0, offset: 0, length: 0, runLength: 0), count: count)
        var lastID: UInt64 = 0
        for index in 0..<count {
            let (sum, overflow) = lastID.addingReportingOverflow(try reader.readVarint())
            guard !overflow else { throw PMTilesError.malformedDirectory }
            lastID = sum
            entries[index].tileID = sum
        }
        for index in 0..<count { entries[index].runLength = try readUInt32(&reader) }
        for index in 0..<count {
            let length = try readUInt32(&reader)
            guard length > 0 else { throw PMTilesError.malformedDirectory }
            entries[index].length = length
        }
        for index in 0..<count {
            let value = try reader.readVarint()
            if value == 0, index > 0 {
                entries[index].offset = entries[index - 1].offset + UInt64(entries[index - 1].length)
            } else {
                guard value > 0 else { throw PMTilesError.malformedDirectory }
                entries[index].offset = value - 1
            }
        }
        return entries
    }

    /// Finds the entry addressing `tileID`: a tile run containing it, or the leaf directory that may contain it.
    public static func find(_ tileID: UInt64, in entries: [PMTilesEntry]) -> PMTilesEntry? {
        var low = 0
        var high = entries.count - 1
        var match = -1
        while low <= high {
            let mid = (low + high) / 2
            if entries[mid].tileID <= tileID {
                match = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        guard match >= 0 else { return nil }
        let entry = entries[match]
        if entry.isLeaf || tileID - entry.tileID < UInt64(entry.runLength) { return entry }
        return nil
    }

    private static func readUInt32(_ reader: inout ByteReader) throws -> UInt32 {
        let value = try reader.readVarint()
        guard let narrowed = UInt32(exactly: value) else { throw PMTilesError.malformedDirectory }
        return narrowed
    }
}
