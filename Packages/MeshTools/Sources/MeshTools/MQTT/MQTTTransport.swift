import Foundation

/// A byte pipe to an MQTT broker. Implementations deliver whatever chunks arrive;
/// the client handles framing.
public protocol MQTTTransport: Sendable {
    /// Opens the connection; returns once bytes can be sent.
    func open() async throws
    func send(_ data: Data) async throws
    /// Waits for the next chunk of bytes. Returns nil once the connection has closed cleanly.
    func receive() async throws -> Data?
    func close() async
}

/// Where and how to reach a broker.
public struct MQTTEndpoint: Equatable, Hashable, Sendable {
    public enum Kind: Equatable, Hashable, Sendable {
        case tcp
        case tls
        /// `ws://host:port/path`, subprotocol "mqtt", binary frames.
        case webSocket(path: String)
        /// `wss://host:port/path`.
        case secureWebSocket(path: String)
    }

    public var host: String
    public var port: UInt16
    public var kind: Kind

    public init(host: String, port: UInt16, kind: Kind) {
        self.host = host
        self.port = port
        self.kind = kind
    }

    /// The URL a WebSocket endpoint connects to; nil for raw TCP/TLS.
    public var webSocketURL: URL? {
        let scheme: String
        let path: String
        switch kind {
        case .tcp, .tls: return nil
        case .webSocket(let value): (scheme, path) = ("ws", value)
        case .secureWebSocket(let value): (scheme, path) = ("wss", value)
        }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = Int(port)
        components.path = path.hasPrefix("/") ? path : "/" + path
        return components.url
    }

    public var usesTLS: Bool {
        switch kind {
        case .tls, .secureWebSocket: true
        case .tcp, .webSocket: false
        }
    }
}

/// Errors from a transport.
public enum MQTTTransportError: Error, Equatable, Sendable {
    case notOpen
    case invalidEndpoint
    case connectionFailed(String)
    case cancelled
}
