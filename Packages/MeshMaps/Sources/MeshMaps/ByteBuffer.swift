/// Little-endian byte writer used for headers and directories.
struct ByteWriter {
    private(set) var bytes: [UInt8] = []

    init(capacity: Int = 0) {
        bytes.reserveCapacity(capacity)
    }

    mutating func append(_ byte: UInt8) {
        bytes.append(byte)
    }

    mutating func append(contentsOf other: some Sequence<UInt8>) {
        bytes.append(contentsOf: other)
    }

    mutating func appendUInt64(_ value: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    mutating func appendInt32(_ value: Int32) {
        let raw = UInt32(bitPattern: value)
        for shift in stride(from: 0, to: 32, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: raw >> UInt32(shift)))
        }
    }

    mutating func appendVarint(_ value: UInt64) {
        Varint.append(value, to: &bytes)
    }
}

/// Little-endian byte reader over an array; throws ``PMTilesError/truncatedData`` on overrun.
struct ByteReader {
    let bytes: [UInt8]
    var position: Int

    init(_ bytes: [UInt8], position: Int = 0) {
        self.bytes = bytes
        self.position = position
    }

    var remaining: Int { bytes.count - position }

    mutating func readUInt8() throws -> UInt8 {
        guard position < bytes.count else { throw PMTilesError.truncatedData }
        defer { position += 1 }
        return bytes[position]
    }

    mutating func readUInt64() throws -> UInt64 {
        guard remaining >= 8 else { throw PMTilesError.truncatedData }
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(bytes[position + index]) << UInt64(index * 8)
        }
        position += 8
        return value
    }

    mutating func readInt32() throws -> Int32 {
        guard remaining >= 4 else { throw PMTilesError.truncatedData }
        var value: UInt32 = 0
        for index in 0..<4 {
            value |= UInt32(bytes[position + index]) << UInt32(index * 8)
        }
        position += 4
        return Int32(bitPattern: value)
    }

    mutating func readVarint() throws -> UInt64 {
        try Varint.read(from: bytes, at: &position)
    }
}

/// Protobuf-style unsigned LEB128 varints, as used by PMTiles directories.
public enum Varint {
    /// Appends `value` as a varint (1–10 bytes).
    public static func append(_ value: UInt64, to bytes: inout [UInt8]) {
        var remaining = value
        while remaining >= 0x80 {
            bytes.append(UInt8(truncatingIfNeeded: remaining) | 0x80)
            remaining >>= 7
        }
        bytes.append(UInt8(remaining))
    }

    /// Encodes `value` as a standalone varint.
    public static func encode(_ value: UInt64) -> [UInt8] {
        var bytes: [UInt8] = []
        append(value, to: &bytes)
        return bytes
    }

    /// Reads a varint starting at `index`, advancing it past the last byte read.
    public static func read(from bytes: [UInt8], at index: inout Int) throws -> UInt64 {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard index < bytes.count else { throw PMTilesError.truncatedData }
            let byte = bytes[index]
            index += 1
            let payload = UInt64(byte & 0x7F)
            if shift == 63, payload > 1 { throw PMTilesError.malformedVarint }
            value |= payload << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
            if shift > 63 { throw PMTilesError.malformedVarint }
        }
    }
}
