import Foundation

/// Why a frame from the radio couldn't be decoded.
public enum FrameDecodingError: Error, Equatable, Sendable {
    case empty
    /// The frame ended before a required field.
    case truncated(code: UInt8, needed: Int, available: Int)
    case invalid(code: UInt8, reason: String)
}

/// Little-endian reader over one frame's bytes.
struct ByteReader {
    private let bytes: [UInt8]
    private let code: UInt8
    private(set) var offset: Int

    init(_ data: Data, code: UInt8, offset: Int = 0) {
        self.bytes = [UInt8](data)
        self.code = code
        self.offset = offset
    }

    var remaining: Int { bytes.count - offset }
    var isAtEnd: Bool { offset >= bytes.count }

    private mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, remaining >= count else {
            throw FrameDecodingError.truncated(code: code, needed: offset + count, available: bytes.count)
        }
        defer { offset += count }
        return bytes[offset..<offset + count]
    }

    mutating func u8() throws -> UInt8 { try take(1).first! }
    mutating func i8() throws -> Int8 { Int8(bitPattern: try u8()) }

    mutating func u16() throws -> UInt16 {
        let b = try take(2)
        return UInt16(b[b.startIndex]) | UInt16(b[b.startIndex + 1]) << 8
    }

    mutating func i16() throws -> Int16 { Int16(bitPattern: try u16()) }

    mutating func u32() throws -> UInt32 {
        let b = try take(4)
        return b.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
    }

    mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }

    mutating func bytes(_ count: Int) throws -> [UInt8] { Array(try take(count)) }

    /// All remaining bytes.
    mutating func rest() -> [UInt8] {
        defer { offset = bytes.count }
        return Array(bytes[min(offset, bytes.count)...])
    }

    /// A fixed-width, NUL-padded UTF-8 field.
    mutating func fixedString(_ count: Int) throws -> String {
        Self.string(from: try bytes(count))
    }

    /// Remaining bytes as UTF-8 text, stopping at the first NUL.
    mutating func restString() -> String {
        Self.string(from: rest())
    }

    static func string(from bytes: [UInt8]) -> String {
        let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
        return String(decoding: bytes[..<end], as: UTF8.self)
    }
}

/// Little-endian writer for command frames.
struct ByteWriter {
    private(set) var bytes: [UInt8] = []

    init(code: UInt8) {
        bytes = [code]
    }

    var data: Data { Data(bytes) }

    mutating func u8(_ value: UInt8) { bytes.append(value) }
    mutating func i8(_ value: Int8) { bytes.append(UInt8(bitPattern: value)) }
    mutating func u16(_ value: UInt16) { bytes += [UInt8(value & 0xFF), UInt8(value >> 8)] }
    mutating func u32(_ value: UInt32) { bytes += (0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) } }
    mutating func i32(_ value: Int32) { u32(UInt32(bitPattern: value)) }
    mutating func append<S: Sequence>(_ more: S) where S.Element == UInt8 { bytes += more }

    /// UTF-8 text with no terminator.
    mutating func text(_ string: String) { bytes += Array(string.utf8) }

    /// A fixed-width field: UTF-8 truncated at a character boundary to `width - 1` bytes, then NUL-padded.
    mutating func fixedString(_ string: String, width: Int) {
        let encoded = Self.truncatedUTF8(string, maxBytes: width - 1)
        bytes += encoded + [UInt8](repeating: 0, count: width - encoded.count)
    }

    /// UTF-8 bytes of `string`, cut at a character boundary so the result is at most `maxBytes` long.
    static func truncatedUTF8(_ string: String, maxBytes: Int) -> [UInt8] {
        var result: [UInt8] = []
        for character in string {
            let encoded = Array(String(character).utf8)
            if result.count + encoded.count > maxBytes { break }
            result += encoded
        }
        return result
    }
}

extension Data {
    /// Hex string of the bytes, lowercase, no separators.
    public var hexString: String { map { String(format: "%02x", $0) }.joined() }

    /// Parses a hex string; whitespace is ignored. Returns nil on odd length or bad digits.
    public init?(hexString: String) {
        let digits = hexString.filter { !$0.isWhitespace }
        guard digits.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(digits.count / 2)
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            guard let byte = UInt8(digits[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
