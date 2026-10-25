import Foundation
import Testing
@testable import MeshMaps

@MainActor
struct OfflineMapStoreTests {
    let bounds = GeoBounds(minLongitude: -40, minLatitude: 10, maxLongitude: -5, maxLatitude: 50)
    let now = Date.utc(2026, 10, 24, hour: 9)

    /// A store whose network is a fake server publishing `source` as yesterday's build.
    private func makeStore(base: URL, source: URL? = nil) -> OfflineMapStore {
        // swiftlint:disable:next force_unwrapping
        let buildURL = URL(string: "https://build.protomaps.com/20261023.pmtiles")!
        let client: FakeHTTPClient = source.map { FakeHTTPClient.serving($0, at: buildURL) }
            ?? FakeHTTPClient { request in (Data(), FakeHTTPClient.response(request.url, status: 404)) }
        return OfflineMapStore(
            baseDirectory: base,
            locator: ProtomapsBuildLocator(client: client, now: { [now] in now }),
            makeFetcher: { build in HTTPRangeFetcher(url: build.url, client: client, expectedETag: build.etag) }
        )
    }

    private func excludedFromBackup(_ url: URL) throws -> Bool {
        try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true
    }

    @Test func addListRenameDeleteAndPersist() throws {
        let directory = try TemporaryDirectory()
        let base = directory.url.appending(path: "Maps", directoryHint: .isDirectory)
        let store = makeStore(base: base)
        #expect(store.areas.isEmpty && store.totalBytes == 0)

        let first = directory.file("a.pmtiles")
        try Data(repeating: 1, count: 1_000).write(to: first)
        let second = directory.file("b.pmtiles")
        try Data(repeating: 2, count: 500).write(to: second)
        let areaA = try store.add(fileAt: first, name: "  Coast ", bounds: bounds, detail: .standard)
        let areaB = try store.add(fileAt: second, name: "Hills", bounds: bounds, detail: .high, sourceBuildDate: now)

        #expect(store.areas.map(\.name) == ["Coast", "Hills"])
        #expect(store.totalBytes == 1_500)
        #expect(store.mapFileURLs == [areaA, areaB].map { base.appending(path: "\($0.id.uuidString).pmtiles") })
        #expect(store.mapSourceURLs.allSatisfy { $0.hasPrefix("pmtiles://file:///") })
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(try excludedFromBackup(store.fileURL(for: areaA)))
        #expect(try excludedFromBackup(base))
        #expect(FileManager.default.fileExists(atPath: base.appending(path: "areas.json").path))

        try store.rename(areaA.id, to: "North Coast")
        #expect(throws: OfflineMapStoreError.invalidName) { try store.rename(areaA.id, to: "   ") }
        #expect(throws: OfflineMapStoreError.areaNotFound) { try store.rename(UUID(), to: "x") }

        let reopened = makeStore(base: base)
        #expect(reopened.areas.map(\.id) == [areaA.id, areaB.id])
        #expect(reopened.areas.map(\.name) == ["North Coast", "Hills"])
        #expect(reopened.areas[1].detail == .high)
        #expect(reopened.areas[1].bounds == bounds)
        #expect(reopened.totalBytes == 1_500)

        try reopened.delete(areaA.id)
        #expect(reopened.areas.map(\.id) == [areaB.id])
        #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: areaA).path))
        #expect(throws: OfflineMapStoreError.areaNotFound) { try reopened.delete(areaA.id) }
        #expect(makeStore(base: base).totalBytes == 500)
    }

    @Test func reloadDropsAreasWhoseFilesVanished() throws {
        let directory = try TemporaryDirectory()
        let store = makeStore(base: directory.url)
        let file = directory.file("x.pmtiles.tmp")
        try Data(count: 10).write(to: file)
        let area = try store.add(fileAt: file, name: "Gone", bounds: bounds, detail: .standard)
        try FileManager.default.removeItem(at: store.fileURL(for: area))
        store.reload()
        #expect(store.areas.isEmpty)
    }

    @Test func downloadLocatesPlansExtractsAndRegisters() async throws {
        let directory = try TemporaryDirectory()
        let source = directory.file("planet.pmtiles")
        let tiles = SyntheticArchive.worldTiles(zooms: 0...6)
        try SyntheticArchive.write(tiles, to: source, leafEntryCount: 200)
        let base = directory.url.appending(path: "Maps", directoryHint: .isDirectory)
        let store = makeStore(base: base, source: source)

        let area = try await store.download(name: "Atlantic", bounds: bounds, detail: .standard)
        #expect(store.activeDownload == nil)
        #expect(store.areas == [area])
        #expect(area.sourceBuildDate == Date.utc(2026, 10, 23))
        #expect(area.detail == .standard)
        let fileURL = store.fileURL(for: area)
        #expect(area.fileSize == (try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value)
        #expect(try excludedFromBackup(fileURL))
        #expect(try FileManager.default.contentsOfDirectory(atPath: base.path).sorted() == ["\(area.id.uuidString).pmtiles", "areas.json"])

        // Source only goes to z6, so the standard z0–13 request is clamped.
        let reader = try await PMTilesReader(fetcher: FileRangeFetcher(fileURL: fileURL))
        #expect(reader.header.minZoom == 0 && reader.header.maxZoom == 6)
        let sample = TileCoordinate(z: 6, x: WebMercator.tileX(longitude: -20, zoom: 6), y: WebMercator.tileY(latitude: 30, zoom: 6))
        #expect(try await reader.tileData(for: sample.tileID) == SyntheticArchive.payload(for: sample))
    }

    @Test func estimateMatchesDownloadWithoutWritingFiles() async throws {
        let directory = try TemporaryDirectory()
        let source = directory.file("planet.pmtiles")
        try SyntheticArchive.write(SyntheticArchive.worldTiles(zooms: 0...6), to: source, leafEntryCount: 200)
        let base = directory.url.appending(path: "Maps", directoryHint: .isDirectory)
        let store = makeStore(base: base, source: source)

        let plan = try await store.estimate(bounds: bounds, detail: .standard)
        #expect(plan.tileCount > 0)
        #expect(!FileManager.default.fileExists(atPath: base.path))
        let again = try await store.estimate(bounds: bounds, detail: .standard)
        #expect(again.estimatedFileSize == plan.estimatedFileSize)

        let area = try await store.download(name: "Atlantic", bounds: bounds, detail: .standard)
        #expect(area.fileSize == plan.estimatedFileSize)
    }

    @Test func downloadFailureLeavesNoFiles() async throws {
        let directory = try TemporaryDirectory()
        let base = directory.url.appending(path: "Maps", directoryHint: .isDirectory)
        let store = makeStore(base: base)
        await #expect(throws: ProtomapsBuildLocatorError.noBuildFound) {
            try await store.download(name: "Nowhere", bounds: bounds, detail: .standard)
        }
        #expect(store.activeDownload == nil)
        #expect(store.areas.isEmpty)
        await #expect(throws: OfflineMapStoreError.invalidName) { try await store.download(name: "", bounds: bounds, detail: .high) }
    }

    @Test(arguments: [GatedFetcher.Behavior.sleep, .sleepThenURLCancelled])
    func cancellingDownloadCleansUp(_ behavior: GatedFetcher.Behavior) async throws {
        let directory = try TemporaryDirectory()
        let source = directory.file("planet.pmtiles")
        try SyntheticArchive.write(SyntheticArchive.worldTiles(zooms: 0...6), to: source)
        let header = try await PMTilesReader(fetcher: FileRangeFetcher(fileURL: source)).header
        let base = directory.url.appending(path: "Maps", directoryHint: .isDirectory)
        // swiftlint:disable:next force_unwrapping
        let buildURL = URL(string: "https://build.protomaps.com/20261024.pmtiles")!
        let client = FakeHTTPClient.serving(source, at: buildURL)
        let store = OfflineMapStore(
            baseDirectory: base,
            locator: ProtomapsBuildLocator(client: client, now: { [now] in now }),
            makeFetcher: { _ in
                GatedFetcher(base: FileRangeFetcher(fileURL: source), threshold: header.tileDataOffset, behavior: behavior)
            }
        )
        let task = Task { try await store.download(name: "Slow", bounds: bounds, detail: .standard) }
        for _ in 0..<1_000 where store.activeDownload?.phase != .downloading {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(store.activeDownload?.phase == .downloading)
        #expect(store.activeDownload?.bytesTotal ?? 0 > 0)
        #expect(store.activeDownload?.estimatedFileSize ?? 0 > store.activeDownload?.bytesTotal ?? 0)
        store.cancelDownload()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(store.activeDownload == nil)
        #expect(store.areas.isEmpty)
        // Cancelled, not kept as a paused download with an error.
        #expect(store.pausedDownloads.isEmpty)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        #expect(leftovers.isEmpty)
    }
}
