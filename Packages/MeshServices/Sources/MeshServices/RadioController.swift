import Foundation
import MeshCoreKit
import Observation

/// Where to reach a radio.
public enum RadioTarget: Codable, Hashable, Sendable {
    case bluetooth(id: UUID, name: String)
    case tcp(host: String, port: UInt16)
    case simulator

    public var displayName: String {
        switch self {
        case .bluetooth(_, let name): name
        case .tcp(let host, let port): "\(host):\(port)"
        case .simulator: "Simulated radio"
        }
    }
}

/// Services that react to the radio connecting, disconnecting and pushing frames.
@MainActor
public protocol RadioEventHandler: AnyObject {
    func radioDidConnect(_ info: ConnectionInfo, session: MeshSession) async
    func radioDidDisconnect()
    func radioDidReceive(_ push: Push, session: MeshSession) async
}

/// Decides which Bluetooth radios CoreBluetooth may touch. With AccessorySetupKit, only radios the user authorized in the
/// accessory picker are reachable, and asking CoreBluetooth for any other peripheral can terminate the app.
@MainActor
public protocol BluetoothAccessAuthority: AnyObject {
    /// Waits until the authority knows which radios are authorized.
    func ready() async
    /// False when this peripheral must not be connected (not authorized for the app).
    func mayConnect(to peripheralID: UUID) -> Bool
    /// Withdraws the app's access to a forgotten radio (and its system pairing) where the system supports it.
    func forget(peripheralID: UUID) async
}

/// Owns the radio connection for the app: scanning, connecting, reconnecting, the handshake result,
/// and fan-out of connection events and pushes to services.
@MainActor
@Observable
public final class RadioController {
    public private(set) var state: MeshConnection.State = .idle
    public private(set) var target: RadioTarget?
    public private(set) var discovered: [DiscoveredRadio] = []
    public private(set) var isScanning = false
    public private(set) var battery: BatteryAndStorage?
    /// Latest identity and settings reported by the radio; refreshed after changes.
    public private(set) var selfInfo: SelfInfo?
    /// Most recently used target, remembered across launches.
    public private(set) var lastTarget: RadioTarget?
    /// Radios this phone has connected to, most recent first.
    public private(set) var knownRadios: [KnownRadio] = []
    /// Why the last connect couldn't start (e.g. a Bluetooth radio that needs adding again); cleared on the next attempt.
    public private(set) var connectionProblem: String?
    /// True when the most recent disconnect was asked for (``disconnect()`` or switching radios), false when the link dropped.
    public private(set) var lastDisconnectWasRequested = false
    /// Set by the app when AccessorySetupKit manages Bluetooth access.
    @ObservationIgnored public var bluetoothAccess: (any BluetoothAccessAuthority)?

    private var connection: MeshConnection?
    private var stateTask: Task<Void, Never>?
    private var pushTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    @ObservationIgnored private lazy var scanner = BLEScanner()
    @ObservationIgnored private var handlers: [WeakHandler] = []
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let restoreIdentifier: String?
    /// The in-process test radio. Nil in the app, which offers no simulated radio; tests and previews pass one.
    @ObservationIgnored public let simulatedRadio: MockRadio?
    @ObservationIgnored private let knownStore: KnownRadiosStore
    @ObservationIgnored private let now: () -> Date
    private static let lastTargetKey = "radio.lastTarget"

    private struct WeakHandler {
        weak var handler: (any RadioEventHandler)?
    }

    /// - Parameter restoreIdentifier: CoreBluetooth state-restoration key, so iOS can relaunch the app for radio events.
    public init(
        defaults: UserDefaults = .standard,
        restoreIdentifier: String? = nil,
        simulatedRadio: MockRadio? = nil,
        now: @escaping () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.restoreIdentifier = restoreIdentifier
        self.simulatedRadio = simulatedRadio
        self.now = now
        knownStore = KnownRadiosStore(defaults: defaults)
        if let data = defaults.data(forKey: Self.lastTargetKey) {
            lastTarget = try? JSONDecoder().decode(RadioTarget.self, from: data)
        }
        // A development build may have saved the simulated radio as the last one; never reconnect to it here.
        if lastTarget == .simulator, simulatedRadio == nil {
            lastTarget = nil
            defaults.removeObject(forKey: Self.lastTargetKey)
        }
        knownRadios = knownStore.load()
        // Radios used before the known-radios list existed.
        if knownRadios.isEmpty, let lastTarget {
            knownRadios = knownStore.add(lastTarget, radioName: nil)
        }
    }

    public var connectionInfo: ConnectionInfo? {
        if case .connected(let info) = state { return info }
        return nil
    }

    public var isConnected: Bool { connectionInfo != nil }
    /// Whether a connection is active or being attempted.
    public var isActive: Bool { state != .idle }

    /// The live session, when connected.
    public func session() async -> MeshSession? {
        await connection?.session
    }

    public func addHandler(_ handler: any RadioEventHandler) {
        handlers.removeAll { $0.handler == nil || $0.handler === handler }
        handlers.append(WeakHandler(handler: handler))
    }

    // MARK: Scanning

    public func startScan() {
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

    public func stopScan() {
        scanTask?.cancel()
        scanTask = nil
        if isScanning { scanner.stop() }
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

    public func connect(to target: RadioTarget) async {
        guard target != .simulator || simulatedRadio != nil else {
            connectionProblem = "There's no simulated radio in this build."
            return
        }
        stopScan()
        await disconnect()
        connectionProblem = nil
        if case .bluetooth(let id, _) = target, let bluetoothAccess {
            await bluetoothAccess.ready()
            guard bluetoothAccess.mayConnect(to: id) else {
                connectionProblem = "\(target.displayName) isn't set up on this iPhone yet. Add it again with Add radio."
                return
            }
        }
        self.target = target
        remember(target)

        let simulatedRadio = simulatedRadio
        let restoreIdentifier = restoreIdentifier
        let connection = MeshConnection {
            Self.makeTransport(for: target, simulatedRadio: simulatedRadio, restoreIdentifier: restoreIdentifier)
        }
        self.connection = connection
        stateTask = Task { [weak self] in
            for await newState in connection.states {
                await self?.apply(newState, connection: connection)
            }
        }
        pushTask = Task { [weak self] in
            for await push in connection.pushes {
                guard let self, let session = await connection.session else { continue }
                await self.dispatch(push, session: session)
            }
        }
        await connection.start()
    }

    /// Reconnects to the last radio, if any.
    public func reconnectToLast() async {
        guard let lastTarget, !isActive else { return }
        await connect(to: lastTarget)
    }

    public func disconnect() async {
        stateTask?.cancel()
        pushTask?.cancel()
        stateTask = nil
        pushTask = nil
        let wasConnected = isConnected
        if let connection {
            await connection.stop()
        }
        connection = nil
        state = .idle
        battery = nil
        selfInfo = nil
        if wasConnected {
            lastDisconnectWasRequested = true
            notifyDisconnect()
        }
    }

    private func apply(_ newState: MeshConnection.State, connection: MeshConnection) async {
        let wasConnected = isConnected
        state = newState
        switch newState {
        case .connected(let info):
            selfInfo = info.selfInfo
            lastDisconnectWasRequested = false
            if let target { knownRadios = knownStore.recordConnection(to: target, radioName: info.selfInfo.name, at: now()) }
            guard let session = await connection.session else { return }
            for handler in liveHandlers() {
                await handler.radioDidConnect(info, session: session)
            }
            await refreshBattery()
        default:
            battery = nil
            if wasConnected {
                lastDisconnectWasRequested = false
                notifyDisconnect()
            }
        }
    }

    private func dispatch(_ push: Push, session: MeshSession) async {
        for handler in liveHandlers() {
            await handler.radioDidReceive(push, session: session)
        }
    }

    private func notifyDisconnect() {
        liveHandlers().forEach { $0.radioDidDisconnect() }
    }

    private func liveHandlers() -> [any RadioEventHandler] {
        handlers.compactMap(\.handler)
    }

    // MARK: Known radios

    /// Remembers a radio without connecting, e.g. one just authorized in the accessory picker.
    public func addKnownRadio(_ target: RadioTarget, name: String?) {
        knownRadios = knownStore.add(target, radioName: name)
    }

    /// Sets the user's own name for a known radio; an empty name restores the radio's.
    public func renameKnownRadio(_ radio: KnownRadio, to name: String) {
        knownRadios = knownStore.rename(id: radio.id, to: name)
    }

    /// Removes a radio from the list (and, with AccessorySetupKit, from the app's authorized accessories).
    public func forgetKnownRadio(_ radio: KnownRadio) async {
        if target == radio.target, isActive { await disconnect() }
        knownRadios = knownStore.forget(id: radio.id)
        if lastTarget == radio.target {
            lastTarget = nil
            defaults.removeObject(forKey: Self.lastTargetKey)
        }
        if case .bluetooth(let id, _) = radio.target {
            await bluetoothAccess?.forget(peripheralID: id)
        }
    }

    // MARK: Battery

    /// The connected radio's battery type, chosen per radio (Li-ion by default).
    public var batteryChemistry: BatteryChemistry {
        guard let key = selfInfo?.publicKey.hex else { return .lithiumIon }
        _ = chemistryRevision
        return defaults.string(forKey: Self.chemistryKey(key)).flatMap(BatteryChemistry.init(rawValue:)) ?? .lithiumIon
    }

    public func setBatteryChemistry(_ chemistry: BatteryChemistry) {
        guard let key = selfInfo?.publicKey.hex else { return }
        defaults.set(chemistry.rawValue, forKey: Self.chemistryKey(key))
        chemistryRevision += 1
    }

    /// Estimated charge of the connected radio's battery, from its voltage and chemistry.
    public var batteryPercent: Int? {
        battery.flatMap { batteryChemistry.percent(millivolts: Int($0.millivolts)) }
    }

    private var chemistryRevision = 0

    private static func chemistryKey(_ radioKey: String) -> String { "radio.batteryChemistry.\(radioKey)" }

    // MARK: Radio info

    public func refreshBattery() async {
        guard let session = await session() else { return }
        battery = try? await session.getBatteryAndStorage()
    }

    /// Re-reads the radio's identity and settings (`SELF_INFO`).
    @discardableResult
    public func refreshSelfInfo() async -> SelfInfo? {
        guard let session = await session(), let info = try? await session.appStart(appName: "m-Core") else { return selfInfo }
        selfInfo = info
        return info
    }

    nonisolated public static func makeTransport(
        for target: RadioTarget,
        simulatedRadio: MockRadio?,
        restoreIdentifier: String? = nil
    ) -> any MeshTransport {
        switch target {
        case .bluetooth(let id, _): BLETransport(peripheralID: id, restoreIdentifier: restoreIdentifier)
        case .tcp(let host, let port): TCPTransport(host: host, port: port)
        case .simulator: simulatedRadio?.makeTransport() ?? UnavailableTransport()
        }
    }

    private func remember(_ target: RadioTarget) {
        lastTarget = target
        if let data = try? JSONEncoder().encode(target) {
            defaults.set(data, forKey: Self.lastTargetKey)
        }
    }
}

/// Stands in for the simulated radio when the build has none: opening it fails.
final class UnavailableTransport: MeshTransport {
    func open() async throws -> AsyncThrowingStream<Data, Error> {
        throw TransportError.connectionFailed("There's no simulated radio in this build.")
    }

    func send(_ frame: Data) async throws {
        throw TransportError.notOpen
    }

    func close() async {}
}
