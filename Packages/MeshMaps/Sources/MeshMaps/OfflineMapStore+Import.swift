import Foundation

// Storage cap and Files/AirDrop import.
extension OfflineMapStore {
    /// Bytes counted against ``storageCap``: saved areas plus the expected size of unfinished downloads.
    /// - Parameters:
    ///   - replacing: An area about to be replaced (a refresh), whose current size no longer counts.
    ///   - excludingDownload: An unfinished download being re-checked, which shouldn't count against itself.
    public func committedBytes(replacing: UUID? = nil, excludingDownload: UUID? = nil) -> Int64 {
        let saved = areas.filter { $0.id != replacing }.reduce(Int64(0)) { $0 + $1.fileSize }
        let pending = pausedDownloads.filter { $0.id != excludingDownload }.reduce(Int64(0)) { $0 + $1.estimatedFileSize }
        return saved + pending
    }

    /// Bytes still allowed under ``storageCap`` (nil when unlimited).
    public func remainingCapacity(replacing: UUID? = nil, excludingDownload: UUID? = nil) -> Int64? {
        storageCap.map { $0 - committedBytes(replacing: replacing, excludingDownload: excludingDownload) }
    }

    /// Throws ``OfflineMapStoreError/storageCapExceeded(required:available:)`` when a file of `estimatedFileSize`
    /// bytes wouldn't fit under ``storageCap``.
    public func checkStorageCap(estimatedFileSize: Int64, replacing: UUID? = nil, excludingDownload: UUID? = nil) throws {
        guard let available = remainingCapacity(replacing: replacing, excludingDownload: excludingDownload),
              estimatedFileSize > available else { return }
        throw OfflineMapStoreError.storageCapExceeded(required: estimatedFileSize, available: available)
    }

    // MARK: Importing

    /// Imports a PMTiles archive or MBTiles database (MBTiles is converted to PMTiles) as a new area, using the
    /// archive's own bounds. Only vector tiles are accepted; archives without the Protomaps layers import with a
    /// warning. The source file is copied, never moved.
    public func importArchive(at sourceURL: URL, name: String? = nil) async throws -> OfflineMapImportResult {
        let fallbackName = sourceURL.deletingPathExtension().lastPathComponent
        let trimmed = try Self.validated(name ?? fallbackName)
        try prepareDirectory()
        let id = UUID()
        let output = baseDirectory.appending(path: ".import-\(id.uuidString).partial")
        let info: OfflineMapArchiveInfo
        do {
            info = try await OfflineMapArchive.prepare(source: sourceURL, output: output)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        var area = OfflineMapArea(
            id: id, name: trimmed, bounds: info.bounds, detail: info.detail, importedFrom: sourceURL.lastPathComponent
        )
        let destination = fileURL(for: area)
        do {
            try FileManager.default.moveItem(at: output, to: destination)
            try register(&area)
        } catch {
            try? FileManager.default.removeItem(at: output)
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return OfflineMapImportResult(area: area, warnings: info.warnings)
    }
}
