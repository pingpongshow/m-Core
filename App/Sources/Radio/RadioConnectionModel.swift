import Foundation
import MeshCoreKit
import MeshDesign
import Observation

/// Where to reach a radio.
enum RadioTarget: Codable, Hashable, Sendable {
    case bluetooth(id: UUID, name: String)
    case tcp(host: String, port: UInt16)
    case simulator

    var displayName: String {
        switch self {
        case .bluetooth(_, let name): name
        case .tcp(let host, let port): "\(host):\(port)"
        case .simulator: "Simulated radio"
        }
    }
}

/// Owns the radio connection for the app: scanning, connecting, reconnecting and the handshake result.
@MainActor
@Observable
final class RadioConnectionModel {
    private(set) var state: MeshConnection.State = .idle
    private(set) var target: RadioTarget?
    private(set) var discovered: [DiscoveredRadio] = []
    private(set) var isScanning = false
    private(set) var battery: BatteryAndStorage?

    /// Most recently used target, remembered across launches.
    private(set) var lastTarget: RadioTarget?

    private var connection: MeshConnection?
    private var stateTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    @ObservationIgnored private lazy var scanner = BLEScanner()
    private let simulatedRadio = MockRadio()
    private let defaults: UserDefaults
    private static let lastTargetKey = "radio.lastTarget"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.lastTargetKey) {
            lastTarget = try? JSONDecoder().decode(RadioTarget.self, from: data)
        }
    }

    var connectionInfo: ConnectionInfo? {
        if case .connected(let info) = state { return info }
        return nil
    }

    /// Whether a connection is active or being attempted.
    var isActive: Bool { state != .idle }

    var status: ConnectionStatus {
        switch state {
        case .idle: .disconnected
        case .connecting, .waitingToReconnect: .connecting(name: target?.displayName)
        case .connected(let info): .connected(name: info.selfInfo.name)
        }
    }

    // MARK: Scanning

    func startScan() {
        guard !isScanning else { return }
        isScanning = true
        discovered = []
        let stream = scanner.scan()
        scanTask = Task { [weak self] in
            for await radio in stream {
                self?.upsert(radio)
            }
            self?.isScanning = false
        }
    }

    func stopScan() {
        scanTask?.cancel()
        scanTask = nil
        scanner.stop()
        isScanning = false
    }

    private func upsert(_ radio: DiscoveredRadio) {
        if let index = discovered.firstIndex(where: { $0.id == radio.id }) {
            discovered[index] = radio
        } else {
            discovered.append(radio)
        }
    }

    // MARK: Connecting

    func connect(to target: RadioTarget) async {
        stopScan()
        await disconnect()
        self.target = target
        remember(target)

        let simulatedRadio = simulatedRadio
        let connection = MeshConnection { Self.makeTransport(for: target, simulatedRadio: simulatedRadio) }
        self.connection = connection
        stateTask = Task { [weak self] in
            for await newState in connection.states {
                guard let self else { return }
                self.state = newState
                if case .connected = newState {
                    await self.refreshBattery()
                } else {
                    self.battery = nil
                }
            }
        }
        await connection.start()
    }

    func disconnect() async {
        stateTask?.cancel()
        stateTask = nil
        if let connection {
            await connection.stop()
        }
        connection = nil
        state = .idle
        battery = nil
    }

    func refreshBattery() async {
        guard let session = await connection?.session else { return }
        battery = try? await session.getBatteryAndStorage()
    }

    nonisolated static func makeTransport(for target: RadioTarget, simulatedRadio: MockRadio) -> any MeshTransport {
        switch target {
        case .bluetooth(let id, _): BLETransport(peripheralID: id)
        case .tcp(let host, let port): TCPTransport(host: host, port: port)
        case .simulator: simulatedRadio.makeTransport()
        }
    }

    private func remember(_ target: RadioTarget) {
        lastTarget = target
        if let data = try? JSONEncoder().encode(target) {
            defaults.set(data, forKey: Self.lastTargetKey)
        }
    }
}
