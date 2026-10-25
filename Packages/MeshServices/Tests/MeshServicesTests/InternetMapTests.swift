import CryptoKit
import Foundation
import MeshCoreKit
import Synchronization
import Testing
@testable import MeshServices

/// Records requests and answers them with canned responses.
final class FakeHTTP: Sendable {
    private let requests = Mutex<[URLRequest]>([])
    private let responder: @Sendable (URLRequest) -> (Int, Data)

    init(_ responder: @escaping @Sendable (URLRequest) -> (Int, Data)) {
        self.responder = responder
    }

    var sent: [URLRequest] { requests.withLock { $0 } }

    func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.withLock { $0.append(request) }
        let (status, body) = responder(request)
        // swiftlint:disable:next force_unwrapping
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor
struct InternetMapTests {
    nonisolated static let sampleJSON = Data("""
    [{"public_key":"01000000E030862BEBF148F4BBB972137F7497B9A46B7F35C1681F1849F19AEF","type":2,"adv_name":"Hill Repeater",
      "last_advert":"2026-10-17T21:28:21.000Z","adv_lat":37.75,"adv_lon":-122.45,"inserted_date":"2026-10-14T23:28:57.000Z",
      "updated_date":"2026-10-17T23:28:51.000Z","params":{"freq":910.525,"cr":5,"sf":7,"bw":62.5},"link":"meshcore://1100aabb"},
     {"public_key":"02","type":1,"adv_name":"No position","adv_lat":0,"adv_lon":0},
     {"public_key":"03","type":3,"adv_name":null,"adv_lat":51.5,"adv_lon":-0.1,"params":null,"link":null}]
    """.utf8)

    private func connect() async throws -> (MockRadio, RadioController) {
        let mock = MockRadio(state: MockRadio.demoState)
        let radio = RadioController(defaults: UserDefaults(suiteName: "imap.\(UUID().uuidString)")!, simulatedRadio: mock)
        await radio.connect(to: .simulator)
        try await waitUntil { radio.isConnected }
        return (mock, radio)
    }

    private func cacheURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "imap-\(UUID().uuidString).json")
    }

    @Test func parsesNodesSkippingThoseWithoutPosition() throws {
        let nodes = try InternetMapService.parseNodes(Self.sampleJSON)
        #expect(nodes.count == 2)
        #expect(nodes[0].name == "Hill Repeater")
        #expect(nodes[0].publicKeyHex == "01000000e030862bebf148f4bbb972137f7497b9a46b7f35c1681f1849f19aef")
        #expect(nodes[0].type == .repeater)
        #expect(nodes[0].radio == RadioParameters(frequencyKHz: 910_525, bandwidthHz: 62_500, spreadingFactor: 7, codingRate: 5))
        #expect(nodes[0].advertPacket == Data([0x11, 0x00, 0xAA, 0xBB]))
        #expect(nodes[0].lastAdvert != nil)
        #expect(nodes[1].name == "03")
        #expect(nodes[1].radio == nil)
        #expect(nodes[1].advertPacket == nil)
    }

    @Test func refreshCachesAndFiltersByArea() async throws {
        let (_, radio) = try await connect()
        let http = FakeHTTP { _ in (200, Self.sampleJSON) }
        let cache = cacheURL()
        let service = InternetMapService(radio: radio, cacheURL: cache, fetch: http.fetch)
        await service.refresh()
        #expect(service.nodes.count == 2)
        #expect(service.fetchedAt != nil)
        #expect(service.nodes(latitudes: 37...38, longitudes: -123 ... -122).map(\.name) == ["Hill Repeater"])
        #expect(service.nodes(latitudes: -90...90, longitudes: -180...180, types: [.room]).count == 1)

        try await waitUntil { FileManager.default.fileExists(atPath: cache.path) }
        let reopened = InternetMapService(radio: radio, cacheURL: cache, fetch: http.fetch)
        try await waitUntil { reopened.nodes.count == 2 }
        await radio.disconnect()
    }

    @Test func refreshReportsServerErrors() async throws {
        let (_, radio) = try await connect()
        let http = FakeHTTP { _ in (503, Data(#"{"message":"Down for maintenance"}"#.utf8)) }
        let service = InternetMapService(radio: radio, cacheURL: cacheURL(), fetch: http.fetch)
        await service.refresh()
        #expect(service.lastError == "Down for maintenance")
        #expect(service.nodes.isEmpty)
        await radio.disconnect()
    }

    @Test func importHandsAdvertToRadio() async throws {
        let (mock, radio) = try await connect()
        let service = InternetMapService(radio: radio, cacheURL: cacheURL(), fetch: FakeHTTP { _ in (200, Data()) }.fetch)
        let node = try #require(try InternetMapService.parseNodes(Self.sampleJSON).first)
        try await service.importContact(node)
        #expect(mock.current.importedContacts == [Data([0x11, 0x00, 0xAA, 0xBB])])

        await #expect(throws: InternetMapError.noAdvert) {
            try await service.importContact(InternetMapNode(publicKeyHex: "03", type: .room, name: "x", latitude: 1, longitude: 1))
        }
        await radio.disconnect()
    }

    @Test func uploadSelfSignsDataHashOnRadio() async throws {
        let (mock, radio) = try await connect()
        let http = FakeHTTP { _ in (200, Data(#"{"message":"Node added"}"#.utf8)) }
        let service = InternetMapService(radio: radio, cacheURL: cacheURL(), fetch: http.fetch)
        let message = try await service.uploadSelf()
        #expect(message == "Node added")

        let request = try #require(http.sent.last)
        #expect(request.url == InternetMapService.uploadURL)
        #expect(request.httpMethod == "POST")
        let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String])
        let data = try #require(body["data"])
        #expect(body["publicKey"] == mock.current.selfInfo.publicKey.hex)
        let expected = MockRadio.demoSignature(of: Data(SHA256.hash(data: Data(data.utf8))))
        #expect(body["signature"] == expected.hexString)

        let payload = try #require(try JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any])
        let params = try #require(payload["params"] as? [String: Any])
        #expect(params["sf"] as? Int == Int(mock.current.selfInfo.radio.spreadingFactor))
        let links = try #require(payload["links"] as? [String])
        #expect(links == ["meshcore://" + MockRadio.selfAdvert(for: mock.current).hexString])
        await radio.disconnect()
    }
}
