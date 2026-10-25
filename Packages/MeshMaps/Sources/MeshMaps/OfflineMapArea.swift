import Foundation

/// A downloaded offline map area, persisted in the store's `areas.json` manifest.
public struct OfflineMapArea: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var name: String
    public var bounds: GeoBounds
    public var detail: OfflineMapDetail
    /// UTC day of the Protomaps build the tiles came from, when known.
    public var sourceBuildDate: Date?
    /// Size of the `.pmtiles` file in bytes.
    public var fileSize: Int64
    public var createdAt: Date
    /// Original file name when the area was imported from Files or AirDrop rather than downloaded.
    public var importedFrom: String?

    public init(
        id: UUID = UUID(),
        name: String,
        bounds: GeoBounds,
        detail: OfflineMapDetail,
        sourceBuildDate: Date? = nil,
        fileSize: Int64 = 0,
        createdAt: Date = Date(),
        importedFrom: String? = nil
    ) {
        self.id = id
        self.name = name
        self.bounds = bounds
        self.detail = detail
        self.sourceBuildDate = sourceBuildDate
        self.fileSize = fileSize
        self.createdAt = createdAt
        self.importedFrom = importedFrom
    }

    /// File name inside the store directory.
    public var fileName: String { "\(id.uuidString).pmtiles" }

    /// Thumbnail image file name inside the store directory.
    public var thumbnailFileName: String { "\(id.uuidString).png" }

    /// Only downloaded areas can be re-downloaded from a newer build.
    public var canRefresh: Bool { importedFrom == nil }
}

/// Observable state of the download in progress.
public struct OfflineMapDownload: Hashable, Sendable {
    public enum Phase: Hashable, Sendable {
        case locatingBuild
        case planning
        case downloading
        case finishing
    }

    public let id: UUID
    public let name: String
    /// The saved area this download will replace (a refresh), if any.
    public var replacesAreaID: UUID?
    public var phase: Phase
    /// Tile payload bytes written so far.
    public var bytesDone: Int64
    /// Tile payload bytes to download (known once planning finishes).
    public var bytesTotal: Int64
    /// Expected output file size (known once planning finishes).
    public var estimatedFileSize: Int64

    /// 0…1 progress of the downloading phase.
    public var fractionCompleted: Double {
        bytesTotal > 0 ? min(1, Double(bytesDone) / Double(bytesTotal)) : 0
    }
}

/// A download that stopped before finishing (paused, interrupted or the app closed) and can be resumed
/// with ``OfflineMapStore/resumeDownload(_:)``.
public struct PausedOfflineMapDownload: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let bounds: GeoBounds
    public let detail: OfflineMapDetail
    /// The saved area this download will replace (a refresh), if any.
    public let replacesAreaID: UUID?
    /// Payload bytes already written.
    public let bytesDone: Int64
    /// Payload bytes in total, 0 if planning never finished.
    public let bytesTotal: Int64
    public let estimatedFileSize: Int64
    /// The build being copied, when one was found.
    public let sourceBuildDate: Date?
    public let updatedAt: Date
    /// Why it stopped, when it wasn't paused on purpose.
    public let lastError: String?

    /// 0…1 progress so far.
    public var fractionCompleted: Double {
        bytesTotal > 0 ? min(1, Double(bytesDone) / Double(bytesTotal)) : 0
    }
}

/// Store-level failures.
public enum OfflineMapStoreError: Error, Sendable, Equatable, LocalizedError {
    case downloadInProgress
    case areaNotFound
    case invalidName
    /// ``OfflineMapStore/pauseDownload()`` stopped the download; it is listed in ``OfflineMapStore/pausedDownloads``.
    case downloadPaused
    case downloadNotFound
    /// The area would take the offline maps past the storage limit.
    case storageCapExceeded(required: Int64, available: Int64)
    /// A refresh found no build newer than the area's.
    case alreadyUpToDate
    /// Imported areas have no Protomaps build to refresh from.
    case cannotRefreshImported

    public var errorDescription: String? {
        switch self {
        case .downloadInProgress: "Another map download is running."
        case .areaNotFound: "That area no longer exists."
        case .invalidName: "Give the area a name."
        case .downloadPaused: "The download is paused."
        case .downloadNotFound: "That download no longer exists."
        case let .storageCapExceeded(required, available):
            "This needs \(Self.bytes(required)) but your offline maps limit leaves \(Self.bytes(max(0, available))). "
                + "Raise the limit or delete an area."
        case .alreadyUpToDate: "This area already has the newest map data."
        case .cannotRefreshImported: "Imported maps can't be refreshed."
        }
    }

    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
