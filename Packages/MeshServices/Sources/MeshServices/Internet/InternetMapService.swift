import CryptoKit
import Foundation
import MeshCoreKit
import Observation

/// A node listed on the MeshCore Internet Map (map.meshcore.io).
public struct InternetMapNode: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String { publicKeyHex }
    public var publicKeyHex: String
    public var type: AdvertType
    public var name: String
    public var latitude: Double
    public var longitude: Double
    public var lastAdvert: Date?
    public var updated: Date?
    public var radio: RadioParameters?
    /// `meshcore://<advert packet hex>`: importing it adds the node as a contact.
    public var link: String?

    public init(
        publicKeyHex: String, type: AdvertType, name: String, latitude: Double, longitude: Double,
        lastAdvert: Date? = nil, updated: Date? = nil, radio: RadioParameters? = nil, link: String? = nil
    ) {
        self.publicKeyHex = publicKeyHex
        self.type = type
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.lastAdvert = lastAdvert
        self.updated = updated
        self.radio = radio
        self.link = link
    }

    /// The advert packet inside `link`.
    public var advertPacket: Data? {
        guard let link, link.hasPrefix(InternetMapService.linkPrefix) else { return nil }
        return Data(hexString: String(link.dropFirst(InternetMapService.linkPrefix.count)))
    }

    private enum CodingKeys: String, CodingKey {
        case publicKeyHex, type, name, latitude, longitude, lastAdvert, updated, link
        case frequencyKHz, bandwidthHz, spreadingFactor, codingRate
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        publicKeyHex = try c.decode(String.self, forKey: .publicKeyHex)
        type = AdvertType(rawValue: try c.decode(UInt8.self, forKey: .type))
        name = try c.decode(String.self, forKey: .name)
        latitude = try c.decode(Double.self, forKey: .latitude)
        longitude = try c.decode(Double.self, forKey: .longitude)
        lastAdvert = try c.decodeIfPresent(Date.self, forKey: .lastAdvert)
        updated = try c.decodeIfPresent(Date.self, forKey: .updated)
        link = try c.decodeIfPresent(String.self, forKey: .link)
        if let frequency = try c.decodeIfPresent(UInt32.self, forKey: .frequencyKHz),
           let bandwidth = try c.decodeIfPresent(UInt32.self, forKey: .bandwidthHz),
           let sf = try c.decodeIfPresent(UInt8.self, forKey: .spreadingFactor),
           let cr = try c.decodeIfPresent(UInt8.self, forKey: .codingRate) {
            radio = RadioParameters(frequencyKHz: frequency, bandwidthHz: bandwidth, spreadingFactor: sf, codingRate: cr)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(publicKeyHex, forKey: .publicKeyHex)
        try c.encode(type.rawValue, forKey: .type)
        try c.encode(name, forKey: .name)
        try c.encode(latitude, forKey: .latitude)
        try c.encode(longitude, forKey: .longitude)
        try c.encodeIfPresent(lastAdvert, forKey: .lastAdvert)
        try c.encodeIfPresent(updated, forKey: .updated)
        try c.encodeIfPresent(link, forKey: .link)
        try c.encodeIfPresent(radio?.frequencyKHz, forKey: .frequencyKHz)
        try c.encodeIfPresent(radio?.bandwidthHz, forKey: .bandwidthHz)
        try c.encodeIfPresent(radio?.spreadingFactor, forKey: .spreadingFactor)
        try c.encodeIfPresent(radio?.codingRate, forKey: .codingRate)
    }
}

public enum InternetMapError: Error, Equatable, Sendable, CustomStringConvertible {
    case notConnected
    case noAdvert
    case server(status: Int, message: String?)
    case badResponse

    public var description: String {
        switch self {
        case .notConnected: "Connect your radio first."
        case .noAdvert: "This node's map entry has no advert to import."
        case let .server(status, message): message ?? "The map server answered with HTTP \(status)."
        case .badResponse: "The map server sent something unexpected."
        }
    }
}

/// The MeshCore Internet Map: browse listed repeaters and rooms (cached for offline use), add them as contacts
/// before you're in range, and add your radio or a repeater you heard. Upload requests are signed by the radio,
/// so its private key never leaves it. Nothing is sent unless the user asks.
@MainActor
@Observable
public final class InternetMapService {
    public static let nodesURL = URL(string: "https://map.meshcore.io/api/v1/nodes")! // swiftlint:disable:this force_unwrapping
    public static let uploadURL = URL(string: "https://map.meshcore.io/api/v1/uploader/node")! // swiftlint:disable:this force_unwrapping
    nonisolated static let linkPrefix = "meshcore://"

    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public private(set) var nodes: [InternetMapNode] = []
    public private(set) var fetchedAt: Date?
    public private(set) var isLoading = false
    public private(set) var lastError: String?

    @ObservationIgnored private let radio: RadioController
    @ObservationIgnored private let cacheURL: URL
    @ObservationIgnored private let fetch: Fetch

    public init(
        radio: RadioController,
        cacheURL: URL = URL.cachesDirectory.appending(path: "internet-map.json"),
        fetch: @escaping Fetch = { try await URLSession.shared.data(for: $0) }
    ) {
        self.radio = radio
        self.cacheURL = cacheURL
        self.fetch = fetch
        Task { await loadCache() }
    }

    /// Nodes inside a latitude/longitude box, optionally of one type.
    public func nodes(
        latitudes: ClosedRange<Double>, longitudes: ClosedRange<Double>, types: Set<AdvertType>? = nil
    ) -> [InternetMapNode] {
        nodes.filter {
            latitudes.contains($0.latitude) && longitudes.contains($0.longitude) && (types?.contains($0.type) ?? true)
        }
    }

    /// Downloads the whole list (about 18 MB) and caches it.
    public func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        lastError = nil
        defer { isLoading = false }
        do {
            var request = URLRequest(url: Self.nodesURL)
            request.timeoutInterval = 120
            let (data, response) = try await fetch(request)
            try Self.check(response, data: data)
            let parsed = try await Task.detached(priority: .userInitiated) { try Self.parseNodes(data) }.value
            nodes = parsed
            fetchedAt = Date()
            let cache = Cache(fetchedAt: fetchedAt ?? Date(), nodes: parsed)
            let url = cacheURL
            Task.detached(priority: .utility) {
                try? JSONEncoder().encode(cache).write(to: url, options: .atomic)
            }
        } catch {
            lastError = (error as? InternetMapError)?.description ?? "Couldn't load the Internet Map. Check your connection."
        }
    }

    /// Adds a listed node as a contact by handing its signed advert to the radio, which checks the signature.
    public func importContact(_ node: InternetMapNode) async throws {
        guard let packet = node.advertPacket else { throw InternetMapError.noAdvert }
        guard let session = await radio.session() else { throw InternetMapError.notConnected }
        try await session.perform(.importContact(packet))
    }

    /// Lists the connected radio on the map, using its own signed advert and current radio settings.
    @discardableResult
    public func uploadSelf() async throws -> String? {
        guard let session = await radio.session() else { throw InternetMapError.notConnected }
        let advert = try await session.request(.exportContact(nil)) {
            if case .exportedContact(let packet) = $0 { return packet }
            return nil
        }
        return try await upload(advertPacket: advert)
    }

    /// Lists a node from an advert packet the radio heard (e.g. a repeater in the RX log).
    @discardableResult
    public func upload(advertPacket: Data) async throws -> String? {
        guard let session = await radio.session(), let info = radio.connectionInfo else { throw InternetMapError.notConnected }
        let body = try await Self.uploadBody(advertPacket: advertPacket, radio: info.selfInfo.radio,
                                       uploaderKey: info.selfInfo.publicKey) { try await session.sign($0) }
        var request = URLRequest(url: Self.uploadURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await fetch(request)
        try Self.check(response, data: data)
        return Self.message(in: data)
    }

    // MARK: Wire format

    /// `{"data": <json string>, "signature": <hex>, "publicKey": <hex>}`, where the signature is the uploader's
    /// Ed25519 signature over SHA-256 of the data string (as the map's own uploader sends it).
    static func uploadBody(
        advertPacket: Data, radio: RadioParameters, uploaderKey: PublicKey,
        sign: (Data) async throws -> Data
    ) async throws -> Data {
        let payload: [String: Any] = [
            "params": [
                "freq": Double(radio.frequencyKHz) / 1000,
                "cr": Int(radio.codingRate),
                "sf": Int(radio.spreadingFactor),
                "bw": Double(radio.bandwidthHz) / 1000,
            ],
            "links": [linkPrefix + advertPacket.hexString],
        ]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]),
                          as: UTF8.self)
        let signature = try await sign(Data(SHA256.hash(data: Data(json.utf8))))
        let body: [String: String] = ["data": json, "signature": signature.hexString, "publicKey": uploaderKey.hex]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    nonisolated static func parseNodes(_ data: Data) throws -> [InternetMapNode] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        // Entries are community-submitted: one malformed node must not throw away the whole list.
        let decoded = try decoder.decode([Lossy<APINode>].self, from: data).compactMap(\.value)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        let date = { (text: String) in fractional.date(from: text) ?? whole.date(from: text) }
        return decoded.compactMap { node in
            guard let lat = node.advLat, let lon = node.advLon, lat != 0 || lon != 0 else { return nil }
            var radio: RadioParameters?
            if let p = node.params, let freq = p.freq, let bw = p.bw, let sf = p.sf, let cr = p.cr {
                radio = RadioParameters(frequencyKHz: UInt32((freq * 1000).rounded()), bandwidthHz: UInt32((bw * 1000).rounded()),
                                        spreadingFactor: UInt8(clamping: sf), codingRate: UInt8(clamping: cr))
            }
            return InternetMapNode(
                publicKeyHex: node.publicKey.lowercased(), type: AdvertType(rawValue: UInt8(clamping: node.type)),
                name: node.advName ?? String(node.publicKey.prefix(8)), latitude: lat, longitude: lon,
                lastAdvert: node.lastAdvert.flatMap(date),
                updated: node.updatedDate.flatMap(date),
                radio: radio, link: node.link
            )
        }
    }

    private static func check(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw InternetMapError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw InternetMapError.server(status: http.statusCode, message: message(in: data))
        }
    }

    private static func message(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (object["message"] ?? object["error"] ?? object["status"]) as? String
    }

    // MARK: Cache

    private struct Cache: Codable {
        var fetchedAt: Date
        var nodes: [InternetMapNode]
    }

    /// Reads the cached list off the main thread; a fresh download that finished first wins.
    func loadCache() async {
        let url = cacheURL
        let cache = await Task.detached(priority: .utility) { () -> Cache? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(Cache.self, from: data)
        }.value
        guard let cache, fetchedAt == nil else { return }
        nodes = cache.nodes
        fetchedAt = cache.fetchedAt
    }
}

/// Decodes a value, or nil when that one value is malformed.
private struct Lossy<Value: Decodable>: Decodable {
    var value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}

/// One entry of `GET /api/v1/nodes` (snake_case on the wire).
private struct APINode: Decodable {
    var publicKey: String
    var type: Int
    var advName: String?
    var advLat: Double?
    var advLon: Double?
    var lastAdvert: String?
    var updatedDate: String?
    var params: APINodeParams?
    var link: String?
}

private struct APINodeParams: Decodable {
    var freq: Double?
    var cr: Int?
    var sf: Int?
    var bw: Double?
}
