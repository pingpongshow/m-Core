import Foundation
import MeshCoreKit
import Observation

/// Nodes and traffic heard while listening on one preset.
public struct DiscoveryResult: Identifiable, Equatable, Sendable {
    public struct Node: Equatable, Hashable, Sendable {
        public var keyHex: String
        public var name: String
        public var type: AdvertType
    }

    public var id: String { preset.id }
    public var preset: RadioPreset
    public var nodes: [Node]
    public var packetsHeard: Int
    public var bestSNR: Double?
}

/// Local Mesh Discovery: listens on several LoRa presets in turn to find which ones are in use nearby,
/// then always puts the radio back on its original settings.
@MainActor
@Observable
public final class MeshDiscoveryService: RadioEventHandler {
    public enum State: Equatable, Sendable {
        case idle
        case listening(preset: RadioPreset, index: Int, total: Int, endsAt: Date)
        case restoring
        case finished
    }

    public private(set) var state: State = .idle
    public private(set) var results: [DiscoveryResult] = []
    public private(set) var lastError: String?

    @ObservationIgnored private let radio: RadioController
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var current: DiscoveryResult?
    private static let restoreKey = "discovery.restoreRadio"

    public init(radio: RadioController, defaults: UserDefaults = .standard) {
        self.radio = radio
        self.defaults = defaults
        radio.addHandler(self)
    }

    public var isRunning: Bool {
        switch state {
        case .listening, .restoring: true
        default: false
        }
    }

    /// Listens on each preset for `dwell`, then restores the original settings.
    public func start(presets: [RadioPreset], dwell: Duration) {
        guard !isRunning, let original = radio.selfInfo?.radio, !presets.isEmpty else { return }
        saveRestorePoint(original)
        results = []
        lastError = nil
        scanTask = Task { [weak self] in
            await self?.run(presets: presets, dwell: dwell, original: original)
        }
    }

    public func cancel() {
        scanTask?.cancel()
    }

    private func run(presets: [RadioPreset], dwell: Duration, original: RadioParameters) async {
        for (index, preset) in presets.enumerated() {
            guard !Task.isCancelled, let session = await radio.session() else { break }
            do {
                try await session.perform(.setRadioParams(preset.radio))
            } catch {
                lastError = "Couldn't switch to \(preset.name): \(error.readable)"
                continue
            }
            current = DiscoveryResult(preset: preset, nodes: [], packetsHeard: 0, bestSNR: nil)
            state = .listening(preset: preset, index: index, total: presets.count, endsAt: Date().addingTimeInterval(dwell.seconds))
            try? await Task.sleep(for: dwell)
            if let current { results.append(current) }
            current = nil
        }
        state = .restoring
        await restore(original)
        state = .finished
    }

    private func restore(_ original: RadioParameters) async {
        guard let session = await radio.session() else {
            lastError = "The radio disconnected. Its original settings will be restored when it reconnects."
            return
        }
        do {
            try await session.perform(.setRadioParams(original))
            defaults.removeObject(forKey: Self.restoreKey)
            await radio.refreshSelfInfo()
        } catch {
            lastError = "Couldn't restore the original settings: \(error.readable) They'll be restored on next connect."
        }
    }

    private func saveRestorePoint(_ radio: RadioParameters) {
        let values = [radio.frequencyKHz, radio.bandwidthHz, UInt32(radio.spreadingFactor), UInt32(radio.codingRate)]
        defaults.set(values.map(Int.init), forKey: Self.restoreKey)
    }

    private var pendingRestore: RadioParameters? {
        guard let values = defaults.array(forKey: Self.restoreKey) as? [Int], values.count == 4 else { return nil }
        return RadioParameters(
            frequencyKHz: UInt32(values[0]), bandwidthHz: UInt32(values[1]),
            spreadingFactor: UInt8(values[2]), codingRate: UInt8(values[3])
        )
    }

    // MARK: RadioEventHandler

    public func radioDidConnect(_ info: ConnectionInfo, session: MeshSession) async {
        // A scan was interrupted (app quit, link lost): put the radio back.
        if !isRunning, let original = pendingRestore, original != info.selfInfo.radio {
            await restore(original)
        } else if !isRunning {
            defaults.removeObject(forKey: Self.restoreKey)
        }
    }

    public func radioDidDisconnect() {}

    public func radioDidReceive(_ push: Push, session: MeshSession) async {
        guard current != nil else { return }
        switch push {
        case .newAdvert(let contact):
            note(DiscoveryResult.Node(keyHex: contact.publicKey.hex, name: contact.name, type: contact.type))
        case .advert(let key):
            note(DiscoveryResult.Node(keyHex: key.hex, name: key.prefix.hex.uppercased(), type: .none))
        case .rxLog(let entry):
            guard var result = current else { return }
            result.packetsHeard += 1
            result.bestSNR = max(result.bestSNR ?? entry.snr, entry.snr)
            current = result
        default:
            break
        }
    }

    private func note(_ node: DiscoveryResult.Node) {
        guard var result = current else { return }
        if !result.nodes.contains(where: { $0.keyHex == node.keyHex }) { result.nodes.append(node) }
        current = result
    }
}

extension Duration {
    var seconds: TimeInterval {
        TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
