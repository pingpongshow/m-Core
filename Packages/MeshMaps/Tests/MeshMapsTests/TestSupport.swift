import Compression
import Foundation
import Synchronization
@testable import MeshMaps

// MARK: gzip encoding (tests build gzip-compressed directories without shelling out)

enum TestGzip {
    struct Options {
        var extra: [UInt8]?
        var name: String?
        var comment: String?
        var headerCRC = false
    }

    static func deflateRaw(_ data: Data) -> [UInt8] {
        let source = [UInt8](data)
        let capacity = source.count + source.count / 2 + 1024
        var destination = [UInt8](repeating: 0, count: capacity)
        let written = compression_encode_buffer(&destination, capacity, source, source.count, nil, COMPRESSION_ZLIB)
        precondition(written > 0, "deflate failed")
        return Array(destination[0..<written])
    }

    static func compress(_ data: Data, options: Options = Options()) -> Data {
        var bytes: [UInt8] = [0x1F, 0x8B, 0x08, 0, 0, 0, 0, 0, 0, 0xFF]
        var flags: UInt8 = 0
        if let extra = options.extra {
            flags |= 0x04
            bytes += [UInt8(extra.count & 0xFF), UInt8(extra.count >> 8)] + extra
        }
        if let name = options.name {
            flags |= 0x08
            bytes += Array(name.utf8) + [0]
        }
        if let comment = options.comment {
            flags |= 0x10
            bytes += Array(comment.utf8) + [0]
        }
        bytes[3] = flags
        if options.headerCRC {
            bytes[3] |= 0x02
            let crc = CRC32.checksum(bytes)
            bytes += [UInt8(crc & 0xFF), UInt8((crc >> 8) & 0xFF)]
        }
        bytes += deflateRaw(data)
        bytes += littleEndian(CRC32.checksum(data))
        bytes += littleEndian(UInt32(truncatingIfNeeded: data.count))
        return Data(bytes)
    }

    static func littleEndian(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8((value >> UInt32($0 * 8)) & 0xFF) }
    }
}

// MARK: Synthetic source archives

/// A tile in a synthetic archive.
struct SyntheticTile {
    let id: UInt64
    let data: Data
}

enum SyntheticArchive {
    static let metadata = Data(#"{"name":"synthetic","vector_layers":[{"id":"water","fields":{}}]}"#.utf8)

    /// Payload used by default: unique per tile, except "ocean" tiles that share one blob.
    static func payload(for coordinate: TileCoordinate) -> Data {
        if coordinate.z >= 2, (coordinate.x + coordinate.y) % 3 == 0 {
            return Data("ocean-blob".utf8)
        }
        return Data("tile \(coordinate.z)/\(coordinate.x)/\(coordinate.y) #".utf8)
    }

    /// Every tile from `zooms` over the whole world.
    static func worldTiles(zooms: ClosedRange<Int>, payload: (TileCoordinate) -> Data = payload(for:)) -> [SyntheticTile] {
        var tiles: [SyntheticTile] = []
        for zoom in zooms {
            let first = TileCoordinate.firstTileID(atZoom: zoom)
            for id in first..<first + (UInt64(1) << UInt64(2 * zoom)) {
                // swiftlint:disable:next force_unwrapping
                tiles.append(SyntheticTile(id: id, data: payload(TileCoordinate(tileID: id)!)))
            }
        }
        return tiles
    }

    /// Writes a clustered, de-duplicated archive (consecutive identical tiles become runs).
    @discardableResult
    static func write(
        _ tiles: [SyntheticTile],
        to url: URL,
        internalCompression: PMTilesCompression = .gzip,
        leafEntryCount: Int? = nil,
        metadata: Data = metadata,
        tileType: PMTilesTileType = .mvt
    ) throws -> PMTilesHeader {
        let sorted = tiles.sorted { $0.id < $1.id }
        var entries: [PMTilesEntry] = []
        var tileData = Data()
        var offsets: [Data: UInt64] = [:]
        for tile in sorted {
            let offset: UInt64
            if let existing = offsets[tile.data] {
                offset = existing
            } else {
                offset = UInt64(tileData.count)
                offsets[tile.data] = offset
                tileData.append(tile.data)
            }
            if let last = entries.last, last.offset == offset, last.tileID + UInt64(last.runLength) == tile.id {
                entries[entries.count - 1].runLength += 1
            } else {
                entries.append(PMTilesEntry(tileID: tile.id, offset: offset, length: UInt32(tile.data.count), runLength: 1))
            }
        }
        var template = PMTilesHeader()
        template.isClustered = true
        template.internalCompression = internalCompression
        template.tileCompression = .gzip
        template.tileType = tileType
        // swiftlint:disable force_unwrapping
        template.minZoom = UInt8(TileCoordinate(tileID: sorted.first!.id)!.z)
        template.maxZoom = UInt8(TileCoordinate(tileID: sorted.last!.id)!.z)
        // swiftlint:enable force_unwrapping
        template.bounds = .world
        template.tileDataLength = UInt64(tileData.count)
        template.addressedTileCount = UInt64(sorted.count)
        template.tileEntryCount = UInt64(entries.count)
        template.tileContentCount = UInt64(offsets.count)
        let compress: (Data) -> Data = internalCompression == .gzip ? { TestGzip.compress($0) } : { $0 }
        let layout = try PMTilesArchiveBuilder.layout(
            entries: entries, metadata: metadata, template: template, compress: compress, forcedLeafEntryCount: leafEntryCount
        )
        var file = layout.prefix
        file.append(tileData)
        try file.write(to: url)
        return layout.header
    }
}

// MARK: Files

/// A unique temporary directory removed on deinit.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "MeshMapsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func file(_ name: String) -> URL {
        url.appending(path: name)
    }

    func contents() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }
}

// MARK: Fetchers and HTTP fakes

/// Counts requests made through a wrapped fetcher.
actor CountingFetcher: RangeFetcher {
    let base: any RangeFetcher
    private(set) var requests: [(offset: UInt64, length: UInt64)] = []

    init(_ base: any RangeFetcher) {
        self.base = base
    }

    func fetch(offset: UInt64, length: UInt64) async throws -> Data {
        requests.append((offset, length))
        return try await base.fetch(offset: offset, length: length)
    }
}

/// Delays (or fails) reads at or beyond `threshold`, i.e. tile data reads.
struct GatedFetcher: RangeFetcher {
    enum Behavior: Sendable {
        case sleep
        case fail
        /// Waits, then fails a cancelled read the way URLSession does: with URLError(.cancelled).
        case sleepThenURLCancelled
    }

    struct InjectedFailure: Error {}

    let base: any RangeFetcher
    let threshold: UInt64
    let behavior: Behavior

    func fetch(offset: UInt64, length: UInt64) async throws -> Data {
        if offset >= threshold {
            switch behavior {
            case .sleep: try await Task.sleep(for: .seconds(30))
            case .fail: throw InjectedFailure()
            case .sleepThenURLCancelled:
                do { try await Task.sleep(for: .seconds(30)) } catch { throw URLError(.cancelled) }
            }
        }
        return try await base.fetch(offset: offset, length: length)
    }
}

/// Lets a set number of tile data reads (at or beyond `threshold`) through, then fails or stalls the rest,
/// logging every tile data read's offset.
struct ScriptedFetcher: RangeFetcher {
    enum Exhausted: Sendable {
        case fail
        case stall
    }

    let base: any RangeFetcher
    let threshold: UInt64
    /// Tile reads still allowed; nil for unlimited.
    let budget: LockedBox<Int?>
    let log: LockedBox<[UInt64]>
    var exhausted: Exhausted = .fail

    func fetch(offset: UInt64, length: UInt64) async throws -> Data {
        guard offset >= threshold else { return try await base.fetch(offset: offset, length: length) }
        var allowed = true
        budget.mutate { remaining in
            guard let left = remaining else { return }
            if left <= 0 { allowed = false } else { remaining = left - 1 }
        }
        if !allowed {
            switch exhausted {
            case .fail: throw URLError(.networkConnectionLost)
            case .stall: try await Task.sleep(for: .seconds(30))
            }
        }
        log.mutate { $0.append(offset) }
        return try await base.fetch(offset: offset, length: length)
    }
}

struct FakeHTTPClient: HTTPClient {
    let handler: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await handler(request)
    }

    static func response(_ url: URL?, status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        // swiftlint:disable:next force_unwrapping
        HTTPURLResponse(url: url ?? URL(string: "https://example.invalid")!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    /// Serves `fileURL` at `servedURL`: HEAD → 200, ranged GET → 206 with Content-Range; other URLs → 404.
    static func serving(_ fileURL: URL, at servedURL: URL, etag: String = "\"v1\"") -> FakeHTTPClient {
        FakeHTTPClient { request in
            guard request.url == servedURL else { return (Data(), response(request.url, status: 404)) }
            let bytes = try Data(contentsOf: fileURL)
            if request.httpMethod == "HEAD" {
                return (Data(), response(request.url, status: 200, headers: ["Content-Length": "\(bytes.count)", "ETag": etag]))
            }
            guard let range = request.value(forHTTPHeaderField: "Range"),
                  let parts = Optional(range.dropFirst("bytes=".count).split(separator: "-")),
                  parts.count == 2, let start = Int(parts[0]), let end = Int(parts[1]) else {
                return (bytes, response(request.url, status: 200, headers: ["ETag": etag]))
            }
            let upper = min(end + 1, bytes.count)
            let body = bytes.subdata(in: min(start, upper)..<upper)
            let headers = ["ETag": etag, "Content-Range": "bytes \(start)-\(upper - 1)/\(bytes.count)"]
            return (body, response(request.url, status: 206, headers: headers))
        }
    }
}

extension Date {
    /// UTC date from components.
    static func utc(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
        // swiftlint:disable:next force_unwrapping
        ProtomapsBuildLocator.calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }
}

/// A Sendable mutable box for recording values from concurrent closures.
final class LockedBox<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>

    init(_ value: Value) {
        mutex = Mutex(value)
    }

    var value: Value {
        get { mutex.withLock { $0 } }
        set { mutex.withLock { $0 = newValue } }
    }

    func mutate(_ body: (inout Value) -> Void) {
        mutex.withLock { body(&$0) }
    }
}
