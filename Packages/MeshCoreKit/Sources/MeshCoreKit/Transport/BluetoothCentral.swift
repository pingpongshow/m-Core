@preconcurrency import CoreBluetooth
import Foundation
import Synchronization

/// Whether this process has created a `CBCentralManager` yet. AccessorySetupKit can only migrate radios found with
/// CoreBluetooth into its accessory list before the app's first central manager exists.
public enum CoreBluetoothUsage {
    private static let created = Atomic<Bool>(false)

    public static var hasCreatedCentralManager: Bool { created.load(ordering: .relaxed) }

    static func markCreated() {
        created.store(true, ordering: .relaxed)
    }
}

/// Receives events from the process-wide central manager. Every call arrives on `BluetoothCentral.queue`.
///
/// Events are broadcast to all clients, so a client that cares about one radio filters by peripheral identifier.
protocol BluetoothCentralClient: AnyObject {
    func centralDidUpdateState(_ central: CBCentralManager)
    func central(_ central: CBCentralManager, didConnect peripheral: CBPeripheral)
    func central(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?)
    func central(_ central: CBCentralManager, didDisconnect peripheral: CBPeripheral, error: Error?)
    func central(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi: NSNumber
    )
    func centralWillRestore(_ peripherals: [CBPeripheral])
}

extension BluetoothCentralClient {
    func centralDidUpdateState(_ central: CBCentralManager) {}
    func central(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {}
    func central(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {}
    func central(_ central: CBCentralManager, didDisconnect peripheral: CBPeripheral, error: Error?) {}
    func central(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi: NSNumber
    ) {}
    func centralWillRestore(_ peripherals: [CBPeripheral]) {}
}

/// The one `CBCentralManager` the app ever creates, shared by the scanner and every connection.
///
/// Two iOS rules make a single long-lived manager necessary:
/// - A process gets one state-restoration identifier. A second manager created with the same
///   `CBCentralManagerOptionRestoreIdentifierKey` is not a fresh start: CoreBluetooth ignores it and never reports
///   `poweredOn`, so reconnecting by building a new manager per attempt fails from the second attempt on.
/// - With AccessorySetupKit the manager reports only `poweredOn` or `poweredOff`, and it stays `poweredOff` until an
///   authorized accessory is actually reachable. The manager therefore has to outlive a single connection attempt and
///   be given time to settle; see `BLETransport.connectIfReady()`.
///
/// Concurrency: all CoreBluetooth state is confined to `queue`, which is also the delegate queue.
final class BluetoothCentral: NSObject, @unchecked Sendable {
    static let shared = BluetoothCentral()

    /// Owns every CoreBluetooth object in the app, and is the delegate queue for the shared manager.
    let queue = DispatchQueue(label: "app.mcore.ble")

    private var central: CBCentralManager?
    private var restoreIdentifier: String?
    private var clients: [WeakClient] = []
    private var wantsScan = false

    private struct WeakClient {
        weak var client: (any BluetoothCentralClient)?
    }

    override private init() {
        super.init()
    }

    /// Sets the state-restoration key to create the manager with. Ignored once the manager exists, so the app sets it
    /// at launch, before any scan or connection.
    func setRestoreIdentifier(_ identifier: String?) {
        guard let identifier else { return }
        queue.async {
            guard self.central == nil else { return }
            self.restoreIdentifier = identifier
        }
    }

    /// Registers a client, creating the manager on first use. Must run on `queue`.
    @discardableResult
    func add(_ client: any BluetoothCentralClient) -> CBCentralManager {
        clients.removeAll { $0.client == nil || $0.client === client }
        clients.append(WeakClient(client: client))
        return manager()
    }

    /// Must run on `queue`.
    func remove(_ client: any BluetoothCentralClient) {
        clients.removeAll { $0.client == nil || $0.client === client }
    }

    /// The shared manager, created on first use. Must run on `queue`.
    @discardableResult
    func manager() -> CBCentralManager {
        if let central { return central }
        var options: [String: Any] = [:]
        if let restoreIdentifier {
            options[CBCentralManagerOptionRestoreIdentifierKey] = restoreIdentifier
        }
        CoreBluetoothUsage.markCreated()
        let created = CBCentralManager(delegate: self, queue: queue, options: options)
        central = created
        return created
    }

    // MARK: Scanning

    /// Starts scanning, or remembers to start once the manager powers on. Must run on `queue`.
    func startScanning() {
        wantsScan = true
        scanIfPossible()
    }

    /// Must run on `queue`.
    func stopScanning() {
        wantsScan = false
        central?.stopScan()
    }

    private func scanIfPossible() {
        guard wantsScan, let central, central.state == .poweredOn, !central.isScanning else { return }
        // No service filter: companion radios are matched by advertised service or name in `BLEScanner`, and with
        // AccessorySetupKit the scan only ever returns radios the user authorized for the app anyway.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    /// Radios already connected to this phone by any app, which never appear in a scan. Must run on `queue`.
    func connectedRadios() -> [CBPeripheral] {
        central?.retrieveConnectedPeripherals(withServices: [MeshCoreProtocol.BLE.service]) ?? []
    }

    /// The peripheral for `id`, if the system still knows it. Must run on `queue`.
    func peripheral(for id: UUID) -> CBPeripheral? {
        central?.retrievePeripherals(withIdentifiers: [id]).first
    }

    private func liveClients() -> [any BluetoothCentralClient] {
        clients.compactMap(\.client)
    }
}

extension BluetoothCentral: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        scanIfPossible()
        liveClients().forEach { $0.centralDidUpdateState(central) }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        liveClients().forEach { $0.centralWillRestore(restored) }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        liveClients().forEach {
            $0.central(central, didDiscover: peripheral, advertisementData: advertisementData, rssi: RSSI)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        liveClients().forEach { $0.central(central, didConnect: peripheral) }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        liveClients().forEach { $0.central(central, didFailToConnect: peripheral, error: error) }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        liveClients().forEach { $0.central(central, didDisconnect: peripheral, error: error) }
    }
}
