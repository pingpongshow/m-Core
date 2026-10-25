import Foundation
import Observation

/// Manages downloaded offline map areas: `<id>.pmtiles` files (with `<id>.png` thumbnails) plus an `areas.json`
/// manifest in one directory (default `Application Support/Maps/`). Unfinished downloads live in its `Downloads/`
/// folder as a partial file and a JSON job, so they can be resumed after a pause, an error or a relaunch.
/// Everything is excluded from backup.
@MainActor
@Observable
public final class OfflineMapStore {
    public static let manifestFileName = "areas.json"
    static let downloadsDirectoryName = "Downloads"

    /// Default storage directory: `Application Support/Maps/`.
    nonisolated public static var defaultBaseDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Maps", directoryHint: .isDirectory)
    }

    nonisolated public let baseDirectory: URL
    /// Areas sorted by creation date (oldest first).
    public internal(set) var areas: [OfflineMapArea] = []
    /// The running download, if any.
    public internal(set) var activeDownload: OfflineMapDownload?
    /// Downloads that stopped before finishing, newest first. They survive relaunches.
    public internal(set) var pausedDownloads: [PausedOfflineMapDownload] = []
    /// Bumped whenever a thumbnail is written or removed, so views reload images.
    public internal(set) var thumbnailRevision = 0
    /// Limit on the bytes offline maps may use (saved areas plus unfinished downloads); nil means unlimited.
    public var storageCap: Int64?
    /// A PMTiles URL used instead of the Protomaps builds (debug testing only; the app never sets it in release).
    /// A URL ending in `.pmtiles` is one archive; anything else is a base URL with dated builds.
    public var customSourceURL: URL? {
        didSet {
            if customSourceURL != oldValue { estimator = nil }
        }
    }

    @ObservationIgnored var estimator: PMTilesExtractor?
    @ObservationIgnored let locator: ProtomapsBuildLocator
    @ObservationIgnored let makeFetcher: @Sendable (ProtomapsBuild) -> any RangeFetcher
    @ObservationIgnored let extractorConfiguration: PMTilesExtractor.Configuration
    @ObservationIgnored var downloadTask: Task<OfflineMapArea, any Error>?
    /// The job the running download works on; checkpoints update it.
    @ObservationIgnored var runningJob: DownloadJob?
    @ObservationIgnored var pauseRequested = false

    /// - Parameters:
    ///   - baseDirectory: Storage directory (inject a temp directory in tests).
    ///   - locator: Finds the newest Protomaps build.
    ///   - makeFetcher: Builds the range fetcher for a located build.
    public init(
        baseDirectory: URL = OfflineMapStore.defaultBaseDirectory,
        locator: ProtomapsBuildLocator = ProtomapsBuildLocator(sourceList: ProtomapsSourceListLoader()),
        extractorConfiguration: PMTilesExtractor.Configuration = PMTilesExtractor.Configuration(),
        makeFetcher: @escaping @Sendable (ProtomapsBuild) -> any RangeFetcher = { build in
            HTTPRangeFetcher(url: build.url, expectedETag: build.etag)
        }
    ) {
        self.baseDirectory = baseDirectory
        self.locator = locator
        self.extractorConfiguration = extractorConfiguration
        self.makeFetcher = makeFetcher
        reload()
    }

    // MARK: Queries

    /// Bytes used by all area files.
    public var totalBytes: Int64 { areas.reduce(0) { $0 + $1.fileSize } }

    /// Local file URLs of every area, for the map to load.
    public var mapFileURLs: [URL] { areas.map(fileURL(for:)) }

    /// `pmtiles://file://…` source URLs for MapLibre.
    public var mapSourceURLs: [String] { mapFileURLs.map { "pmtiles://" + $0.absoluteString } }

    public func fileURL(for area: OfflineMapArea) -> URL {
        baseDirectory.appending(path: area.fileName, directoryHint: .notDirectory)
    }

    /// `pmtiles://file://…` source URL of one area.
    public func mapSourceURL(for area: OfflineMapArea) -> String {
        "pmtiles://" + fileURL(for: area).absoluteString
    }

    /// Where the area's thumbnail image is (or would be) saved.
    public func thumbnailURL(for area: OfflineMapArea) -> URL {
        baseDirectory.appending(path: area.thumbnailFileName, directoryHint: .notDirectory)
    }

    public func hasThumbnail(_ area: OfflineMapArea) -> Bool {
        FileManager.default.fileExists(atPath: thumbnailURL(for: area).path)
    }

    // MARK: Mutations

    /// Re-reads the manifest, dropping areas whose files are gone and refreshing file sizes, and lists
    /// unfinished downloads.
    public func reload() {
        reloadPausedDownloads()
        let manifestURL = baseDirectory.appending(path: Self.manifestFileName)
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? Self.decoder.decode(Manifest.self, from: data) else {
            areas = []
            return
        }
        var refreshed: [OfflineMapArea] = []
        for var area in manifest.areas {
            guard let size = Self.fileSize(at: fileURL(for: area)) else { continue }
            area.fileSize = size
            refreshed.append(area)
        }
        areas = refreshed.sorted { $0.createdAt < $1.createdAt }
        if refreshed != manifest.areas { try? saveManifest() }
    }

    /// Moves an existing PMTiles file into the store as a new area.
    @discardableResult
    public func add(
        fileAt sourceURL: URL, name: String, bounds: GeoBounds, detail: OfflineMapDetail, sourceBuildDate: Date? = nil
    ) throws -> OfflineMapArea {
        let trimmed = try Self.validated(name)
        try prepareDirectory()
        var area = OfflineMapArea(name: trimmed, bounds: bounds.normalized, detail: detail, sourceBuildDate: sourceBuildDate)
        let destination = fileURL(for: area)
        try FileManager.default.moveItem(at: sourceURL, to: destination)
        try register(&area)
        return area
    }

    public func rename(_ id: UUID, to name: String) throws {
        let trimmed = try Self.validated(name)
        guard let index = areas.firstIndex(where: { $0.id == id }) else { throw OfflineMapStoreError.areaNotFound }
        areas[index].name = trimmed
        try saveManifest()
    }

    /// Deletes the area's file, thumbnail and manifest entry.
    public func delete(_ id: UUID) throws {
        guard let index = areas.firstIndex(where: { $0.id == id }) else { throw OfflineMapStoreError.areaNotFound }
        let url = fileURL(for: areas[index])
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        removeThumbnail(for: areas[index])
        areas.remove(at: index)
        try saveManifest()
    }

    /// Saves a PNG thumbnail for an area (excluded from backup).
    public func saveThumbnail(_ png: Data, for id: UUID) throws {
        guard let area = areas.first(where: { $0.id == id }) else { throw OfflineMapStoreError.areaNotFound }
        var url = thumbnailURL(for: area)
        try png.write(to: url, options: .atomic)
        try Self.excludeFromBackup(&url)
        thumbnailRevision += 1
    }

    func removeThumbnail(for area: OfflineMapArea) {
        let url = thumbnailURL(for: area)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
        thumbnailRevision += 1
    }

    // MARK: Persistence

    func register(_ area: inout OfflineMapArea) throws {
        var url = fileURL(for: area)
        try Self.excludeFromBackup(&url)
        area.fileSize = Self.fileSize(at: url) ?? 0
        areas.append(area)
        do {
            try saveManifest()
        } catch {
            areas.removeAll { $0.id == area.id }
            throw error
        }
    }

    func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        var directory = baseDirectory
        try Self.excludeFromBackup(&directory)
    }

    func saveManifest() throws {
        try prepareDirectory()
        var url = baseDirectory.appending(path: Self.manifestFileName)
        try Self.encoder.encode(Manifest(areas: areas)).write(to: url, options: .atomic)
        try Self.excludeFromBackup(&url)
    }

    static func validated(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OfflineMapStoreError.invalidName }
        return trimmed
    }

    static func excludeFromBackup(_ url: inout URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    static func fileSize(at url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return nil }
        return size.int64Value
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

private struct Manifest: Codable {
    var version = 1
    var areas: [OfflineMapArea]
}
