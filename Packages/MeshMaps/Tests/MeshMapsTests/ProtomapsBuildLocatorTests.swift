import Foundation
import Testing
@testable import MeshMaps

struct ProtomapsBuildLocatorTests {
    let now = Date.utc(2026, 10, 24, hour: 3)

    /// Answers HEAD 200 for the listed URLs and 404 otherwise, recording every probe.
    private func responder(available: Set<String>, probes: LockedBox<[String]>? = nil) -> FakeHTTPClient {
        FakeHTTPClient { request in
            let url = request.url?.absoluteString ?? ""
            probes?.mutate { $0.append(url) }
            #expect(request.httpMethod == "HEAD")
            let found = available.contains(url)
            let headers = found ? ["Content-Length": "120000000000", "ETag": "\"etag-\(url.suffix(16))\""] : [:]
            return (Data(), FakeHTTPClient.response(request.url, status: found ? 200 : 404, headers: headers))
        }
    }

    private func window(days: Int) -> ProtomapsBuildLocator.Configuration {
        .init(baseURLs: ProtomapsBuildLocator.Configuration.default.baseURLs, maxAgeDays: days)
    }

    @Test func identifiersUseUTC() {
        #expect(ProtomapsBuildLocator.identifier(for: Date.utc(2026, 1, 5)) == "20260105")
        #expect(ProtomapsBuildLocator.identifier(for: Date.utc(2026, 10, 24, hour: 23)) == "20261024")
    }

    @Test func picksNewestAvailableBuild() async throws {
        let probes = LockedBox<[String]>([])
        let client = responder(
            available: ["https://build.protomaps.com/20261022.pmtiles", "https://build.protomaps.com/20261019.pmtiles"],
            probes: probes
        )
        let build = try await ProtomapsBuildLocator(client: client, now: { [now] in now }).locate()
        #expect(build.identifier == "20261022")
        #expect(build.url.absoluteString == "https://build.protomaps.com/20261022.pmtiles")
        #expect(build.buildDate == Date.utc(2026, 10, 22))
        #expect(build.contentLength == 120_000_000_000)
        #expect(build.etag != nil)
        #expect(probes.value == [
            "https://build.protomaps.com/20261024.pmtiles",
            "https://build.protomaps.com/20261023.pmtiles",
            "https://build.protomaps.com/20261022.pmtiles",
        ])
    }

    @Test func newestDayWinsAcrossBaseURLs() async throws {
        let configuration = ProtomapsBuildLocator.Configuration(
            // swiftlint:disable:next force_unwrapping
            baseURLs: [URL(string: "https://primary.example/builds/")!, URL(string: "https://mirror.example")!],
            maxAgeDays: 7
        )
        let client = responder(available: ["https://primary.example/builds/20261020.pmtiles", "https://mirror.example/20261023.pmtiles"])
        let build = try await ProtomapsBuildLocator(configuration: configuration, client: client, now: { [now] in now }).locate()
        #expect(build.url.absoluteString == "https://mirror.example/20261023.pmtiles")
    }

    @Test func failsWhenNothingWithinWindow() async throws {
        let probes = LockedBox<[String]>([])
        let client = responder(available: ["https://build.protomaps.com/20261001.pmtiles"], probes: probes)
        let locator = ProtomapsBuildLocator(configuration: window(days: 3), client: client, now: { [now] in now })
        await #expect(throws: ProtomapsBuildLocatorError.noBuildFound) { _ = try await locator.locate() }
        #expect(probes.value.count == 4)
    }

    @Test func surfacesTransportErrorsWhenNothingAnswers() async throws {
        let client = FakeHTTPClient { _ in throw URLError(.notConnectedToInternet) }
        let locator = ProtomapsBuildLocator(configuration: window(days: 1), client: client, now: { [now] in now })
        await #expect(throws: URLError.self) { _ = try await locator.locate() }
    }

    @Test func configurationDecodesFromJSON() throws {
        let json = Data(#"{"baseURLs":["https://mirror.example/pm/"],"maxAgeDays":5}"#.utf8)
        let configuration = try JSONDecoder().decode(ProtomapsBuildLocator.Configuration.self, from: json)
        #expect(configuration.baseURLs.map(\.absoluteString) == ["https://mirror.example/pm/"])
        #expect(configuration.maxAgeDays == 5)
    }
}
