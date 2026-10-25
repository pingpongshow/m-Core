import Foundation

// Downloading, refreshing, pausing and resuming. An unfinished download is a JSON job plus a partial file in
// `Downloads/`; the job records the build (with its ETag), the plan's fingerprint and the batches written.
extension OfflineMapStore {
    /// Locates the newest build, plans and extracts `bounds` at `detail`, and registers the new area.
    /// Progress is published through ``activeDownload``. ``pauseDownload()`` stops it resumably (throwing
    /// ``OfflineMapStoreError/downloadPaused``); ``cancelDownload()`` or cancelling the calling task discards it.
    /// Other failures after planning keep the progress in ``pausedDownloads`` and rethrow.
    @discardableResult
    public func download(name: String, bounds: GeoBounds, detail: OfflineMapDetail) async throws -> OfflineMapArea {
        let trimmed = try Self.validated(name)
        return try await run(DownloadJob(id: UUID(), name: trimmed, bounds: bounds.normalized, detail: detail))
    }

    /// Re-downloads an area's bounds and detail from the newest build, replacing its file only once the new one
    /// is complete. The area keeps its id, name and creation date; its build date and size are updated.
    @discardableResult
    public func refresh(_ id: UUID) async throws -> OfflineMapArea {
        guard let area = areas.first(where: { $0.id == id }) else { throw OfflineMapStoreError.areaNotFound }
        guard area.canRefresh else { throw OfflineMapStoreError.cannotRefreshImported }
        if let paused = pausedDownloads.first(where: { $0.replacesAreaID == id }) {
            return try await resumeDownload(paused.id)
        }
        return try await run(DownloadJob(id: UUID(), name: area.name, bounds: area.bounds, detail: area.detail, replacesAreaID: id))
    }

    /// Carries on with an unfinished download, skipping what is already written. If the build it was copying
    /// has changed or gone, it starts cleanly from the newest build.
    @discardableResult
    public func resumeDownload(_ id: UUID) async throws -> OfflineMapArea {
        guard let job = loadJob(id) else {
            reloadPausedDownloads()
            throw OfflineMapStoreError.downloadNotFound
        }
        return try await run(job)
    }

    /// Stops the running download, keeping its progress for ``resumeDownload(_:)``.
    public func pauseDownload() {
        guard downloadTask != nil else { return }
        pauseRequested = true
        downloadTask?.cancel()
    }

    /// Cancels the running download; its partial file is removed.
    public func cancelDownload() {
        pauseRequested = false
        downloadTask?.cancel()
    }

    /// Deletes an unfinished download and its partial file.
    public func discardDownload(_ id: UUID) {
        guard runningJob?.id != id else { return cancelDownload() }
        removeJobFiles(id)
        reloadPausedDownloads()
    }

    /// Exact download size for `bounds` at `detail`, without downloading tiles. The located build and its
    /// directories are cached, so repeated estimates while the user frames an area are cheap.
    public func estimate(bounds: GeoBounds, detail: OfflineMapDetail) async throws -> ExtractPlan {
        let extractor = try await cachedExtractor()
        do {
            return try await extractor.plan(bounds: bounds.normalized, zoomRange: detail.zoomRange)
        } catch {
            // The cached build may have been replaced or removed (daily builds expire): locate it afresh next time.
            if !(error is CancellationError || error is PMTilesError) { estimator = nil }
            throw error
        }
    }

    private var activeLocator: ProtomapsBuildLocator {
        customSourceURL.map { locator.with(configuration: .custom($0)) } ?? locator
    }

    private func cachedExtractor() async throws -> PMTilesExtractor {
        if let estimator { return estimator }
        let build = try await activeLocator.locate()
        let reader = try await PMTilesReader(fetcher: makeFetcher(build))
        let extractor = PMTilesExtractor(reader: reader, configuration: extractorConfiguration)
        estimator = extractor
        return extractor
    }

    private func run(_ job: DownloadJob) async throws -> OfflineMapArea {
        guard downloadTask == nil else { throw OfflineMapStoreError.downloadInProgress }
        pauseRequested = false
        runningJob = job
        activeDownload = OfflineMapDownload(
            id: job.id, name: job.name, replacesAreaID: job.replacesAreaID, phase: .locatingBuild,
            bytesDone: job.bytesDone, bytesTotal: job.bytesTotal, estimatedFileSize: job.estimatedFileSize
        )
        pausedDownloads.removeAll { $0.id == job.id }
        let task = Task { try await self.perform() }
        downloadTask = task
        defer {
            downloadTask = nil
            activeDownload = nil
            runningJob = nil
            pauseRequested = false
            reloadPausedDownloads()
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Runs ``runningJob`` and decides what to keep when it stops early.
    private func perform() async throws -> OfflineMapArea {
        if let job = runningJob { try saveJob(job) }
        do {
            let area = try await execute()
            if let job = runningJob { removeJobFiles(job.id) }
            return area
        } catch {
            guard var job = runningJob else { throw error }
            // URLSession reports a cancelled request as URLError(.cancelled), not CancellationError: go by the task.
            let cancelled = error is CancellationError || Task.isCancelled
            // A pause always keeps the job; an error keeps it once there is planned work to resume.
            if pauseRequested || (!cancelled && job.fingerprint != nil && Self.isResumable(error)) {
                job.lastError = pauseRequested ? nil : Self.describe(error)
                job.updatedAt = Date()
                try? saveJob(job)
                if pauseRequested { throw OfflineMapStoreError.downloadPaused }
                throw error
            }
            removeJobFiles(job.id)
            throw cancelled ? CancellationError() : error
        }
    }

    private func execute() async throws -> OfflineMapArea {
        // A build replaced mid-download restarts once from the newest build.
        for attempt in 0..<2 {
            do {
                return try await executeOnce()
            } catch RangeFetchError.resourceChanged where attempt == 0 {
                resetProgress(keepBuild: false)
            }
        }
        throw RangeFetchError.resourceChanged
    }

    /// The build the running job copies: its saved build while that is unchanged, else the newest one
    /// (with the saved progress discarded).
    private func resolveBuild() async throws -> ProtomapsBuild {
        guard var job = runningJob else { throw OfflineMapStoreError.downloadNotFound }
        let locator = activeLocator
        if let build = job.build, try await !locator.isUnchanged(build) {
            resetProgress(keepBuild: false)
            job = runningJob ?? job
        }
        if let existing = job.build { return existing }
        let build = try await locator.locate()
        if let replaced = job.replacesAreaID, let area = areas.first(where: { $0.id == replaced }),
           let current = area.sourceBuildDate, build.buildDate <= current {
            throw OfflineMapStoreError.alreadyUpToDate
        }
        job.build = build
        runningJob = job
        try saveJob(job)
        return build
    }

    private func executeOnce() async throws -> OfflineMapArea {
        let build = try await resolveBuild()
        guard var job = runningJob else { throw OfflineMapStoreError.downloadNotFound }

        activeDownload?.phase = .planning
        let reader = try await PMTilesReader(fetcher: makeFetcher(build))
        let extractor = PMTilesExtractor(reader: reader, configuration: extractorConfiguration)
        let plan = try await extractor.plan(bounds: job.bounds, zoomRange: job.detail.zoomRange)
        try checkStorageCap(estimatedFileSize: plan.estimatedFileSize, replacing: job.replacesAreaID, excludingDownload: job.id)
        let fingerprint = extractor.fingerprint(of: plan)
        let partialSize = Self.fileSize(at: partialURL(for: job.id)) ?? 0
        // Different work than the saved progress describes, or a partial file missing bytes the job says were written
        // (resuming would leave holes): start this plan from scratch.
        if job.fingerprint != fingerprint || partialSize < extractor.minimumPartialSize(for: job.completedBatches, in: plan) {
            resetProgress(keepBuild: true)
            job = runningJob ?? job
            job.fingerprint = fingerprint
        }
        job.bytesTotal = plan.payloadBytes
        job.estimatedFileSize = plan.estimatedFileSize
        job.bytesDone = extractor.payloadBytes(of: job.completedBatches, in: plan)
        job.lastError = nil
        runningJob = job
        try saveJob(job)

        activeDownload?.phase = .downloading
        activeDownload?.bytesDone = job.bytesDone
        activeDownload?.bytesTotal = plan.payloadBytes
        activeDownload?.estimatedFileSize = plan.estimatedFileSize
        try prepareDirectory()
        let id = job.id
        try await extractor.extract(
            plan: plan,
            partialURL: partialURL(for: id),
            completedBatches: job.completedBatches,
            checkpoint: { [weak self] completed, done in await self?.checkpoint(id: id, completed: completed, done: done) },
            progress: { done, total in
                Task { @MainActor [weak self] in self?.updateProgress(id: id, done: done, total: total) }
            }
        )
        activeDownload?.phase = .finishing
        return try install(job: job, build: build, plan: plan)
    }

    /// Moves the finished file into place as a new area, or over the area it refreshes.
    private func install(job: DownloadJob, build: ProtomapsBuild, plan: ExtractPlan) throws -> OfflineMapArea {
        let partial = partialURL(for: job.id)
        if let replaced = job.replacesAreaID {
            guard let index = areas.firstIndex(where: { $0.id == replaced }) else { throw OfflineMapStoreError.areaNotFound }
            var url = fileURL(for: areas[index])
            try PMTilesExtractor.finish(partialURL: partial, plan: plan, to: url)
            try Self.excludeFromBackup(&url)
            removeThumbnail(for: areas[index])
            areas[index].sourceBuildDate = build.buildDate
            areas[index].fileSize = Self.fileSize(at: url) ?? plan.estimatedFileSize
            try saveManifest()
            return areas[index]
        }
        var area = OfflineMapArea(id: job.id, name: job.name, bounds: job.bounds, detail: job.detail, sourceBuildDate: build.buildDate)
        let destination = fileURL(for: area)
        try PMTilesExtractor.finish(partialURL: partial, plan: plan, to: destination)
        do {
            try register(&area)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return area
    }

    /// Forgets the running job's written batches (and optionally its build) and deletes its partial file.
    private func resetProgress(keepBuild: Bool) {
        guard var job = runningJob else { return }
        if !keepBuild { job.build = nil }
        job.fingerprint = nil
        job.completedBatches = IndexSet()
        job.bytesDone = 0
        runningJob = job
        try? FileManager.default.removeItem(at: partialURL(for: job.id))
        activeDownload?.bytesDone = 0
    }

    private func checkpoint(id: UUID, completed: IndexSet, done: Int64) {
        guard var job = runningJob, job.id == id else { return }
        job.completedBatches = completed
        job.bytesDone = done
        job.updatedAt = Date()
        runningJob = job
        try? saveJob(job)
    }

    private func updateProgress(id: UUID, done: Int64, total: Int64) {
        guard var download = activeDownload, download.id == id, done >= download.bytesDone else { return }
        download.bytesDone = done
        download.bytesTotal = total
        activeDownload = download
    }

    /// Errors after which the saved progress is still worth resuming (network trouble, not a broken plan).
    private static func isResumable(_ error: any Error) -> Bool {
        switch error {
        case is OfflineMapStoreError, is PMTilesError: false
        default: true
        }
    }

    private static func describe(_ error: any Error) -> String {
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: return "The connection was lost."
            case .timedOut: return "The map server stopped responding."
            default: break
            }
        }
        if let error = error as? RangeFetchError, case .unexpectedStatus(let status) = error {
            return "The map server answered \(status)."
        }
        return (error as? LocalizedError)?.errorDescription ?? "The download stopped."
    }

    // MARK: Download jobs

    private var downloadsDirectory: URL {
        baseDirectory.appending(path: Self.downloadsDirectoryName, directoryHint: .isDirectory)
    }

    private func jobURL(for id: UUID) -> URL {
        downloadsDirectory.appending(path: "\(id.uuidString).json", directoryHint: .notDirectory)
    }

    private func partialURL(for id: UUID) -> URL {
        downloadsDirectory.appending(path: "\(id.uuidString).pmtiles.partial", directoryHint: .notDirectory)
    }

    private func loadJob(_ id: UUID) -> DownloadJob? {
        guard let data = try? Data(contentsOf: jobURL(for: id)) else { return nil }
        return try? Self.decoder.decode(DownloadJob.self, from: data)
    }

    private func saveJob(_ job: DownloadJob) throws {
        try prepareDirectory()
        var directory = downloadsDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.excludeFromBackup(&directory)
        var url = jobURL(for: job.id)
        try Self.encoder.encode(job).write(to: url, options: .atomic)
        try Self.excludeFromBackup(&url)
        let partial = partialURL(for: job.id)
        if FileManager.default.fileExists(atPath: partial.path) {
            var partialURL = partial
            try? Self.excludeFromBackup(&partialURL)
        }
    }

    private func removeJobFiles(_ id: UUID) {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: jobURL(for: id))
        try? fileManager.removeItem(at: partialURL(for: id))
        if let remaining = try? fileManager.contentsOfDirectory(atPath: downloadsDirectory.path), remaining.isEmpty {
            try? fileManager.removeItem(at: downloadsDirectory)
        }
    }

    /// Lists saved jobs (except the running one), clearing partial files whose job is gone and abandoned imports.
    func reloadPausedDownloads() {
        let fileManager = FileManager.default
        let names = (try? fileManager.contentsOfDirectory(atPath: downloadsDirectory.path)) ?? []
        var jobs: [DownloadJob] = []
        for name in names where name.hasSuffix(".json") {
            guard let id = UUID(uuidString: String(name.dropLast(5))) else { continue }
            if let job = loadJob(id) {
                jobs.append(job)
            } else {
                removeJobFiles(id)
            }
        }
        let known = Set(jobs.map(\.id))
        for name in names where name.hasSuffix(".partial") {
            let stem = name.split(separator: ".").first.map(String.init) ?? ""
            if let id = UUID(uuidString: stem), known.contains(id) { continue }
            try? fileManager.removeItem(at: downloadsDirectory.appending(path: name))
        }
        if downloadTask == nil {
            let leftovers = (try? fileManager.contentsOfDirectory(atPath: baseDirectory.path)) ?? []
            for name in leftovers where name.hasPrefix(".import-") {
                try? fileManager.removeItem(at: baseDirectory.appending(path: name))
            }
        }
        pausedDownloads = jobs
            .filter { $0.id != runningJob?.id }
            .sorted { $0.updatedAt > $1.updatedAt }
            .map(\.summary)
    }
}

/// An unfinished download as saved in `Downloads/<id>.json`: what to fetch, from which build, and which
/// coalesced batches of the plan are already in the partial file.
struct DownloadJob: Codable, Sendable {
    var version = 1
    let id: UUID
    var name: String
    var bounds: GeoBounds
    var detail: OfflineMapDetail
    var replacesAreaID: UUID?
    /// The build being copied, including the ETag that must still match to resume.
    var build: ProtomapsBuild?
    /// The plan the completed batches belong to; nil until planned.
    var fingerprint: ExtractFingerprint?
    var completedBatches = IndexSet()
    var bytesDone: Int64 = 0
    var bytesTotal: Int64 = 0
    var estimatedFileSize: Int64 = 0
    var createdAt = Date()
    var updatedAt = Date()
    var lastError: String?

    init(id: UUID, name: String, bounds: GeoBounds, detail: OfflineMapDetail, replacesAreaID: UUID? = nil) {
        self.id = id
        self.name = name
        self.bounds = bounds
        self.detail = detail
        self.replacesAreaID = replacesAreaID
    }

    var summary: PausedOfflineMapDownload {
        PausedOfflineMapDownload(
            id: id, name: name, bounds: bounds, detail: detail, replacesAreaID: replacesAreaID,
            bytesDone: bytesDone, bytesTotal: bytesTotal, estimatedFileSize: estimatedFileSize,
            sourceBuildDate: build?.buildDate, updatedAt: updatedAt, lastError: lastError
        )
    }
}
