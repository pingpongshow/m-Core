import Foundation
import Testing
@testable import MeshMaps

/// The remote list of Protomaps base URLs, its cache and fallbacks, and the debug custom source.
struct ProtomapsSourceListTests {
    // swiftlint:disable:next force_unwrapping
    let listURL = URL(string: "https://raw.example/m-Core/main/Maps/sources.json")!
    let now = Date.utc(2026, 10, 24, hour: 3)
    let mirrorList = Data(#"{"version":1,"baseURLs":["https://mirror.example/pm/","http://insecure.example/"],"maxAgeDays":3}"#.utf8)

    /// Serves `body` for the list URL, counting requests; `failing` makes every request fail.
    private func listClient(_ body: Data, status: Int = 200, failing: LockedBox<Bool>? = nil, requests: LockedBox<Int>) -> FakeHTTPClient {
        FakeHTTPClient { [listURL] request in
            requests.mutate { $0 += 1 }
            if failing?.value == true { throw URLError(.notConnectedToInternet) }
            #expect(request.url == listURL)
            return (body, FakeHTTPClient.response(request.url, status: status))
        }
    }

    private func loader(_ client: FakeHTTPClient, cache: URL, clock: LockedBox<Date>) -> ProtomapsSourceListLoader {
        ProtomapsSourceListLoader(remoteURL: listURL, cacheURL: cache, client: client, now: { clock.value })
    }

    @Test func repositoryFileDecodesToTheBuiltInDefault() throws {
        let repoRoot = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../../")
        let data = try Data(contentsOf: repoRoot.appending(path: "Maps/sources.json").standardizedFileURL)
        let list = try #require(try JSONDecoder().decode(ProtomapsSourceList.self, from: data).usable)
        #expect(list.baseURLs == ProtomapsBuildLocator.Configuration.default.baseURLs)
        #expect(list.configuration(fallback: .default) == .default)
    }

    @Test func defaultListIsTheRepositoryFileOverHTTPS() {
        let url = ProtomapsSourceListLoader.defaultRemoteURL
        #expect(url?.scheme == "https")
        #expect(url?.absoluteString.hasSuffix("/main/Maps/sources.json") == true)
    }

    @Test func noRemoteURLMeansNoRequestsAndTheDefault() async throws {
        let requests = LockedBox(0)
        let client = listClient(mirrorList, requests: requests)
        let directory = try TemporaryDirectory()
        let loader = ProtomapsSourceListLoader(remoteURL: nil, cacheURL: directory.file("sources.json"), client: client)
        #expect(await loader.configuration(fallback: .default) == .default)
        #expect(requests.value == 0)
    }

    @Test func fetchesCachesAndRefreshesDaily() async throws {
        let directory = try TemporaryDirectory()
        let requests = LockedBox(0)
        let failing = LockedBox(false)
        let clock = LockedBox(now)
        let client = listClient(mirrorList, failing: failing, requests: requests)
        let loader = loader(client, cache: directory.file("cache/sources.json"), clock: clock)

        let configuration = await loader.configuration(fallback: .default)
        // The plain-HTTP entry is dropped.
        #expect(configuration.baseURLs.map(\.absoluteString) == ["https://mirror.example/pm/"])
        #expect(configuration.maxAgeDays == 3)
        #expect(requests.value == 1)
        #expect(FileManager.default.fileExists(atPath: directory.file("cache/sources.json").path))

        // Within a day the cache answers without a request.
        clock.value = now.addingTimeInterval(3_600)
        #expect(await loader.configuration(fallback: .default) == configuration)
        #expect(requests.value == 1)

        // After a day it refetches; offline, the stale cache still wins over the default.
        clock.value = now.addingTimeInterval(2 * 86_400)
        failing.value = true
        #expect(await loader.configuration(fallback: .default) == configuration)
        #expect(requests.value == 2)
    }

    @Test func fallsBackToTheDefaultWithoutAUsableList() async throws {
        let directory = try TemporaryDirectory()
        let clock = LockedBox(now)
        for body in [Data("not json".utf8), Data(#"{"version":1,"baseURLs":["http://insecure.example/"]}"#.utf8),
                     Data(#"{"version":2,"baseURLs":["https://future.example/"]}"#.utf8)] {
            let requests = LockedBox(0)
            let loader = loader(listClient(body, requests: requests), cache: directory.file("\(UUID()).json"), clock: clock)
            #expect(await loader.configuration(fallback: .default) == .default)
            #expect(requests.value == 1)
        }
        let requests = LockedBox(0)
        let missing = loader(listClient(Data(), status: 404, requests: requests), cache: directory.file("missing.json"), clock: clock)
        #expect(await missing.configuration(fallback: .default) == .default)
    }

    @Test func locatorSearchesTheListedMirror() async throws {
        let directory = try TemporaryDirectory()
        let probes = LockedBox<[String]>([])
        let client = FakeHTTPClient { [listURL, mirrorList] request in
            if request.url == listURL { return (mirrorList, FakeHTTPClient.response(request.url, status: 200)) }
            let url = request.url?.absoluteString ?? ""
            probes.mutate { $0.append(url) }
            let found = url == "https://mirror.example/pm/20261023.pmtiles"
            return (Data(), FakeHTTPClient.response(request.url, status: found ? 200 : 404, headers: found ? ["ETag": "\"m\""] : [:]))
        }
        let sourceList = ProtomapsSourceListLoader(
            remoteURL: listURL, cacheURL: directory.file("s.json"), client: client, now: { [now] in now }
        )
        let locator = ProtomapsBuildLocator(client: client, sourceList: sourceList, now: { [now] in now })
        let build = try await locator.locate()
        #expect(build.url.absoluteString == "https://mirror.example/pm/20261023.pmtiles")
        #expect(probes.value == ["https://mirror.example/pm/20261024.pmtiles", "https://mirror.example/pm/20261023.pmtiles"])
    }

    @Test func customSourceUsesAFixedArchiveOrABaseURL() async throws {
        // swiftlint:disable force_unwrapping
        let fixed = URL(string: "http://192.0.2.10:8080/planet.pmtiles")!
        let base = URL(string: "https://test.example/builds/")!
        // swiftlint:enable force_unwrapping
        #expect(ProtomapsBuildLocator.Configuration.custom(fixed) == .init(baseURLs: [], maxAgeDays: 0, fixedFileURL: fixed))
        #expect(ProtomapsBuildLocator.Configuration.custom(base) == .init(baseURLs: [base]))

        let client = FakeHTTPClient { request in
            #expect(request.httpMethod == "HEAD")
            guard request.url == fixed else { return (Data(), FakeHTTPClient.response(request.url, status: 404)) }
            return (Data(), FakeHTTPClient.response(request.url, status: 200, headers: [
                "ETag": "\"lan\"", "Content-Length": "1000", "Last-Modified": "Tue, 20 Oct 2026 17:30:00 GMT",
            ]))
        }
        let locator = ProtomapsBuildLocator(client: client, now: { [now] in now }).with(configuration: .custom(fixed))
        let build = try await locator.locate()
        #expect(build.url == fixed)
        #expect(build.identifier == "planet")
        #expect(build.buildDate == Date.utc(2026, 10, 20))
        #expect(build.etag == "\"lan\"")
        #expect(try await locator.isUnchanged(build))
        let replaced = ProtomapsBuild(url: fixed, buildDate: build.buildDate, identifier: "planet", etag: "\"old\"")
        #expect(try await !locator.isUnchanged(replaced))
    }

    @Test func storeUsesTheCustomSourceWhenSet() async throws {
        let directory = try TemporaryDirectory()
        let source = directory.file("planet.pmtiles")
        try SyntheticArchive.write(SyntheticArchive.worldTiles(zooms: 0...5), to: source, leafEntryCount: 200)
        // swiftlint:disable:next force_unwrapping
        let custom = URL(string: "https://lan.example/maps/planet.pmtiles")!
        let client = FakeHTTPClient.serving(source, at: custom)
        let store = await OfflineMapStore(
            baseDirectory: directory.url.appending(path: "Maps", directoryHint: .isDirectory),
            locator: ProtomapsBuildLocator(client: client),
            makeFetcher: { build in HTTPRangeFetcher(url: build.url, client: client, expectedETag: build.etag) }
        )
        let bounds = GeoBounds(minLongitude: -40, minLatitude: 10, maxLongitude: -5, maxLatitude: 50)
        await #expect(throws: ProtomapsBuildLocatorError.noBuildFound) { _ = try await store.estimate(bounds: bounds, detail: .standard) }
        await MainActor.run { store.customSourceURL = custom }
        let plan = try await store.estimate(bounds: bounds, detail: .standard)
        #expect(plan.tileCount > 0)
    }
}
