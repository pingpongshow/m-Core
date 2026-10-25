import CryptoKit
import Foundation
import SQLite3

/// Converts a vector MBTiles database into a clustered PMTiles v3 archive, so imported MBTiles render like any
/// other offline area.
///
/// MBTiles is SQLite: `tiles(zoom_level, tile_column, tile_row, tile_data)` with TMS rows (y = 0 at the south
/// edge) and a `metadata(name, value)` table whose `json` row carries `vector_layers`. Tile payloads are copied
/// verbatim (normally gzip-compressed MVT) and identical payloads are stored once.
public enum MBTilesConverter {
    /// Converts `source` to a PMTiles file at `output` (replacing it). Runs synchronously; call off the main actor.
    public static func convert(_ source: URL, to output: URL) throws {
        let database = try MBTilesDatabase(url: source)
        let metadata = try database.metadata()
        let format = metadata["format"]?.lowercased() ?? ""
        guard format == "pbf" || format == "mvt" else {
            throw OfflineMapImportError.notVectorTiles(format.isEmpty ? "unknown" : format.uppercased())
        }
        let tiles = try database.tileAddresses()
        guard let first = tiles.first, let last = tiles.last else { throw OfflineMapImportError.empty }

        // Payloads go to a scratch file in tile ID order, then follow the directories in the output.
        let fileManager = FileManager.default
        let dataURL = output.deletingLastPathComponent().appending(path: ".\(output.lastPathComponent).\(UUID().uuidString).data")
        guard fileManager.createFile(atPath: dataURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: dataURL.path])
        }
        defer { try? fileManager.removeItem(at: dataURL) }
        let written = try writePayloads(tiles, from: database, to: dataURL)

        var template = PMTilesHeader()
        template.isClustered = true
        template.internalCompression = .none
        template.tileCompression = written.compression
        template.tileType = .mvt
        template.minZoom = UInt8(first.coordinate.z)
        template.maxZoom = UInt8(tiles.map(\.coordinate.z).max() ?? last.coordinate.z)
        let bounds = OfflineMapArchive.bounds(fromMetadata: metadata["bounds"]) ?? coveredBounds(tiles)
        template.bounds = bounds
        let zooms = Int(template.minZoom)...Int(template.maxZoom)
        template.centerZoom = UInt8(PMTilesExtractor.centerZoom(for: bounds, in: zooms))
        template.centerLongitudeE7 = PMTilesHeader.e7(bounds.center.longitude)
        template.centerLatitudeE7 = PMTilesHeader.e7(bounds.center.latitude)
        template.tileDataLength = written.length
        template.addressedTileCount = UInt64(tiles.count)
        template.tileEntryCount = UInt64(written.entries.count)
        template.tileContentCount = UInt64(written.contentCount)

        let json = outputMetadata(metadata, bounds: bounds, zooms: zooms)
        let layout = try PMTilesArchiveBuilder.layout(entries: written.entries, metadata: json, template: template)
        try writeArchive(prefix: layout.prefix, dataURL: dataURL, to: output)
    }

    struct TileAddress {
        let tileID: UInt64
        let coordinate: TileCoordinate
        /// The row as stored (TMS).
        let row: Int
    }

    private struct WrittenPayloads {
        var entries: [PMTilesEntry] = []
        var length: UInt64 = 0
        var contentCount = 0
        var compression: PMTilesCompression = .unknown
    }

    private static func writePayloads(_ tiles: [TileAddress], from database: MBTilesDatabase, to dataURL: URL) throws -> WrittenPayloads {
        let handle = try FileHandle(forWritingTo: dataURL)
        defer { try? handle.close() }
        var result = WrittenPayloads()
        var offsets: [SHA256Digest: (offset: UInt64, length: UInt32)] = [:]
        let statement = try database.prepare(
            "SELECT tile_data FROM tiles WHERE zoom_level = ?1 AND tile_column = ?2 AND tile_row = ?3"
        )
        for (index, tile) in tiles.enumerated() {
            if index.isMultiple(of: 1_024) { try Task.checkCancellation() }
            guard let payload = try statement.blob(binding: [tile.coordinate.z, tile.coordinate.x, tile.row]), !payload.isEmpty else {
                continue
            }
            guard payload.count <= Int(UInt32.max) else { throw OfflineMapImportError.invalidArchive("oversized tile") }
            if result.compression == .unknown {
                result.compression = payload.starts(with: [0x1F, 0x8B]) ? .gzip : .none
            }
            let digest = SHA256.hash(data: payload)
            let location: (offset: UInt64, length: UInt32)
            if let existing = offsets[digest] {
                location = existing
            } else {
                location = (result.length, UInt32(payload.count))
                offsets[digest] = location
                try handle.write(contentsOf: payload)
                result.length += UInt64(payload.count)
                result.contentCount += 1
            }
            if let previous = result.entries.last, previous.offset == location.offset,
               previous.tileID + UInt64(previous.runLength) == tile.tileID, previous.runLength < UInt32.max {
                result.entries[result.entries.count - 1].runLength += 1
            } else {
                result.entries.append(PMTilesEntry(tileID: tile.tileID, offset: location.offset, length: location.length, runLength: 1))
            }
        }
        guard !result.entries.isEmpty else { throw OfflineMapImportError.empty }
        return result
    }

    private static func writeArchive(prefix: Data, dataURL: URL, to output: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: output.path) { try fileManager.removeItem(at: output) }
        guard fileManager.createFile(atPath: output.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: output.path])
        }
        do {
            let writer = try FileHandle(forWritingTo: output)
            defer { try? writer.close() }
            let reader = try FileHandle(forReadingFrom: dataURL)
            defer { try? reader.close() }
            try writer.write(contentsOf: prefix)
            while let chunk = try reader.read(upToCount: 4 << 20), !chunk.isEmpty {
                try Task.checkCancellation()
                try writer.write(contentsOf: chunk)
            }
        } catch {
            try? fileManager.removeItem(at: output)
            throw error
        }
    }

    /// Bounds of the tiles at the highest zoom, for databases without a `bounds` row.
    private static func coveredBounds(_ tiles: [TileAddress]) -> GeoBounds {
        let top = tiles.map(\.coordinate.z).max() ?? 0
        let deepest = tiles.filter { $0.coordinate.z == top }
        let side = Double(1 << top)
        func longitude(_ x: Int) -> Double { Double(x) / side * 360 - 180 }
        func latitude(_ y: Int) -> Double { atan(sinh(.pi * (1 - 2 * Double(y) / side))) * 180 / .pi }
        let xs = deepest.map(\.coordinate.x)
        let ys = deepest.map(\.coordinate.y)
        return GeoBounds(
            minLongitude: longitude(xs.min() ?? 0), minLatitude: latitude((ys.max() ?? 0) + 1),
            maxLongitude: longitude((xs.max() ?? 0) + 1), maxLatitude: latitude(ys.min() ?? 0)
        ).normalized
    }

    /// TileJSON-style metadata: the database's `json` row (with `vector_layers`) plus its descriptive rows.
    static func outputMetadata(_ metadata: [String: String], bounds: GeoBounds, zooms: ClosedRange<Int>) -> Data {
        var object = metadata["json"].flatMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] } ?? [:]
        for key in ["name", "description", "attribution", "version", "type"] {
            if let value = metadata[key] { object[key] = value }
        }
        object["format"] = "pbf"
        object["bounds"] = [bounds.minLongitude, bounds.minLatitude, bounds.maxLongitude, bounds.maxLatitude]
        object["minzoom"] = zooms.lowerBound
        object["maxzoom"] = zooms.upperBound
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}

// MARK: SQLite

/// A read-only MBTiles database.
final class MBTilesDatabase {
    private var handle: OpaquePointer?

    init(url: URL) throws {
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "can't open"
            sqlite3_close(handle)
            handle = nil
            throw OfflineMapImportError.invalidArchive(message)
        }
    }

    deinit {
        sqlite3_close(handle)
    }

    func prepare(_ sql: String) throws -> MBTilesStatement {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw OfflineMapImportError.invalidArchive(errorMessage)
        }
        return MBTilesStatement(statement: statement, database: self)
    }

    var errorMessage: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "no database"
    }

    /// The `metadata` table as name → value.
    func metadata() throws -> [String: String] {
        let statement = try prepare("SELECT name, value FROM metadata")
        var result: [String: String] = [:]
        while try statement.step() {
            if let name = statement.text(0), let value = statement.text(1) { result[name] = value }
        }
        return result
    }

    /// Every tile's address, sorted by PMTiles tile ID without duplicates.
    func tileAddresses() throws -> [MBTilesConverter.TileAddress] {
        let statement = try prepare("SELECT zoom_level, tile_column, tile_row FROM tiles")
        var tiles: [MBTilesConverter.TileAddress] = []
        while try statement.step() {
            let zoom = statement.int(0)
            let column = statement.int(1)
            let row = statement.int(2)
            // Zoom 26 already means 4.5 quadrillion tiles; anything beyond is a damaged row.
            guard (0...26).contains(zoom), (0..<(1 << zoom)).contains(column), (0..<(1 << zoom)).contains(row) else {
                throw OfflineMapImportError.invalidArchive("tile \(zoom)/\(column)/\(row) is outside the grid")
            }
            let coordinate = TileCoordinate(z: zoom, x: column, y: (1 << zoom) - 1 - row)
            tiles.append(MBTilesConverter.TileAddress(tileID: coordinate.tileID, coordinate: coordinate, row: row))
        }
        tiles.sort { $0.tileID < $1.tileID }
        var unique: [MBTilesConverter.TileAddress] = []
        unique.reserveCapacity(tiles.count)
        for tile in tiles where unique.last?.tileID != tile.tileID { unique.append(tile) }
        return unique
    }
}

/// A prepared statement; finalized on deinit.
final class MBTilesStatement {
    private let statement: OpaquePointer
    private let database: MBTilesDatabase

    init(statement: OpaquePointer, database: MBTilesDatabase) {
        self.statement = statement
        self.database = database
    }

    deinit {
        sqlite3_finalize(statement)
    }

    /// Advances to the next row; false when done.
    func step() throws -> Bool {
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw OfflineMapImportError.invalidArchive(database.errorMessage)
        }
    }

    func int(_ column: Int32) -> Int {
        Int(sqlite3_column_int64(statement, column))
    }

    func text(_ column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
    }

    /// Binds integer parameters, steps once and returns column 0 as bytes (nil when there's no row).
    func blob(binding values: [Int]) throws -> Data? {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        for (index, value) in values.enumerated() {
            sqlite3_bind_int64(statement, Int32(index + 1), sqlite3_int64(value))
        }
        guard try step() else { return nil }
        let count = Int(sqlite3_column_bytes(statement, 0))
        guard count > 0, let bytes = sqlite3_column_blob(statement, 0) else { return Data() }
        return Data(bytes: bytes, count: count)
    }
}
