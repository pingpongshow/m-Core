import Foundation

/// Byte-stream framing used over TCP (and USB serial): a direction marker, a little-endian
/// 16-bit length, then the frame. App → radio uses `<`, radio → app uses `>`.
public enum SerialFraming {
    public static let toRadioMarker: UInt8 = 0x3C   // "<"
    public static let fromRadioMarker: UInt8 = 0x3E // ">"

    /// Wraps an outgoing frame.
    public static func encode(_ frame: Data) throws -> Data {
        guard frame.count <= MeshCoreProtocol.maxFrameSize else {
            throw TransportError.frameTooLarge(frame.count)
        }
        return Data([toRadioMarker, UInt8(frame.count & 0xFF), UInt8(frame.count >> 8)]) + frame
    }

    /// Splits an incoming byte stream into frames, resynchronising on junk or oversized headers.
    public struct Deframer: Sendable {
        private var buffer: [UInt8] = []
        private let maxFrameLength: Int

        /// Lengths above `maxFrameLength` are treated as noise. The firmware never sends more than 176 bytes.
        public init(maxFrameLength: Int = 512) {
            self.maxFrameLength = maxFrameLength
        }

        /// Adds received bytes and returns any frames now complete.
        public mutating func append(_ bytes: Data) -> [Data] {
            buffer += bytes
            var frames: [Data] = []
            while true {
                guard let start = buffer.firstIndex(of: SerialFraming.fromRadioMarker) else {
                    buffer.removeAll()
                    break
                }
                if start > 0 { buffer.removeFirst(start) }
                guard buffer.count >= 3 else { break }
                let length = Int(buffer[1]) | Int(buffer[2]) << 8
                guard length > 0, length <= maxFrameLength else {
                    buffer.removeFirst() // not a real header; look for the next marker
                    continue
                }
                guard buffer.count >= 3 + length else { break }
                frames.append(Data(buffer[3..<3 + length]))
                buffer.removeFirst(3 + length)
            }
            return frames
        }
    }
}
