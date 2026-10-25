import Foundation

/// Reads byte ranges from an archive. Implementations may return fewer bytes only when the range passes end of file.
public protocol RangeFetcher: Sendable {
    func fetch(offset: UInt64, length: UInt64) async throws -> Data
}

/// Minimal HTTP transport so networking can be faked in tests.
public protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// ``HTTPClient`` backed by `URLSession`.
public struct URLSessionHTTPClient: HTTPClient {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RangeFetchError.notHTTP }
        return (data, http)
    }
}

/// Failures specific to ranged HTTP reads.
public enum RangeFetchError: Error, Sendable, Equatable {
    case notHTTP
    /// The server answered 200 instead of 206 (range requests unsupported).
    case rangeNotSupported
    /// The remote file changed mid-download (ETag mismatch or 412).
    case resourceChanged
    case unexpectedStatus(Int)
    /// `Content-Range` starts somewhere other than the requested offset.
    case rangeMismatch
    /// The response was shorter than requested without reaching end of file.
    case shortRead(expected: UInt64, received: UInt64)
}

/// Fetches ranges over HTTP with `Range: bytes=a-b`, requiring 206 responses.
///
/// When ETag validation is on, the first strong ETag seen (or `expectedETag`) is sent as `If-Match`
/// and compared against every response, so a daily build replaced mid-download fails instead of mixing files.
public actor HTTPRangeFetcher: RangeFetcher {
    nonisolated public let url: URL
    private let client: any HTTPClient
    private let validatesETag: Bool
    private var etag: String?

    public init(url: URL, client: any HTTPClient = URLSessionHTTPClient(), expectedETag: String? = nil, validatesETag: Bool = true) {
        self.url = url
        self.client = client
        self.validatesETag = validatesETag
        self.etag = expectedETag
    }

    public func fetch(offset: UInt64, length: UInt64) async throws -> Data {
        guard length > 0 else { return Data() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("bytes=\(offset)-\(offset + length - 1)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if validatesETag, let etag, !etag.hasPrefix("W/") {
            request.setValue(etag, forHTTPHeaderField: "If-Match")
        }
        let (data, response) = try await client.send(request)
        switch response.statusCode {
        case 206: break
        case 200: throw RangeFetchError.rangeNotSupported
        case 412: throw RangeFetchError.resourceChanged
        default: throw RangeFetchError.unexpectedStatus(response.statusCode)
        }
        if validatesETag, let responseTag = response.value(forHTTPHeaderField: "ETag") {
            if let etag, etag != responseTag { throw RangeFetchError.resourceChanged }
            etag = responseTag
        }
        let contentRange = response.value(forHTTPHeaderField: "Content-Range")
        if let start = Self.startOffset(contentRange: contentRange), start != offset {
            throw RangeFetchError.rangeMismatch
        }
        let received = UInt64(data.count)
        if received > length { return data.prefix(Int(length)) }
        if received < length {
            guard let total = Self.totalLength(contentRange: contentRange), offset + received >= total else {
                throw RangeFetchError.shortRead(expected: length, received: received)
            }
        }
        return data
    }

    /// Parses `a` from `bytes a-b/total`.
    static func startOffset(contentRange: String?) -> UInt64? {
        guard let contentRange, let space = contentRange.firstIndex(of: " "),
              let dash = contentRange.firstIndex(of: "-") else { return nil }
        return UInt64(contentRange[contentRange.index(after: space)..<dash])
    }

    /// Parses the complete length from `bytes a-b/total`.
    static func totalLength(contentRange: String?) -> UInt64? {
        guard let contentRange, let slash = contentRange.lastIndex(of: "/") else { return nil }
        return UInt64(contentRange[contentRange.index(after: slash)...].trimmingCharacters(in: .whitespaces))
    }
}

/// Reads ranges from a local file (tests, or archives already on disk).
public struct FileRangeFetcher: RangeFetcher {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func fetch(offset: UInt64, length: UInt64) async throws -> Data {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: Int(clamping: length)) ?? Data()
    }
}
