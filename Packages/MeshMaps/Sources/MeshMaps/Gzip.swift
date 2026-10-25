import Compression
import Foundation

/// gzip (RFC 1952) decoding on top of the Compression framework's raw DEFLATE decoder.
public enum Gzip {
    private static let flagHeaderCRC: UInt8 = 0x02
    private static let flagExtra: UInt8 = 0x04
    private static let flagName: UInt8 = 0x08
    private static let flagComment: UInt8 = 0x10

    /// Decompresses a single-member gzip stream, verifying the CRC32 and length trailer.
    ///
    /// The Compression framework does not report where a DEFLATE stream ends, so the trailer is taken from the
    /// last eight bytes. Concatenated members (never produced for PMTiles directories) fail the CRC check.
    public static func decompress(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        let start = try skipHeader(bytes)
        guard bytes.count - start >= 8 else { throw PMTilesError.invalidGzip("missing trailer") }
        let trailerStart = bytes.count - 8
        let output = try inflateRaw(Array(bytes[start..<trailerStart]))
        var trailer = ByteReader(bytes, position: trailerStart)
        let crc = UInt32(bitPattern: try trailer.readInt32())
        let size = UInt32(bitPattern: try trailer.readInt32())
        guard CRC32.checksum(output) == crc else { throw PMTilesError.invalidGzip("CRC mismatch") }
        guard UInt32(truncatingIfNeeded: output.count) == size else { throw PMTilesError.invalidGzip("length mismatch") }
        return Data(output)
    }

    /// Returns the offset of the DEFLATE stream following the gzip header (RFC 1952 §2.3).
    private static func skipHeader(_ bytes: [UInt8]) throws -> Int {
        guard bytes.count >= 18, bytes[0] == 0x1F, bytes[1] == 0x8B else {
            throw PMTilesError.invalidGzip("bad magic")
        }
        guard bytes[2] == 8 else { throw PMTilesError.invalidGzip("unsupported method") }
        let flags = bytes[3]
        var position = 10
        if flags & flagExtra != 0 {
            guard position + 2 <= bytes.count else { throw PMTilesError.invalidGzip("truncated FEXTRA") }
            let extraLength = Int(bytes[position]) | (Int(bytes[position + 1]) << 8)
            position += 2 + extraLength
        }
        for flag in [flagName, flagComment] where flags & flag != 0 {
            guard let terminator = bytes[min(position, bytes.count)...].firstIndex(of: 0) else {
                throw PMTilesError.invalidGzip("unterminated header string")
            }
            position = terminator + 1
        }
        if flags & flagHeaderCRC != 0 { position += 2 }
        guard position + 8 < bytes.count else { throw PMTilesError.invalidGzip("truncated header") }
        return position
    }

    /// Inflates a raw DEFLATE stream (COMPRESSION_ZLIB is headerless DEFLATE).
    static func inflateRaw(_ bytes: [UInt8]) throws -> [UInt8] {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw PMTilesError.invalidGzip("decoder init failed")
        }
        defer { compression_stream_destroy(stream) }

        let chunkSize = 64 * 1024
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { destination.deallocate() }
        let finalize = Int32(bitPattern: COMPRESSION_STREAM_FINALIZE.rawValue)

        return try bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress, !buffer.isEmpty else { throw PMTilesError.invalidGzip("empty stream") }
            stream.pointee.src_ptr = base
            stream.pointee.src_size = buffer.count
            var output: [UInt8] = []
            while true {
                stream.pointee.dst_ptr = destination
                stream.pointee.dst_size = chunkSize
                let sourceBefore = stream.pointee.src_size
                let status = compression_stream_process(stream, finalize)
                let produced = chunkSize - stream.pointee.dst_size
                output.append(contentsOf: UnsafeBufferPointer(start: destination, count: produced))
                switch status {
                case COMPRESSION_STATUS_END:
                    return output
                case COMPRESSION_STATUS_OK:
                    guard produced > 0 || stream.pointee.src_size != sourceBefore else {
                        throw PMTilesError.invalidGzip("truncated stream")
                    }
                default:
                    throw PMTilesError.invalidGzip("corrupt stream")
                }
            }
        }
    }
}

/// CRC-32 (IEEE 802.3, reflected polynomial 0xEDB88320) as used by gzip.
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    static func checksum(_ bytes: some Sequence<UInt8>) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

extension PMTilesCompression {
    /// Decodes directory or metadata bytes compressed with this internal compression (none or gzip).
    func decompress(_ data: Data) throws -> Data {
        switch self {
        case .none: data
        case .gzip: try Gzip.decompress(data)
        default: throw PMTilesError.unsupportedCompression(self)
        }
    }
}
