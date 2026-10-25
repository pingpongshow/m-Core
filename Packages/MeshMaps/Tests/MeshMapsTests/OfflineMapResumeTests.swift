import Foundation
import Testing
@testable import MeshMaps

/// Pause, resume, refresh and the storage cap.
@MainActor
struct OfflineMapResumeTests {
    let bounds = GeoBounds(minLongitude: -40, minLatitude: 10, maxLongitude: -5, maxLatitude: 50)
    /// One payload per batch, one request at a time, so batch counts are exact.
    let configuration = PMTilesExtractor.Configuration(maxGapBytes: 0, maxBatchBytes: 1, maxConcurrentRequests: 1)

    /// A planet build on a fake server, plus knobs to interrupt tile reads.
    final class Fixture {
        let directory: TemporaryDirectory
        let source: URL
        let base: URL
        let header: PMTilesHeader
        let budget = LockedBox<Int?>(nil)
        let log = LockedBox<[UInt64]>([])

        init() async throws {
            directory = try TemporaryDirectory()
            source = directory.file("planet.pmtiles")
            try SyntheticArchive.write(SyntheticArchive.worldTiles(zooms: 0...6), to: source, leafEntryCount: 200)
            base = directory.url.appending(path: "Maps", directoryHint: .isDirectory)
            header = try await PMTilesReader(fetcher: FileRangeFetcher(fileURL: source)).header
        }

        // swiftlint:disable:next force_unwrapping
        static func buildURL(_ day: String) -> URL { URL(string: "https://build.protomaps.com/\(day).pmtiles")! }
    }

    private func makeStore(
        _ fixture: Fixture, today: Date = Date.utc(2026, 10, 24, hour: 9), buildDay: String = "20261023",
        etag: String = "\"v1\"", exhausted: ScriptedFetcher.Exhausted = .fail
    ) -> OfflineMapStore {
        let client = FakeHTTPClient.serving(fixture.source, at: Fixture.buildURL(buildDay), etag: etag)
        let threshold = fixture.header.tileDataOffset
        return OfflineMapStore(
            baseDirectory: fixture.base,
            locator: ProtomapsBuildLocator(client: client, now: { today }),
            extractorConfiguration: configuration,
            makeFetcher: { [budget = fixture.budget, log = fixture.log] build in
                ScriptedFetcher(
                    base: HTTPRangeFetcher(url: build.url, client: client, expectedETag: build.etag),
                    threshold: threshold, budget: budget, log: log, exhausted: exhausted
                )
            }
        )
    }

    /// The archive a single uninterrupted extraction produces.
    private func referenceArchive(_ fixture: Fixture) async throws -> (data: Data, batches: Int) {
        let reader = try await PMTilesReader(fetcher: FileRangeFetcher(fileURL: fixture.source))
        let extractor = PMTilesExtractor(reader: reader, configuration: configuration)
        let plan = try await extractor.plan(bounds: bounds, zoomRange: OfflineMapDetail.standard.zoomRange)
        let url = fixture.directory.file("reference.pmtiles")
        try await extractor.extract(plan: plan, to: url)
        return (try Data(contentsOf: url), extractor.batchCount(for: plan))
    }

    @Test func interruptedDownloadResumesWithoutRefetching() async throws {
        let fixture = try await Fixture()
        let reference = try await referenceArchive(fixture)
        let store = makeStore(fixture)
        fixture.budget.value = 5

        await #expect(throws: URLError.self) { try await store.download(name: "Atlantic", bounds: bounds, detail: .standard) }
        #expect(store.activeDownload == nil)
        #expect(store.areas.isEmpty)
        let paused = try #require(store.pausedDownloads.first)
        #expect(store.pausedDownloads.count == 1)
        #expect(paused.name == "Atlantic")
        #expect(paused.bytesDone > 0 && paused.bytesDone < paused.bytesTotal)
        #expect(paused.lastError == "The connection was lost.")
        #expect(paused.sourceBuildDate == Date.utc(2026, 10, 23))

        fixture.budget.value = nil
        fixture.log.value = []
        let area = try await store.resumeDownload(paused.id)
        #expect(area.id == paused.id && area.name == "Atlantic")
        #expect(fixture.log.value.count == reference.batches - 5)
        #expect(try Data(contentsOf: store.fileURL(for: area)) == reference.data)
        #expect(store.pausedDownloads.isEmpty)
        let contents = try FileManager.default.contentsOfDirectory(atPath: fixture.base.path).sorted()
        #expect(contents == ["\(area.id.uuidString).pmtiles", "areas.json"])
    }

    @Test func pausedDownloadSurvivesRelaunchAndResumes() async throws {
        let fixture = try await Fixture()
        let reference = try await referenceArchive(fixture)
        let store = makeStore(fixture, exhausted: .stall)
        fixture.budget.value = 3

        let task = Task { try await store.download(name: "Paused", bounds: bounds, detail: .standard) }
        for _ in 0..<2_000 where fixture.log.value.count < 3 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(store.activeDownload?.phase == .downloading)
        store.pauseDownload()
        await #expect(throws: OfflineMapStoreError.downloadPaused) { try await task.value }
        #expect(store.activeDownload == nil)
        let paused = try #require(store.pausedDownloads.first)
        #expect(paused.lastError == nil)

        // A fresh store over the same directory is what the app sees after a relaunch.
        fixture.budget.value = nil
        fixture.log.value = []
        let relaunched = makeStore(fixture)
        #expect(relaunched.pausedDownloads.map(\.id) == [paused.id])
        #expect(relaunched.pausedDownloads.first?.bytesDone == paused.bytesDone)
        #expect(relaunched.pausedDownloads.first?.bytesDone ?? 0 > 0)
        let area = try await relaunched.resumeDownload(paused.id)
        #expect(fixture.log.value.count == reference.batches - 3)
        #expect(try Data(contentsOf: relaunched.fileURL(for: area)) == reference.data)
        #expect(relaunched.pausedDownloads.isEmpty)
    }

    @Test func changedBuildRestartsCleanly() async throws {
        let fixture = try await Fixture()
        let reference = try await referenceArchive(fixture)
        fixture.budget.value = 4
        await #expect(throws: URLError.self) {
            try await makeStore(fixture).download(name: "Moved", bounds: bounds, detail: .standard)
        }

        fixture.budget.value = nil
        fixture.log.value = []
        let republished = makeStore(fixture, etag: "\"v2\"")
        let paused = try #require(republished.pausedDownloads.first)
        let area = try await republished.resumeDownload(paused.id)
        // Nothing written against the old ETag is trusted: every batch is fetched again.
        #expect(fixture.log.value.count == reference.batches)
        #expect(try Data(contentsOf: republished.fileURL(for: area)) == reference.data)
    }

    @Test func missingPartialFileRestartsInsteadOfWritingHoles() async throws {
        let fixture = try await Fixture()
        let reference = try await referenceArchive(fixture)
        let store = makeStore(fixture)
        fixture.budget.value = 5
        await #expect(throws: URLError.self) { try await store.download(name: "Lost", bounds: bounds, detail: .standard) }
        let paused = try #require(store.pausedDownloads.first)
        #expect(paused.bytesDone > 0)

        // The job still lists written batches, but the bytes they refer to are gone.
        let downloads = fixture.base.appending(path: OfflineMapStore.downloadsDirectoryName, directoryHint: .isDirectory)
        try FileManager.default.removeItem(at: downloads.appending(path: "\(paused.id.uuidString).pmtiles.partial"))

        fixture.budget.value = nil
        fixture.log.value = []
        let area = try await store.resumeDownload(paused.id)
        #expect(fixture.log.value.count == reference.batches)
        #expect(try Data(contentsOf: store.fileURL(for: area)) == reference.data)
    }

    @Test func estimateRecoversAfterTheBuildChanges() async throws {
        let fixture = try await Fixture()
        let etag = LockedBox("\"v1\"")
        let buildURL = Fixture.buildURL("20261023")
        let client = FakeHTTPClient { [source = fixture.source] request in
            try await FakeHTTPClient.serving(source, at: buildURL, etag: etag.value).send(request)
        }
        let store = OfflineMapStore(
            baseDirectory: fixture.base,
            locator: ProtomapsBuildLocator(client: client, now: { Date.utc(2026, 10, 24, hour: 9) }),
            makeFetcher: { build in HTTPRangeFetcher(url: build.url, client: client, expectedETag: build.etag) }
        )
        _ = try await store.estimate(bounds: bounds, detail: .standard)

        // The build is republished: the cached reader's leaf reads now fail the ETag check...
        etag.value = "\"v2\""
        let elsewhere = GeoBounds(minLongitude: 100, minLatitude: -40, maxLongitude: 150, maxLatitude: -10)
        await #expect(throws: RangeFetchError.resourceChanged) { try await store.estimate(bounds: elsewhere, detail: .standard) }
        // ...but the next estimate locates the build again instead of failing until relaunch.
        let plan = try await store.estimate(bounds: elsewhere, detail: .standard)
        #expect(plan.tileCount > 0)
    }

    @Test func discardAndCancelRemoveProgress() async throws {
        let fixture = try await Fixture()
        let store = makeStore(fixture)
        fixture.budget.value = 2
        await #expect(throws: URLError.self) { try await store.download(name: "Gone", bounds: bounds, detail: .standard) }
        let paused = try #require(store.pausedDownloads.first)
        store.discardDownload(paused.id)
        #expect(store.pausedDownloads.isEmpty)
        #expect(makeStore(fixture).pausedDownloads.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.base.path).isEmpty)
        await #expect(throws: OfflineMapStoreError.downloadNotFound) { try await store.resumeDownload(paused.id) }
    }

    @Test func refreshReplacesFileKeepingIdentity() async throws {
        let fixture = try await Fixture()
        let first = makeStore(fixture)
        let original = try await first.download(name: "Coast", bounds: bounds, detail: .standard)
        try first.saveThumbnail(Data([1, 2, 3]), for: original.id)
        try first.rename(original.id, to: "My Coast")

        let later = makeStore(fixture, today: Date.utc(2026, 10, 26, hour: 9), buildDay: "20261025", etag: "\"v3\"")
        let revision = later.thumbnailRevision
        let refreshed = try await later.refresh(original.id)
        #expect(refreshed.id == original.id)
        #expect(refreshed.name == "My Coast")
        #expect(refreshed.createdAt.timeIntervalSince(original.createdAt) < 1)
        #expect(refreshed.sourceBuildDate == Date.utc(2026, 10, 25))
        #expect(refreshed.fileSize == original.fileSize)
        #expect(later.areas == [refreshed])
        #expect(!later.hasThumbnail(refreshed))
        #expect(later.thumbnailRevision > revision)
        #expect(makeStore(fixture).areas.first?.sourceBuildDate == Date.utc(2026, 10, 25))

        await #expect(throws: OfflineMapStoreError.alreadyUpToDate) {
            try await makeStore(fixture, today: Date.utc(2026, 10, 26, hour: 9), buildDay: "20261025").refresh(original.id)
        }
        #expect(later.areas.count == 1)
        await #expect(throws: OfflineMapStoreError.areaNotFound) { try await later.refresh(UUID()) }
    }

    @Test func storageCapBlocksDownloadsThatWouldNotFit() async throws {
        let fixture = try await Fixture()
        let store = makeStore(fixture)
        #expect(store.remainingCapacity() == nil)
        let plan = try await store.estimate(bounds: bounds, detail: .standard)
        try store.checkStorageCap(estimatedFileSize: plan.estimatedFileSize)

        let existing = try await store.download(name: "First", bounds: bounds, detail: .standard)
        store.storageCap = existing.fileSize + plan.estimatedFileSize - 1
        #expect(store.remainingCapacity() == plan.estimatedFileSize - 1)
        let exceeded = OfflineMapStoreError.storageCapExceeded(required: plan.estimatedFileSize, available: plan.estimatedFileSize - 1)
        #expect(throws: exceeded) {
            try store.checkStorageCap(estimatedFileSize: plan.estimatedFileSize)
        }
        // Replacing an area frees its space first.
        try store.checkStorageCap(estimatedFileSize: plan.estimatedFileSize, replacing: existing.id)

        await #expect(throws: exceeded) {
            try await store.download(name: "Second", bounds: bounds, detail: .standard)
        }
        #expect(store.areas == [existing])
        #expect(store.pausedDownloads.isEmpty)
        let contents = try FileManager.default.contentsOfDirectory(atPath: fixture.base.path).sorted()
        #expect(contents == ["\(existing.id.uuidString).pmtiles", "areas.json"])

        // Unfinished downloads count against the cap too.
        store.storageCap = nil
        fixture.budget.value = 1
        await #expect(throws: URLError.self) { try await store.download(name: "Partial", bounds: bounds, detail: .standard) }
        #expect(store.committedBytes() == existing.fileSize + plan.estimatedFileSize)
    }

    @Test func thumbnailsAreSavedExcludedFromBackupAndDeletedWithTheirArea() async throws {
        let fixture = try await Fixture()
        let store = makeStore(fixture)
        let area = try await store.download(name: "Thumb", bounds: bounds, detail: .standard)
        #expect(!store.hasThumbnail(area))
        try store.saveThumbnail(Data([0x89, 0x50]), for: area.id)
        #expect(store.hasThumbnail(area))
        #expect(store.thumbnailURL(for: area).deletingLastPathComponent().standardizedFileURL == fixture.base.standardizedFileURL)
        #expect(try store.thumbnailURL(for: area).resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(throws: OfflineMapStoreError.areaNotFound) { try store.saveThumbnail(Data(), for: UUID()) }
        try store.delete(area.id)
        #expect(!FileManager.default.fileExists(atPath: store.thumbnailURL(for: area).path))
    }
}
