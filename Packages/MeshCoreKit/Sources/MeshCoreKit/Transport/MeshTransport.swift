import Foundation

/// A link to a companion radio that carries whole protocol frames (BLE, TCP, or a mock).
public protocol MeshTransport: AnyObject, Sendable {
    /// Opens the link. The stream yields complete inbound frames and finishes when the link closes,
    /// throwing if it closed because of an error.
    func open() async throws -> AsyncThrowingStream<Data, Error>
    /// Sends one frame. Callers send one command at a time.
    func send(_ frame: Data) async throws
    /// Closes the link; the inbound stream finishes without an error.
    func close() async
}

public enum TransportError: Error, Equatable, Sendable {
    case notOpen
    case alreadyOpen
    case connectionFailed(String)
    case disconnected(String?)
    case bluetoothUnavailable(String)
    case peripheralNotFound
    case serviceNotFound
    case timedOut
    case frameTooLarge(Int)
}
