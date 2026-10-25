import Foundation
import MeshCoreKit
import Observation

/// One hop of a completed trace.
public struct TraceHop: Equatable, Hashable, Sendable {
    public var hashHex: String
    /// SNR (dB) this hop measured.
    public var snr: Double
}

public struct TraceOutcome: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public var date: Date
    public var hops: [TraceHop]
    /// SNR (dB) of the last hop back to this radio.
    public var finalSNR: Double
    public var roundTrip: Duration
}

/// Sends a trace along a chosen path of repeaters and reports the SNR at each hop.
@MainActor
@Observable
public final class TraceService: RadioEventHandler {
    public private(set) var history: [TraceOutcome] = []

    @ObservationIgnored private let radio: RadioController
    @ObservationIgnored private let waiter = PushWaiter<TraceResult>()
    @ObservationIgnored private let clock = ContinuousClock()

    public init(radio: RadioController) {
        self.radio = radio
        radio.addHandler(self)
    }

    /// - Parameter path: Repeater hashes in order (1, 2 or 4 bytes each, all the same size).
    public func trace(path: [[UInt8]]) async throws -> TraceOutcome {
        guard let session = await radio.session() else { throw RemoteRequestError.notConnected }
        let hashSize = path.first?.count ?? 1
        let flags: UInt8 = switch hashSize {
        case 2: 1
        case 4: 2
        default: 0
        }
        let tag = UInt32.random(in: 1...UInt32.max)
        let started = clock.now
        let command = Command.sendTracePath(tag: tag, authCode: 0, flags: flags, pathHashes: path.flatMap { $0 })
        let sent = try await session.request(command) { response -> SentInfo? in
            if case .sent(let info) = response { return info }
            return nil
        }
        let result = try await waiter.wait(for: String(tag), timeout: meshTimeout(estimatedMs: sent.estimatedTimeoutMs))
        let hops = zip(result.pathHashes, result.hopSNRs).map { TraceHop(hashHex: Data($0).hexString.uppercased(), snr: $1) }
        let outcome = TraceOutcome(date: Date(), hops: hops, finalSNR: result.finalSNR, roundTrip: clock.now - started)
        history.insert(outcome, at: 0)
        return outcome
    }

    public func radioDidConnect(_ info: ConnectionInfo, session: MeshSession) async {}

    public func radioDidDisconnect() {
        waiter.cancelAll()
    }

    public func radioDidReceive(_ push: Push, session: MeshSession) async {
        if case .traceData(let result) = push {
            waiter.resolve(String(result.tag), with: .success(result))
        }
    }
}
