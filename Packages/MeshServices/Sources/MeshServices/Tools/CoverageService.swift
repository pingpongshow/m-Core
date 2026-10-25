import Foundation
import MeshCoreKit
import MeshTools
import Observation

/// Coverage walk: while you move around, records where the mesh can and can't hear you.
///
/// Each interval the phone's position is paired with a trace to a chosen repeater (success and SNR both ways).
/// Packets the radio overhears in between are logged too, so a walk also maps what you can hear.
@MainActor
@Observable
public final class CoverageService: RadioEventHandler {
    public enum Target: Equatable, Sendable {
        /// Ping this repeater by tracing a one-hop path to it.
        case repeater(hashHex: String, name: String)
        /// Only record packets the radio overhears.
        case listenOnly
    }

    public private(set) var isRunning = false
    public private(set) var samples: [CoverageSample] = []
    public private(set) var target: Target = .listenOnly
    public private(set) var lastError: String?

    @ObservationIgnored private let traces: TraceService
    @ObservationIgnored private let location: () -> GeoCoordinate?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var walkTask: Task<Void, Never>?

    /// - Parameter location: The phone's current position, or nil while unknown.
    public init(
        radio: RadioController,
        traces: TraceService,
        location: @escaping () -> GeoCoordinate?,
        now: @escaping () -> Date = { Date() }
    ) {
        self.traces = traces
        self.location = location
        self.now = now
        radio.addHandler(self)
    }

    public var successCount: Int { samples.filter(\.success).count }

    public func start(target: Target, interval: Duration = .seconds(30)) {
        stop()
        self.target = target
        isRunning = true
        lastError = nil
        walkTask = Task { [weak self] in
            while !Task.isCancelled {
                // Without a fix yet (the phone's GPS has only just started), try again shortly, not a whole interval later.
                let pinged = await self?.ping() ?? true
                try? await Task.sleep(for: pinged ? interval : Self.locationRetry)
            }
        }
    }

    public func stop() {
        walkTask?.cancel()
        walkTask = nil
        isRunning = false
    }

    public func clear() {
        samples = []
    }

    /// How soon to try again when there's no location to record a ping at.
    static let locationRetry = Duration.seconds(1)

    /// Records one ping now, outside the regular interval. False when it couldn't, for want of a location.
    @discardableResult
    public func ping() async -> Bool {
        guard case let .repeater(hashHex, name) = target, let hash = Data(hexString: hashHex) else { return true }
        guard let coordinate = location() else {
            lastError = "Waiting for your location."
            return false
        }
        lastError = nil
        let time = now()
        do {
            let outcome = try await traces.trace(path: [[UInt8](hash)])
            let up = outcome.hops.first?.snr
            let note = up.map { "\(name): heard you at \($0.formatted()) dB" } ?? name
            samples.append(CoverageSample(time: time, coordinate: coordinate, snr: outcome.finalSNR, success: true, note: note))
        } catch RemoteRequestError.notConnected, MeshError.notConnected {
            // Without a radio nothing was sent, so this spot isn't a coverage gap.
            lastError = "Radio disconnected. Pings resume when it reconnects."
        } catch {
            samples.append(CoverageSample(time: time, coordinate: coordinate, success: false, note: "\(name): no reply"))
        }
        return true
    }

    public func gpx() -> String {
        CoverageExport.gpx(samples, name: "m-Core coverage \(now().formatted(date: .abbreviated, time: .shortened))")
    }

    public func csv() -> String {
        CoverageExport.csv(samples)
    }

    // MARK: RadioEventHandler

    public func radioDidConnect(_ info: ConnectionInfo, session: MeshSession) async {}

    public func radioDidDisconnect() {
        if isRunning { lastError = "Radio disconnected. Pings resume when it reconnects." }
    }

    public func radioDidReceive(_ push: Push, session: MeshSession) async {
        guard isRunning, case .rxLog(let entry) = push, let coordinate = location() else { return }
        let packet = MeshPacket.decode(entry.raw)
        samples.append(CoverageSample(
            time: now(), coordinate: coordinate, snr: entry.snr, rssi: Int(entry.rssi), success: true,
            note: "Heard \(packet?.payloadType.name ?? "packet")"
        ))
    }
}
