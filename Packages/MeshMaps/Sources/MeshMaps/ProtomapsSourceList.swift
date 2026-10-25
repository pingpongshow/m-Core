import Foundation

/// The list of candidate Protomaps build base URLs published as `Maps/sources.json` in the m-Core repository,
/// so the source can move without an app update (PLAN.md §4.4).
///
/// ```json
/// { "version": 1, "baseURLs": ["https://build.protomaps.com/"], "maxAgeDays": 14 }
/// ```
public struct ProtomapsSourceList: Hashable, Sendable, Codable {
    /// Format version this app understands.
    public static let supportedVersion = 1

    public var version: Int
    /// Base URLs holding dated `YYYYMMDD.pmtiles` builds, tried in order.
    public var baseURLs: [URL]
    /// Days back to search; the built-in window when absent.
    public var maxAgeDays: Int?

    public init(version: Int = ProtomapsSourceList.supportedVersion, baseURLs: [URL], maxAgeDays: Int? = nil) {
        self.version = version
        self.baseURLs = baseURLs
        self.maxAgeDays = maxAgeDays
    }

    /// Whether the list can be used: a supported version and at least one HTTPS base URL. Non-HTTPS entries
    /// are dropped, so a tampered list can't point the app at plain HTTP.
    public var usable: ProtomapsSourceList? {
        guard version == Self.supportedVersion else { return nil }
        let secure = baseURLs.filter { $0.scheme?.lowercased() == "https" && $0.host() != nil }
        guard !secure.isEmpty else { return nil }
        return ProtomapsSourceList(version: version, baseURLs: secure, maxAgeDays: maxAgeDays.map { min(max($0, 0), 60) })
    }

    /// Locator configuration for this list, keeping `fallback`'s search window when the list has none.
    public func configuration(fallback: ProtomapsBuildLocator.Configuration) -> ProtomapsBuildLocator.Configuration {
        ProtomapsBuildLocator.Configuration(baseURLs: baseURLs, maxAgeDays: maxAgeDays ?? fallback.maxAgeDays)
    }
}

/// Fetches the remote ``ProtomapsSourceList`` and caches it on disk.
///
/// With no remote URL nothing is fetched and the built-in configuration is used. A cached list younger than
/// ``refreshInterval`` is used without a request; if a refresh fails, a stale cache is still better than nothing,
/// and with no cache the built-in configuration is the fallback.
public struct ProtomapsSourceListLoader: Sendable {
    /// Where the app fetches the list: `Maps/sources.json` on the main branch of the m-Core repository. Edit that
    /// file to point every installed app at new or additional map sources without an app update.
    public static let defaultRemoteURL = URL(string: "https://raw.githubusercontent.com/pingpongshow/m-Core/main/Maps/sources.json")

    /// Default cache file in the app's Caches directory.
    nonisolated public static var defaultCacheURL: URL {
        URL.cachesDirectory.appending(path: "protomaps-sources.json", directoryHint: .notDirectory)
    }

    public let remoteURL: URL?
    public let cacheURL: URL
    public let refreshInterval: TimeInterval
    private let client: any HTTPClient
    private let now: @Sendable () -> Date

    public init(
        remoteURL: URL? = ProtomapsSourceListLoader.defaultRemoteURL,
        cacheURL: URL = ProtomapsSourceListLoader.defaultCacheURL,
        refreshInterval: TimeInterval = 86_400,
        client: any HTTPClient = URLSessionHTTPClient(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.remoteURL = remoteURL
        self.cacheURL = cacheURL
        self.refreshInterval = refreshInterval
        self.client = client
        self.now = now
    }

    /// The configuration to search: the fresh cache, a newly fetched list, a stale cache, or `fallback`.
    public func configuration(fallback: ProtomapsBuildLocator.Configuration) async -> ProtomapsBuildLocator.Configuration {
        guard let remoteURL else { return fallback }
        let cached = cachedList()
        if let cached, now().timeIntervalSince(cached.fetchedAt) < refreshInterval {
            return cached.list.configuration(fallback: fallback)
        }
        if let fetched = await fetch(remoteURL) {
            store(fetched)
            return fetched.configuration(fallback: fallback)
        }
        return cached?.list.configuration(fallback: fallback) ?? fallback
    }

    private func fetch(_ url: URL) async -> ProtomapsSourceList? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await client.send(request), response.statusCode == 200,
              let list = try? JSONDecoder().decode(ProtomapsSourceList.self, from: data) else { return nil }
        return list.usable
    }

    private func cachedList() -> CachedSourceList? {
        guard let data = try? Data(contentsOf: cacheURL),
              let cached = try? Self.decoder.decode(CachedSourceList.self, from: data),
              let usable = cached.list.usable else { return nil }
        return CachedSourceList(fetchedAt: cached.fetchedAt, list: usable)
    }

    private func store(_ list: ProtomapsSourceList) {
        guard let data = try? Self.encoder.encode(CachedSourceList(fetchedAt: now(), list: list)) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

private struct CachedSourceList: Codable {
    var fetchedAt: Date
    var list: ProtomapsSourceList
}
