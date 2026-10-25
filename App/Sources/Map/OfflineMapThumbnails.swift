import MapLibre
import MeshMaps
import UIKit

/// Renders a small preview of each saved offline area with `MLNMapSnapshotter`, using the app's style limited
/// to that area, and saves it next to the area's file. Runs one snapshot at a time.
@MainActor
final class OfflineMapThumbnails {
    static let shared = OfflineMapThumbnails()

    /// Thumbnail size in points (rendered at the screen's scale).
    static let size = CGSize(width: 120, height: 90)

    private var isRunning = false
    /// Areas whose snapshot failed this session, so a broken file isn't retried in a loop.
    private var failed: Set<UUID> = []

    /// Renders thumbnails for every area that lacks one.
    func generateMissing(in store: OfflineMapStore) {
        guard !isRunning else { return }
        let missing = store.areas.filter { !store.hasThumbnail($0) && !failed.contains($0.id) }
        guard !missing.isEmpty else { return }
        isRunning = true
        Task {
            for area in missing {
                guard store.areas.contains(where: { $0.id == area.id }) else { continue }
                if let png = await render(area, store: store) {
                    try? store.saveThumbnail(png, for: area.id)
                } else {
                    failed.insert(area.id)
                }
            }
            isRunning = false
            // Areas added while this pass ran.
            if store.areas.contains(where: { !store.hasThumbnail($0) && !failed.contains($0.id) }) {
                generateMissing(in: store)
            }
        }
    }

    private func render(_ area: OfflineMapArea, store: OfflineMapStore) async -> Data? {
        let sources = [MapStyle.overviewSource].compactMap { $0 } + [store.mapSourceURL(for: area)]
        let style = MapStyle(sources: sources, palette: .light, glyphsDirectory: MapStyle.bundledGlyphs)
        guard let styleURL = try? style.write(named: "mcore-thumbnail-\(area.id.uuidString)") else { return nil }
        defer { try? FileManager.default.removeItem(at: styleURL) }
        let options = MLNMapSnapshotOptions(styleURL: styleURL, camera: MLNMapCamera(), size: Self.size)
        options.coordinateBounds = MLNCoordinateBounds(
            sw: CLLocationCoordinate2D(latitude: area.bounds.minLatitude, longitude: area.bounds.minLongitude),
            ne: CLLocationCoordinate2D(latitude: area.bounds.maxLatitude, longitude: area.bounds.maxLongitude)
        )
        options.scale = UIScreen.main.scale
        options.showsLogo = false
        options.showsAttribution = false
        let snapshotter = MLNMapSnapshotter(options: options)
        let png: Data? = await withCheckedContinuation { continuation in
            snapshotter.start { snapshot, _ in
                continuation.resume(returning: snapshot?.image.pngData())
            }
        }
        withExtendedLifetime(snapshotter) {}
        return png
    }
}

/// Thumbnails decoded once per ``OfflineMapStore/thumbnailRevision``, so the list re-rendering for download progress
/// doesn't read every PNG from disk again.
@MainActor
enum AreaThumbnailCache {
    private static var revision = -1
    private static var images: [UUID: UIImage?] = [:]

    static func image(for area: OfflineMapArea, in store: OfflineMapStore) -> UIImage? {
        if store.thumbnailRevision != revision {
            images = [:]
            revision = store.thumbnailRevision
        }
        if let cached = images[area.id] { return cached }
        let image = UIImage(contentsOfFile: store.thumbnailURL(for: area).path)
        images[area.id] = image
        return image
    }
}
