import Foundation
import Testing
@testable import MeshMaps

struct GzipTests {
    let sample = Data((0..<50_000).map { UInt8(truncatingIfNeeded: $0 * 7 % 251) })

    @Test func crc32KnownValue() {
        #expect(CRC32.checksum(Array("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test func decodesPlainMember() throws {
        #expect(try Gzip.decompress(TestGzip.compress(sample)) == sample)
    }

    @Test func skipsOptionalHeaderFields() throws {
        let options = TestGzip.Options(extra: [1, 2, 3, 4, 5], name: "root.dir", comment: "made by tests", headerCRC: true)
        #expect(try Gzip.decompress(TestGzip.compress(sample, options: options)) == sample)
    }

    @Test func concatenatedMembersFailLoudly() {
        // Multi-member streams are unsupported; they must not decode to partial data silently.
        var data = TestGzip.compress(Data("hello ".utf8))
        data.append(TestGzip.compress(Data("world".utf8)))
        #expect(throws: PMTilesError.self) { try Gzip.decompress(data) }
    }

    @Test func rejectsCorruption() {
        var corrupted = TestGzip.compress(sample)
        corrupted[corrupted.count - 6] ^= 0xFF
        #expect(throws: PMTilesError.invalidGzip("CRC mismatch")) { try Gzip.decompress(corrupted) }
        #expect(throws: (any Error).self) { try Gzip.decompress(Data([0x1F, 0x8B, 8, 0])) }
        #expect(throws: (any Error).self) { try Gzip.decompress(TestGzip.compress(sample).dropLast(4)) }
    }

    @Test func internalCompressionDispatch() throws {
        #expect(try PMTilesCompression.none.decompress(sample) == sample)
        #expect(try PMTilesCompression.gzip.decompress(TestGzip.compress(sample)) == sample)
        #expect(throws: PMTilesError.unsupportedCompression(.brotli)) { try PMTilesCompression.brotli.decompress(sample) }
    }
}
