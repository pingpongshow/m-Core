import Foundation

/// Supplies ground elevation (metres above sea level) for coordinates.
public protocol ElevationProvider: Sendable {
    /// Elevations in the same order as `coordinates`.
    func elevations(for coordinates: [GeoCoordinate]) async throws -> [Double]
}

public enum ElevationError: Error, Equatable, Sendable {
    case badResponse(String)
    /// The service returned a different number of elevations than requested.
    case countMismatch(expected: Int, received: Int)
}

/// Elevation from the free Open-Meteo API (Copernicus DEM, ~90 m), batched at 100 points per request.
public struct OpenMeteoElevationProvider: ElevationProvider {
    public typealias Fetch = @Sendable (URL) async throws -> Data

    public static let maxPointsPerRequest = 100
    public static let defaultBaseURL = URL(string: "https://api.open-meteo.com/v1/elevation")

    private let baseURL: URL?
    private let fetch: Fetch

    /// - Parameter fetch: loads a URL; defaults to `URLSession.shared`. Inject a stub in tests.
    public init(baseURL: URL? = OpenMeteoElevationProvider.defaultBaseURL, fetch: Fetch? = nil) {
        self.baseURL = baseURL
        self.fetch = fetch ?? { url in
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw ElevationError.badResponse("HTTP \(http.statusCode)")
            }
            return data
        }
    }

    public func elevations(for coordinates: [GeoCoordinate]) async throws -> [Double] {
        var result: [Double] = []
        result.reserveCapacity(coordinates.count)
        for start in stride(from: 0, to: coordinates.count, by: Self.maxPointsPerRequest) {
            let batch = Array(coordinates[start..<min(start + Self.maxPointsPerRequest, coordinates.count)])
            guard let url = requestURL(for: batch) else { throw ElevationError.badResponse("invalid URL") }
            let values = try Self.parse(try await fetch(url))
            guard values.count == batch.count else {
                throw ElevationError.countMismatch(expected: batch.count, received: values.count)
            }
            result += values
        }
        return result
    }

    /// `…/elevation?latitude=a,b&longitude=c,d` with six decimal places.
    public func requestURL(for coordinates: [GeoCoordinate]) -> URL? {
        guard let baseURL, var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "latitude", value: coordinates.map { String(format: "%.6f", $0.latitude) }.joined(separator: ",")),
            URLQueryItem(name: "longitude", value: coordinates.map { String(format: "%.6f", $0.longitude) }.joined(separator: ",")),
        ]
        return components.url
    }

    private struct Response: Decodable {
        var elevation: [Double?]?
        var reason: String?
    }

    static func parse(_ data: Data) throws -> [Double] {
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw ElevationError.badResponse("unreadable JSON")
        }
        guard let values = response.elevation else {
            throw ElevationError.badResponse(response.reason ?? "missing elevation")
        }
        // Open-Meteo reports sea/no-data points as null; treat them as sea level.
        return values.map { $0 ?? 0 }
    }
}
