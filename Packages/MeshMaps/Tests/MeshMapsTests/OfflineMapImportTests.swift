import Foundation
import SQLite3
import Testing
@testable import MeshMaps

/// Files/AirDrop import of PMTiles and MBTiles.
@MainActor
struct OfflineMapImportTests {
    static let protomapsMetadata = Data(#"""
        {"name":"city","vector_layers":[{"id":"earth"},{"id":"roads"},{"id":"places"},{"id":"boundaries"},{"id":"water"}]}
        """#.utf8)

    private func makeStore(_ directory: TemporaryDirectory) -> OfflineMapStore {
        let client = FakeHTTPClient { request in (Data(), FakeHTTPClient.response(request.url, status: 404)) }
        return OfflineMapStore(
            baseDirectory: directory.url.appending(path: "Maps", directoryHint: .isDirectory),
            locator: ProtomapsBuildLocator(client: client)
        )
    }

    /// A z0–4 world archive whose header bounds cover only part of it.
    private func writePMTiles(
        _ url: URL, metadata: Data = protomapsMetadata, tileType: PMTilesTileType = .mvt
    ) throws {
        let tiles = SyntheticArchive.worldTiles(zooms: 0...4)
        try SyntheticArchive.write(tiles, to: url, metadata: metadata, tileType: tileType)
        // Narrow the header bounds so the import has to use them.
        var data = try Data(contentsOf: url)
        var header = try PMTilesHeader(data: data)
        header.bounds = GeoBounds(minLongitude: 5, minLatitude: 45, maxLongitude: 10, maxLatitude: 48)
        data.replaceSubrange(0..<PMTilesHeader.length, with: header.serialized())
        try data.write(to: url)
    }

    @Test func importsPMTilesWithHeaderBounds() async throws {
        let directory = try TemporaryDirectory()
        let source = directory.file("Zurich Area.pmtiles")
        try writePMTiles(source)
        let store = makeStore(directory)

        let result = try await store.importArchive(at: source)
        #expect(result.warnings.isEmpty)
        #expect(result.area.name == "Zurich Area")
        #expect(result.area.importedFrom == "Zurich Area.pmtiles")
        #expect(!result.area.canRefresh)
        #expect(result.area.bounds == GeoBounds(minLongitude: 5, minLatitude: 45, maxLongitude: 10, maxLatitude: 48))
        #expect(result.area.detail == .standard)
        #expect(store.areas == [result.area])
        // The source is copied, not moved, and the copy is byte-identical.
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try Data(contentsOf: store.fileURL(for: result.area)) == Data(contentsOf: source))
        #expect(try store.fileURL(for: result.area).resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        await #expect(throws: OfflineMapStoreError.cannotRefreshImported) { try await store.refresh(result.area.id) }
    }

    @Test func warnsWhenProtomapsLayersAreMissing() async throws {
        let directory = try TemporaryDirectory()
        let source = directory.file("other.pmtiles")
        try writePMTiles(source, metadata: SyntheticArchive.metadata)
        let result = try await makeStore(directory).importArchive(at: source, name: "Other schema")
        #expect(result.area.name == "Other schema")
        #expect(result.warnings == [.missingLayers(["roads", "places", "boundaries"])])
    }

    @Test func rejectsRasterAndUnknownFiles() async throws {
        let directory = try TemporaryDirectory()
        let store = makeStore(directory)
        let raster = directory.file("satellite.pmtiles")
        try writePMTiles(raster, tileType: .png)
        await #expect(throws: OfflineMapImportError.notVectorTiles("PNG")) { try await store.importArchive(at: raster) }

        let text = directory.file("notes.pmtiles")
        try Data("hello, not a map".utf8).write(to: text)
        await #expect(throws: OfflineMapImportError.unrecognizedFormat) { try await store.importArchive(at: text) }

        let truncated = directory.file("cut.pmtiles")
        try Data(try Data(contentsOf: raster).prefix(60)).write(to: truncated)
        await #expect(throws: OfflineMapImportError.self) { try await store.importArchive(at: truncated) }

        #expect(store.areas.isEmpty)
        // No partial copies are left behind.
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.baseDirectory.path).filter { $0 != "areas.json" }.isEmpty)
    }

    // MARK: MBTiles

    /// Writes an MBTiles database of `tiles` (XYZ coordinates; stored with TMS rows).
    private func writeMBTiles(_ url: URL, tiles: [SyntheticTile], metadata: [String: String]) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else { throw MBTilesTestError.sqlite }
        defer { sqlite3_close(database) }
        func exec(_ sql: String) throws {
            guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw MBTilesTestError.sqlite }
        }
        try exec("CREATE TABLE metadata (name TEXT, value TEXT)")
        try exec("CREATE TABLE tiles (zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER, tile_data BLOB)")
        try exec("CREATE UNIQUE INDEX tile_index ON tiles (zoom_level, tile_column, tile_row)")
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var statement: OpaquePointer?
        sqlite3_prepare_v2(database, "INSERT INTO metadata VALUES (?1, ?2)", -1, &statement, nil)
        for (name, value) in metadata {
            sqlite3_bind_text(statement, 1, name, -1, transient)
            sqlite3_bind_text(statement, 2, value, -1, transient)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw MBTilesTestError.sqlite }
            sqlite3_reset(statement)
        }
        sqlite3_finalize(statement)
        try exec("BEGIN")
        sqlite3_prepare_v2(database, "INSERT INTO tiles VALUES (?1, ?2, ?3, ?4)", -1, &statement, nil)
        for tile in tiles {
            // swiftlint:disable:next force_unwrapping
            let coordinate = TileCoordinate(tileID: tile.id)!
            sqlite3_bind_int(statement, 1, Int32(coordinate.z))
            sqlite3_bind_int(statement, 2, Int32(coordinate.x))
            sqlite3_bind_int(statement, 3, Int32((1 << coordinate.z) - 1 - coordinate.y))
            _ = tile.data.withUnsafeBytes { sqlite3_bind_blob(statement, 4, $0.baseAddress, Int32($0.count), transient) }
            guard sqlite3_step(statement) == SQLITE_DONE else { throw MBTilesTestError.sqlite }
            sqlite3_reset(statement)
        }
        sqlite3_finalize(statement)
        try exec("COMMIT")
    }

    private enum MBTilesTestError: Error {
        case sqlite
    }

    private static let vectorMetadata: [String: String] = [
        "name": "Test city",
        "format": "pbf",
        "bounds": "-10.5,40.25,2.5,50.75",
        "attribution": "© OpenStreetMap",
        "json": #"{"vector_layers":[{"id":"roads"},{"id":"places"},{"id":"boundaries"}]}"#,
    ]

    @Test func convertsMBTilesToPMTiles() async throws {
        let directory = try TemporaryDirectory()
        let tiles = SyntheticArchive.worldTiles(zooms: 0...4) { TestGzip.compress(SyntheticArchive.payload(for: $0)) }
        let source = directory.file("city.mbtiles")
        try writeMBTiles(source, tiles: tiles, metadata: Self.vectorMetadata)
        let output = directory.file("city.pmtiles")
        try MBTilesConverter.convert(source, to: output)

        let reader = try await PMTilesReader(fetcher: FileRangeFetcher(fileURL: output))
        #expect(reader.header.tileType == .mvt)
        #expect(reader.header.tileCompression == .gzip)
        #expect(reader.header.isClustered)
        #expect(reader.header.minZoom == 0 && reader.header.maxZoom == 4)
        #expect(reader.header.addressedTileCount == UInt64(tiles.count))
        // Identical "ocean" payloads are stored once.
        #expect(reader.header.tileContentCount < UInt64(tiles.count))
        #expect(reader.header.bounds == GeoBounds(minLongitude: -10.5, minLatitude: 40.25, maxLongitude: 2.5, maxLatitude: 50.75))
        // TMS rows were flipped back to XYZ: every tile reads back under its own coordinate.
        for tile in tiles {
            #expect(try await reader.tileData(for: tile.id) == tile.data)
        }
        let metadata = try #require(try JSONSerialization.jsonObject(with: reader.metadata) as? [String: Any])
        #expect(metadata["name"] as? String == "Test city")
        #expect(OfflineMapArchive.vectorLayers(in: metadata) == ["roads", "places", "boundaries"])
    }

    @Test func importsMBTilesThroughTheStore() async throws {
        let directory = try TemporaryDirectory()
        let tiles = SyntheticArchive.worldTiles(zooms: 0...3)
        let source = directory.file("Region.mbtiles")
        var metadata = Self.vectorMetadata
        metadata["bounds"] = nil
        metadata["json"] = #"{"vector_layers":[{"id":"transportation"},{"id":"place"}]}"#
        try writeMBTiles(source, tiles: tiles.filter { TileCoordinate(tileID: $0.id)?.x == 0 || $0.id < 5 }, metadata: metadata)
        let store = makeStore(directory)

        let result = try await store.importArchive(at: source)
        #expect(result.area.name == "Region")
        // OpenMapTiles-style layers won't draw with the Protomaps style.
        #expect(result.warnings == [.missingLayers(["roads", "places", "boundaries"])])
        // Without a bounds row, bounds come from the deepest zoom's tiles: the western column at z3.
        #expect(result.area.bounds.minLongitude == -180)
        #expect(result.area.bounds.maxLongitude == -135)
        let reader = try await PMTilesReader(fetcher: FileRangeFetcher(fileURL: store.fileURL(for: result.area)))
        #expect(reader.header.tileCompression == PMTilesCompression.none)
        let sample = TileCoordinate(z: 3, x: 0, y: 5)
        #expect(try await reader.tileData(for: sample.tileID) == SyntheticArchive.payload(for: sample))
    }

    @Test func rejectsRasterAndEmptyMBTiles() async throws {
        let directory = try TemporaryDirectory()
        let store = makeStore(directory)
        let raster = directory.file("aerial.mbtiles")
        var metadata = Self.vectorMetadata
        metadata["format"] = "png"
        try writeMBTiles(raster, tiles: SyntheticArchive.worldTiles(zooms: 0...1), metadata: metadata)
        await #expect(throws: OfflineMapImportError.notVectorTiles("PNG")) { try await store.importArchive(at: raster) }

        let empty = directory.file("empty.mbtiles")
        try writeMBTiles(empty, tiles: [], metadata: Self.vectorMetadata)
        await #expect(throws: OfflineMapImportError.empty) { try await store.importArchive(at: empty) }
        #expect(store.areas.isEmpty)
    }
}
