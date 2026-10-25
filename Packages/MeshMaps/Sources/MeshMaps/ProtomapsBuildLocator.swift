import Foundation

/// A daily Protomaps planet build found by ``ProtomapsBuildLocator``.
public struct ProtomapsBuild: Hashable, Sendable, Codable {
    public let url: URL
    /// UTC midnight of the build day.
    public let buildDate: Date
    /// `YYYYMMDD` file stem.
    public let identifier: String
    public let contentLength: Int64?
    public let etag: String?

    public init(url: URL, buildDate: Date, identifier: String, contentLength: Int64? = nil, etag: String? = nil) {
        self.url = url
        self.buildDate = buildDate
        self.identifier = identifier
        self.contentLength = contentLength
        self.etag = etag
    }
}

/// Errors from build discovery.
public enum ProtomapsBuildLocatorError: Error, Sendable, Equatable {
    /// No candidate answered 200 within the search window.
    case noBuildFound
}

/// Finds the newest daily planet build by HEAD-probing `<base>/YYYYMMDD.pmtiles` from today (UTC) backwards.
public struct ProtomapsBuildLocator: Sendable {
    /// Where and how far back to look; `Codable` so the app can load overrides from JSON.
    public struct Configuration: Hashable, Sendable, Codable {
        /// Candidate base URLs, tried in order for each day.
        public var baseURLs: [URL]
        /// Days before today to probe (0 = today only).
        public var maxAgeDays: Int
        /// A single archive to use as-is instead of probing dated builds (a debug-only test source).
        public var fixedFileURL: URL?

        public init(baseURLs: [URL], maxAgeDays: Int = 14, fixedFileURL: URL? = nil) {
            self.baseURLs = baseURLs
            self.maxAgeDays = max(0, maxAgeDays)
            self.fixedFileURL = fixedFileURL
        }

        /// A custom source: a URL ending in `.pmtiles` is used as one fixed archive, anything else as a base URL
        /// holding dated `YYYYMMDD.pmtiles` builds.
        public static func custom(_ url: URL) -> Configuration {
            url.pathExtension.lowercased() == "pmtiles"
                ? Configuration(baseURLs: [], maxAgeDays: 0, fixedFileURL: url)
                : Configuration(baseURLs: [url])
        }

        // swiftlint:disable:next force_unwrapping
        public static let `default` = Configuration(baseURLs: [URL(string: "https://build.protomaps.com/")!])
    }

    /// Built-in configuration, used when there is no source list or it can't be loaded.
    public var configuration: Configuration
    /// Optional remote list of candidate base URLs that replaces ``configuration`` when it loads.
    public var sourceList: ProtomapsSourceListLoader?
    private let client: any HTTPClient
    private let now: @Sendable () -> Date

    public init(
        configuration: Configuration = .default,
        client: any HTTPClient = URLSessionHTTPClient(),
        sourceList: ProtomapsSourceListLoader? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.client = client
        self.sourceList = sourceList
        self.now = now
    }

    /// The same locator (network and clock) searching `configuration` only, without the source list.
    public func with(configuration: Configuration) -> ProtomapsBuildLocator {
        ProtomapsBuildLocator(configuration: configuration, client: client, now: now)
    }

    /// The configuration ``locate()`` searches: the source list's when one is set and loads, else the built-in one.
    public func resolvedConfiguration() async -> Configuration {
        guard let sourceList else { return configuration }
        return await sourceList.configuration(fallback: configuration)
    }

    /// Returns the newest build any candidate base URL serves. Days are checked newest first; within a day
    /// base URLs are tried in order. Transport errors on one candidate do not stop the search.
    public func locate() async throws -> ProtomapsBuild {
        let configuration = await resolvedConfiguration()
        if let fixed = configuration.fixedFileURL {
            return try await locateFixed(fixed)
        }
        let today = Self.calendar.startOfDay(for: now())
        var lastError: (any Error)?
        var sawResponse = false
        for age in 0...configuration.maxAgeDays {
            guard let day = Self.calendar.date(byAdding: .day, value: -age, to: today) else { continue }
            let identifier = Self.identifier(for: day)
            for base in configuration.baseURLs {
                try Task.checkCancellation()
                let url = base.appending(path: "\(identifier).pmtiles")
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
                request.httpMethod = "HEAD"
                do {
                    let (_, response) = try await client.send(request)
                    sawResponse = true
                    guard response.statusCode == 200 else { continue }
                    return ProtomapsBuild(
                        url: url,
                        buildDate: day,
                        identifier: identifier,
                        contentLength: response.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0) },
                        etag: response.value(forHTTPHeaderField: "ETag")
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lastError = error
                }
            }
        }
        // A reachable server without a build is "not found"; only surface transport errors when nothing answered.
        if sawResponse { throw ProtomapsBuildLocatorError.noBuildFound }
        throw lastError ?? ProtomapsBuildLocatorError.noBuildFound
    }

    /// Whether `build` is still served unchanged: same ETag, or same length when the server sends no ETag.
    /// A missing build, or one that was replaced, returns false; transport errors are thrown.
    public func isUnchanged(_ build: ProtomapsBuild) async throws -> Bool {
        var request = URLRequest(url: build.url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "HEAD"
        let (_, response) = try await client.send(request)
        guard response.statusCode == 200 else { return false }
        let etag = response.value(forHTTPHeaderField: "ETag")
        if build.etag != nil || etag != nil { return etag == build.etag }
        let length = response.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0) }
        return length != nil && length == build.contentLength
    }

    /// HEADs a fixed archive; its build date comes from `Last-Modified` (else today).
    private func locateFixed(_ url: URL) async throws -> ProtomapsBuild {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "HEAD"
        let (_, response) = try await client.send(request)
        guard response.statusCode == 200 else { throw ProtomapsBuildLocatorError.noBuildFound }
        let modified = response.value(forHTTPHeaderField: "Last-Modified").flatMap(Self.httpDate)
        let day = Self.calendar.startOfDay(for: modified ?? now())
        return ProtomapsBuild(
            url: url,
            buildDate: day,
            identifier: url.deletingPathExtension().lastPathComponent,
            contentLength: response.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0) },
            etag: response.value(forHTTPHeaderField: "ETag")
        )
    }

    /// Parses an RFC 7231 date such as `Sat, 24 Oct 2026 03:00:00 GMT`.
    static func httpDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .gmt
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text)
    }

    /// `YYYYMMDD` for `date` in UTC.
    public static func identifier(for date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()
}
