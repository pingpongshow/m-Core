import Foundation

/// Why a file can't be imported as an offline map.
public enum OfflineMapImportError: Error, Sendable, Equatable, LocalizedError {
    /// Neither a PMTiles archive nor an MBTiles database.
    case unrecognizedFormat
    /// The archive holds raster or other non-vector tiles (the format is named).
    case notVectorTiles(String)
    /// Compression MapLibre can't read (the compression is named).
    case unsupportedCompression(String)
    /// The file is damaged or not laid out as its format requires.
    case invalidArchive(String)
    /// The archive contains no tiles.
    case empty

    public var errorDescription: String? {
        switch self {
        case .unrecognizedFormat: "That isn't a PMTiles or MBTiles map file."
        case .notVectorTiles(let format):
            "That map contains \(format) image tiles. m-Core can only use vector maps, such as Protomaps extracts."
        case .unsupportedCompression(let compression): "That map uses \(compression) compression, which m-Core can't read."
        case .invalidArchive(let reason): "That map file is damaged (\(reason))."
        case .empty: "That map file contains no tiles."
        }
    }
}

/// Something worth telling the user about an imported map that still imported.
public enum OfflineMapImportWarning: Hashable, Sendable {
    /// The archive's `vector_layers` lack these Protomaps layers, so m-Core's style draws little or nothing from it.
    case missingLayers([String])
}

/// What an archive covers, read from its header and metadata.
public struct OfflineMapArchiveInfo: Hashable, Sendable {
    public var bounds: GeoBounds
    public var minZoom: Int
    public var maxZoom: Int
    /// `vector_layers` ids from the metadata.
    public var vectorLayers: [String]
    public var warnings: [OfflineMapImportWarning]

    /// Detail level that best describes the archive's highest zoom.
    public var detail: OfflineMapDetail {
        maxZoom >= OfflineMapDetail.high.zoomRange.upperBound ? .high : .standard
    }
}

/// The outcome of ``OfflineMapStore/importArchive(at:name:)``.
public struct OfflineMapImportResult: Hashable, Sendable {
    public let area: OfflineMapArea
    public let warnings: [OfflineMapImportWarning]
}

/// Validation shared by PMTiles and MBTiles imports.
public enum OfflineMapArchive {
    /// The source layers m-Core's style draws.
    public static let protomapsLayers = ["roads", "places", "boundaries"]

    enum Format {
        case pmtiles
        case mbtiles
    }

    /// Sniffs the file's magic bytes.
    static func format(of url: URL) throws -> Format {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let magic = try handle.read(upToCount: 16) ?? Data()
        if magic.starts(with: Array("PMTiles".utf8)) { return .pmtiles }
        if magic.starts(with: Array("SQLite format 3".utf8) + [0]) { return .mbtiles }
        throw OfflineMapImportError.unrecognizedFormat
    }

    /// Reads and validates a local PMTiles archive: vector (MVT) tiles, compression MapLibre reads, and usable
    /// bounds (the header's, else the metadata's, else the world).
    public static func inspectPMTiles(at url: URL) async throws -> OfflineMapArchiveInfo {
        let reader: PMTilesReader
        do {
            reader = try await PMTilesReader(fetcher: FileRangeFetcher(fileURL: url))
        } catch let error as PMTilesError {
            throw OfflineMapImportError.invalidArchive(String(describing: error))
        }
        let header = reader.header
        switch header.tileType {
        case .mvt: break
        case .png: throw OfflineMapImportError.notVectorTiles("PNG")
        case .jpeg: throw OfflineMapImportError.notVectorTiles("JPEG")
        case .webp: throw OfflineMapImportError.notVectorTiles("WebP")
        case .avif: throw OfflineMapImportError.notVectorTiles("AVIF")
        case .mlt: throw OfflineMapImportError.notVectorTiles("MapLibre Tile")
        default: throw OfflineMapImportError.notVectorTiles("unknown")
        }
        guard [.none, .gzip].contains(header.internalCompression) else {
            throw OfflineMapImportError.unsupportedCompression(header.internalCompression.description)
        }
        guard [.none, .gzip, .unknown].contains(header.tileCompression) else {
            throw OfflineMapImportError.unsupportedCompression(header.tileCompression.description)
        }
        guard header.addressedTileCount > 0 || header.tileDataLength > 0 else { throw OfflineMapImportError.empty }
        let metadata = (try? JSONSerialization.jsonObject(with: reader.metadata)) as? [String: Any] ?? [:]
        let bounds = usableBounds(header.bounds) ?? bounds(fromMetadata: metadata["bounds"]) ?? .world
        return info(bounds: bounds, minZoom: Int(header.minZoom), maxZoom: Int(header.maxZoom), metadata: metadata)
    }

    static func info(bounds: GeoBounds, minZoom: Int, maxZoom: Int, metadata: [String: Any]) -> OfflineMapArchiveInfo {
        let layers = vectorLayers(in: metadata)
        let missing = protomapsLayers.filter { !layers.contains($0) }
        return OfflineMapArchiveInfo(
            bounds: bounds.normalized, minZoom: minZoom, maxZoom: maxZoom, vectorLayers: layers,
            warnings: missing.isEmpty ? [] : [.missingLayers(missing)]
        )
    }

    /// `vector_layers[].id` from TileJSON-style metadata.
    static func vectorLayers(in metadata: [String: Any]) -> [String] {
        guard let layers = metadata["vector_layers"] as? [[String: Any]] else { return [] }
        return layers.compactMap { $0["id"] as? String }
    }

    /// Bounds with positive area inside the world, else nil.
    static func usableBounds(_ bounds: GeoBounds) -> GeoBounds? {
        let box = bounds.normalized
        guard box.maxLongitude > box.minLongitude, box.maxLatitude > box.minLatitude else { return nil }
        return box
    }

    /// Parses `[w, s, e, n]` or `"w,s,e,n"`.
    static func bounds(fromMetadata value: Any?) -> GeoBounds? {
        var numbers: [Double] = []
        if let array = value as? [Any] {
            numbers = array.compactMap { ($0 as? NSNumber)?.doubleValue }
        } else if let text = value as? String {
            numbers = text.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        }
        guard numbers.count == 4 else { return nil }
        return usableBounds(GeoBounds(minLongitude: numbers[0], minLatitude: numbers[1], maxLongitude: numbers[2], maxLatitude: numbers[3]))
    }

    /// Produces a validated PMTiles file at `output` from `source` (copied, or converted from MBTiles).
    static func prepare(source: URL, output: URL) async throws -> OfflineMapArchiveInfo {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: output.path) { try fileManager.removeItem(at: output) }
        switch try format(of: source) {
        case .pmtiles:
            try fileManager.copyItem(at: source, to: output)
        case .mbtiles:
            try MBTilesConverter.convert(source, to: output)
        }
        try Task.checkCancellation()
        return try await inspectPMTiles(at: output)
    }
}
