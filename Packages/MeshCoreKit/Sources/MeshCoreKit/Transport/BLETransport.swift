@preconcurrency import CoreBluetooth
import Foundation

/// A companion radio seen during a BLE scan.
public struct DiscoveredRadio: Identifiable, Hashable, Sendable {
    /// CoreBluetooth peripheral identifier; stable per phone, used to reconnect.
    public let id: UUID
    public let name: String
    public let rssi: Int
}

extension MeshCoreProtocol.BLE {
    static let service = CBUUID(string: serviceUUID)
    static let rx = CBUUID(string: rxCharacteristicUUID)
    static let tx = CBUUID(string: txCharacteristicUUID)
}

/// Scans for companion radios: anything advertising the Nordic UART service or named "MeshCore…",
/// plus radios already connected to this phone.
///
/// Concurrency: all CoreBluetooth state is confined to `BluetoothCentral.shared.queue`, which is also the delegate queue.
public final class BLEScanner: NSObject, BluetoothCentralClient, @unchecked Sendable {
    private let hub: BluetoothCentral
    private var queue: DispatchQueue { hub.queue }
    private var continuation: AsyncStream<DiscoveredRadio>.Continuation?
    /// Identifies the current scan, so a superseded stream's termination doesn't stop its replacement.
    private var scanID: UUID?

    override public init() {
        hub = .shared
        super.init()
    }

    /// Starts scanning. Results repeat as RSSI updates; scanning stops when the stream is no longer iterated.
    public func scan() -> AsyncStream<DiscoveredRadio> {
        let (stream, continuation) = AsyncStream<DiscoveredRadio>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let id = UUID()
        continuation.onTermination = { [weak self] _ in self?.stop(scan: id) }
        queue.async {
            self.continuation?.finish()
            self.continuation = continuation
            self.scanID = id
            self.hub.add(self)
            self.yieldAlreadyConnected()
            self.hub.startScanning()
        }
        return stream
    }

    public func stop() {
        stop(scan: nil)
    }

    /// Stops scanning; with an `id`, only if that scan is still the current one.
    private func stop(scan id: UUID?) {
        queue.async {
            guard id == nil || id == self.scanID else { return }
            self.hub.stopScanning()
            self.hub.remove(self)
            self.continuation?.finish()
            self.continuation = nil
            self.scanID = nil
        }
    }

    private func yieldAlreadyConnected() {
        for peripheral in hub.connectedRadios() {
            continuation?.yield(
                DiscoveredRadio(id: peripheral.identifier, name: peripheral.name ?? "MeshCore radio", rssi: 0)
            )
        }
    }

    // MARK: BluetoothCentralClient

    func centralDidUpdateState(_ central: CBCentralManager) {
        // The manager can power on well after the scan was asked for; `BluetoothCentral` restarts the scan itself,
        // so this only has to pick up radios another app already has connected.
        guard central.state == .poweredOn, continuation != nil else { return }
        yieldAlreadyConnected()
    }

    func central(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        let isRadio = services.contains(MeshCoreProtocol.BLE.service) || (name?.hasPrefix("MeshCore") ?? false)
        guard isRadio else { return }
        continuation?.yield(DiscoveredRadio(id: peripheral.identifier, name: name ?? "MeshCore radio", rssi: RSSI.intValue))
    }
}

/// Connects to a companion radio over BLE (Nordic UART Service): one write or notification per frame.
/// Radios with a PIN trigger the system pairing prompt when notifications are enabled.
///
/// Concurrency: all CoreBluetooth state is confined to `BluetoothCentral.shared.queue`, which is also the delegate queue.
public final class BLETransport: NSObject, MeshTransport, BluetoothCentralClient, @unchecked Sendable {
    public let peripheralID: UUID
    private let openTimeout: Duration
    private let hub: BluetoothCentral
    private var queue: DispatchQueue { hub.queue }

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var rxCharacteristic: CBCharacteristic?
    private var openContinuation: CheckedContinuation<Void, Error>?
    private var inbound: AsyncThrowingStream<Data, Error>.Continuation?
    private var writeContinuation: CheckedContinuation<Void, Error>?
    private var isClosing = false
    /// Why the manager isn't usable yet, reported if it hasn't become `poweredOn` by `powerTimeout`.
    private var powerProblem: TransportError?

    /// How long the manager gets to reach `poweredOn` before the attempt is given up on. Long enough for
    /// AccessorySetupKit's initial `poweredOff` to settle, short enough that Bluetooth really being off is
    /// reported while the user is still looking at the screen.
    private static let powerTimeout: Duration = .seconds(10)

    /// Sets the CoreBluetooth state-restoration key for the app's single central manager, so iOS can relaunch the app
    /// for radio events. Only the first call counts, so call it at launch before any scan or connection.
    public static func configureStateRestoration(identifier: String) {
        BluetoothCentral.shared.setRestoreIdentifier(identifier)
    }

    /// - Parameters:
    ///   - openTimeout: Covers waiting for Bluetooth, connecting, discovery and the user typing a pairing PIN.
    ///   - restoreIdentifier: Forwarded to ``configureStateRestoration(identifier:)``.
    public init(peripheralID: UUID, openTimeout: Duration = .seconds(60), restoreIdentifier: String? = nil) {
        self.peripheralID = peripheralID
        self.openTimeout = openTimeout
        hub = .shared
        super.init()
        if let restoreIdentifier {
            Self.configureStateRestoration(identifier: restoreIdentifier)
        }
    }

    public func open() async throws -> AsyncThrowingStream<Data, Error> {
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        try await withCheckedThrowingContinuation { (opened: CheckedContinuation<Void, Error>) in
            queue.async {
                guard self.inbound == nil, self.openContinuation == nil else {
                    opened.resume(throwing: TransportError.alreadyOpen)
                    return
                }
                self.isClosing = false
                self.powerProblem = nil
                self.inbound = continuation
                self.openContinuation = opened
                self.central = self.hub.add(self)
                self.queue.asyncAfter(deadline: .now() + self.openTimeout.timeInterval) { [weak self] in
                    guard let self, self.openContinuation != nil else { return }
                    self.finish(error: TransportError.timedOut)
                }
                self.queue.asyncAfter(deadline: .now() + Self.powerTimeout.timeInterval) { [weak self] in
                    guard let self, self.openContinuation != nil, self.central?.state != .poweredOn,
                          let problem = self.powerProblem else { return }
                    self.finish(error: problem)
                }
                self.connectIfReady()
            }
        }
        return stream
    }

    public func send(_ frame: Data) async throws {
        guard frame.count <= MeshCoreProtocol.maxFrameSize else { throw TransportError.frameTooLarge(frame.count) }
        try await withCheckedThrowingContinuation { (written: CheckedContinuation<Void, Error>) in
            queue.async {
                guard let peripheral = self.peripheral, let rx = self.rxCharacteristic, self.inbound != nil else {
                    written.resume(throwing: TransportError.notOpen)
                    return
                }
                guard self.writeContinuation == nil else {
                    written.resume(throwing: TransportError.connectionFailed("a write is already in progress"))
                    return
                }
                self.writeContinuation = written
                peripheral.writeValue(frame, for: rx, type: .withResponse)
            }
        }
    }

    public func close() async {
        await withCheckedContinuation { (closed: CheckedContinuation<Void, Never>) in
            queue.async {
                self.isClosing = true
                self.finish(error: nil)
                closed.resume()
            }
        }
    }

    /// Connects once the shared manager is usable, and records why it isn't when it's not. Must run on `queue`.
    ///
    /// A state that isn't `poweredOn` is deliberately not fatal here. With AccessorySetupKit CoreBluetooth reports
    /// only `poweredOn` and `poweredOff`, and it reports `poweredOff` until an authorized accessory is reachable —
    /// so failing the attempt on the first state callback means every connect ends instantly in "Bluetooth is off",
    /// however healthy the radio and the phone's Bluetooth actually are. Waiting for the state to settle, up to
    /// `openTimeout`, is the only way to tell a radio that isn't ready yet from Bluetooth that is genuinely off.
    private func connectIfReady() {
        guard let central, openContinuation != nil else { return }
        switch central.state {
        case .poweredOn:
            powerProblem = nil
            connect(using: central)
        case .unauthorized:
            finish(error: TransportError.bluetoothUnavailable("m-Core isn't allowed to use Bluetooth. Turn it on in Settings."))
        case .unsupported:
            finish(error: TransportError.bluetoothUnavailable("Bluetooth LE isn't supported on this device."))
        case .poweredOff:
            powerProblem = .bluetoothUnavailable(
                "Bluetooth isn't available for m-Core. Check that Bluetooth is on, and that the radio is powered on and nearby."
            )
        case .resetting, .unknown:
            powerProblem = .bluetoothUnavailable("Bluetooth isn't ready yet.")
        @unknown default:
            powerProblem = .bluetoothUnavailable("Bluetooth isn't ready yet.")
        }
    }

    private func connect(using central: CBCentralManager) {
        guard let target = peripheral ?? hub.peripheral(for: peripheralID) else {
            finish(error: TransportError.peripheralNotFound)
            return
        }
        peripheral = target
        target.delegate = self
        // Another app, or an earlier session, may already hold the link; then there's nothing to connect and
        // CoreBluetooth sends no `didConnect`, so go straight to discovery.
        if target.state == .connected {
            target.discoverServices([MeshCoreProtocol.BLE.service])
        } else {
            central.connect(target)
        }
    }

    /// Tears down the connection and completes any waiters. Must run on `queue`.
    private func finish(error: Error?) {
        if let central, let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        // Only this transport stops listening; the manager is shared and stays alive for the next attempt.
        hub.remove(self)
        let failure = error ?? TransportError.disconnected(nil)
        openContinuation?.resume(throwing: failure)
        writeContinuation?.resume(throwing: failure)
        if let error {
            inbound?.finish(throwing: error)
        } else {
            inbound?.finish()
        }
        openContinuation = nil
        writeContinuation = nil
        inbound = nil
        rxCharacteristic = nil
        peripheral?.delegate = nil
        peripheral = nil
        central = nil
    }
}

extension BLETransport {
    // MARK: BluetoothCentralClient

    func centralDidUpdateState(_ central: CBCentralManager) {
        connectIfReady()
    }

    func centralWillRestore(_ peripherals: [CBPeripheral]) {
        guard let match = peripherals.first(where: { $0.identifier == peripheralID }) else { return }
        peripheral = match
        match.delegate = self
    }

    func central(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral.identifier == peripheralID else { return }
        peripheral.delegate = self
        peripheral.discoverServices([MeshCoreProtocol.BLE.service])
    }

    func central(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral.identifier == peripheralID else { return }
        finish(error: TransportError.connectionFailed(error?.localizedDescription ?? "failed to connect"))
    }

    func central(_ central: CBCentralManager, didDisconnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral.identifier == peripheralID, !isClosing, inbound != nil else { return }
        finish(error: TransportError.disconnected(error?.localizedDescription))
    }
}

extension BLETransport: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == MeshCoreProtocol.BLE.service }) else {
            finish(error: TransportError.serviceNotFound)
            return
        }
        peripheral.discoverCharacteristics([MeshCoreProtocol.BLE.rx, MeshCoreProtocol.BLE.tx], for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let characteristics = service.characteristics ?? []
        guard error == nil,
              let rx = characteristics.first(where: { $0.uuid == MeshCoreProtocol.BLE.rx }),
              let tx = characteristics.first(where: { $0.uuid == MeshCoreProtocol.BLE.tx }) else {
            finish(error: TransportError.serviceNotFound)
            return
        }
        rxCharacteristic = rx
        peripheral.setNotifyValue(true, for: tx)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == MeshCoreProtocol.BLE.tx else { return }
        if let error {
            // Usually pairing was cancelled or the PIN was wrong.
            finish(error: TransportError.connectionFailed(error.localizedDescription))
        } else {
            openContinuation?.resume()
            openContinuation = nil
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == MeshCoreProtocol.BLE.tx, error == nil, let value = characteristic.value, !value.isEmpty else {
            return
        }
        inbound?.yield(value)
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        let continuation = writeContinuation
        writeContinuation = nil
        if let error {
            continuation?.resume(throwing: TransportError.disconnected(error.localizedDescription))
        } else {
            continuation?.resume()
        }
    }
}
