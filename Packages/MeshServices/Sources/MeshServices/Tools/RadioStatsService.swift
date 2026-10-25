import Foundation
import MeshCoreKit
import Observation

/// The connected radio's counters and a rolling noise-floor history.
@MainActor
@Observable
public final class RadioStatsService {
    public struct NoiseSample: Identifiable, Equatable, Sendable {
        public let id = UUID()
        public var date: Date
        public var noiseFloor: Int16
        public var lastRSSI: Int8
        public var lastSNR: Double
    }

    public private(set) var core: CoreStats?
    public private(set) var radioStats: RadioStats?
    public private(set) var packets: PacketStats?
    public private(set) var samples: [NoiseSample] = []
    public private(set) var isMonitoring = false
    public private(set) var lastError: String?

    /// Samples kept for the chart.
    public static let historyLimit = 300

    @ObservationIgnored private let radio: RadioController
    @ObservationIgnored private var monitorTask: Task<Void, Never>?

    public init(radio: RadioController) {
        self.radio = radio
    }

    public func refresh() async {
        guard let session = await radio.session() else { return }
        do {
            for type in StatsType.allCases {
                switch try await session.getStats(type) {
                case .core(let value): core = value
                case .radio(let value): record(value)
                case .packets(let value): packets = value
                case .unknown: break
                }
            }
            lastError = nil
        } catch {
            lastError = "Couldn't read stats: \(error.readable)"
        }
    }

    /// Polls radio stats for the noise-floor chart until stopped.
    public func startMonitoring(interval: Duration = .seconds(2)) {
        guard monitorTask == nil else { return }
        isMonitoring = true
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                if let session = await self?.radio.session(), case .radio(let value)? = try? await session.getStats(.radio) {
                    self?.record(value)
                }
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
        isMonitoring = false
    }

    public func clearHistory() {
        samples.removeAll()
    }

    private func record(_ value: RadioStats) {
        radioStats = value
        samples.append(NoiseSample(date: Date(), noiseFloor: value.noiseFloorDbm, lastRSSI: value.lastRSSI, lastSNR: value.lastSNR))
        if samples.count > Self.historyLimit { samples.removeFirst(samples.count - Self.historyLimit) }
    }
}
