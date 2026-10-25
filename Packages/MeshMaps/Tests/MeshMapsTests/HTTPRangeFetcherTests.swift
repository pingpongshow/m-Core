import Foundation
import Testing
@testable import MeshMaps

struct HTTPRangeFetcherTests {
    // swiftlint:disable:next force_unwrapping
    let url = URL(string: "https://build.example/20261024.pmtiles")!
    let body = Data((0..<1_000).map { UInt8($0 % 256) })

    @Test func sendsRangeAndReturnsBody() async throws {
        let directory = try TemporaryDirectory()
        let file = directory.file("blob")
        try body.write(to: file)
        let seen = LockedBox<[URLRequest]>([])
        let serving = FakeHTTPClient.serving(file, at: url)
        let client = FakeHTTPClient { request in
            seen.mutate { $0.append(request) }
            return try await serving.send(request)
        }
        let fetcher = HTTPRangeFetcher(url: url, client: client)
        #expect(try await fetcher.fetch(offset: 10, length: 20) == body.subdata(in: 10..<30))
        // Ranges past end of file are allowed to come back short.
        #expect(try await fetcher.fetch(offset: 990, length: 100) == body.subdata(in: 990..<1_000))

        let requests = seen.value
        #expect(requests[0].value(forHTTPHeaderField: "Range") == "bytes=10-29")
        #expect(requests[0].value(forHTTPHeaderField: "If-Match") == nil)
        #expect(requests[1].value(forHTTPHeaderField: "If-Match") == "\"v1\"")
    }

    @Test func rejectsFullResponsesAndUnexpectedStatus() async throws {
        let full = HTTPRangeFetcher(url: url, client: FakeHTTPClient { [body] request in
            (body, FakeHTTPClient.response(request.url, status: 200))
        })
        await #expect(throws: RangeFetchError.rangeNotSupported) { _ = try await full.fetch(offset: 0, length: 10) }

        let missing = HTTPRangeFetcher(url: url, client: FakeHTTPClient { request in
            (Data(), FakeHTTPClient.response(request.url, status: 404))
        })
        await #expect(throws: RangeFetchError.unexpectedStatus(404)) { _ = try await missing.fetch(offset: 0, length: 10) }
    }

    @Test func detectsChangedResource() async throws {
        let tag = LockedBox("\"a\"")
        let client = FakeHTTPClient { request in
            let current = tag.value
            if let ifMatch = request.value(forHTTPHeaderField: "If-Match"), ifMatch != current {
                return (Data(), FakeHTTPClient.response(request.url, status: 412))
            }
            let headers = ["ETag": current, "Content-Range": "bytes 0-9/1000"]
            return (Data(count: 10), FakeHTTPClient.response(request.url, status: 206, headers: headers))
        }
        let fetcher = HTTPRangeFetcher(url: url, client: client)
        _ = try await fetcher.fetch(offset: 0, length: 10)
        tag.value = "\"b\""
        await #expect(throws: RangeFetchError.resourceChanged) { _ = try await fetcher.fetch(offset: 0, length: 10) }

        // Without If-Match support on the server, a changed ETag in the response is still caught.
        let ignoring = HTTPRangeFetcher(url: url, client: FakeHTTPClient { request in
            let headers = ["ETag": "\"\(UUID().uuidString)\"", "Content-Range": "bytes 0-9/1000"]
            return (Data(count: 10), FakeHTTPClient.response(request.url, status: 206, headers: headers))
        })
        _ = try await ignoring.fetch(offset: 0, length: 10)
        await #expect(throws: RangeFetchError.resourceChanged) { _ = try await ignoring.fetch(offset: 0, length: 10) }
    }

    @Test func rejectsShortReadsBeforeEndOfFile() async throws {
        let fetcher = HTTPRangeFetcher(url: url, client: FakeHTTPClient { request in
            (Data(count: 5), FakeHTTPClient.response(request.url, status: 206, headers: ["Content-Range": "bytes 0-4/1000"]))
        })
        await #expect(throws: RangeFetchError.shortRead(expected: 10, received: 5)) { _ = try await fetcher.fetch(offset: 0, length: 10) }
    }

    @Test func rejectsMisplacedRanges() async throws {
        let fetcher = HTTPRangeFetcher(url: url, client: FakeHTTPClient { request in
            (Data(count: 10), FakeHTTPClient.response(request.url, status: 206, headers: ["Content-Range": "bytes 0-9/1000"]))
        })
        await #expect(throws: RangeFetchError.rangeMismatch) { _ = try await fetcher.fetch(offset: 50, length: 10) }
        #expect(HTTPRangeFetcher.startOffset(contentRange: "bytes 50-59/1000") == 50)
        #expect(HTTPRangeFetcher.totalLength(contentRange: "bytes 50-59/1000") == 1_000)
        #expect(HTTPRangeFetcher.totalLength(contentRange: "bytes 50-59/*") == nil)
    }

    @Test func readsArchiveEndToEnd() async throws {
        let directory = try TemporaryDirectory()
        let file = directory.file("source.pmtiles")
        let tiles = SyntheticArchive.worldTiles(zooms: 0...3)
        try SyntheticArchive.write(tiles, to: file, leafEntryCount: 20)
        let reader = try await PMTilesReader(fetcher: HTTPRangeFetcher(url: url, client: FakeHTTPClient.serving(file, at: url)))
        for tile in tiles {
            #expect(try await reader.tileData(for: tile.id) == tile.data)
        }
    }
}
