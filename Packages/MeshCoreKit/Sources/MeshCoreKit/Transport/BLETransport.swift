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
/// Concurrency: all CoreBluetooth state is confined to `queue`, which is also the delegate queue.
public final class BLEScanner: NSObject, @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.mcore.ble.scan")
    private var central: CBCentralManager?
    private var continuation: AsyncStream<DiscoveredRadio>.Continuation?

    override public init() {
        super.init()
    }

    /// Starts scanning. Results repeat as RSSI updates; scanning stops when the stream is no longer iterated.
    public func scan() -> AsyncStream<DiscoveredRadio> {
        let (stream, continuation) = AsyncStream<DiscoveredRadio>.makeStream(bufferingPolicy: .bufferingNewest(64))
        continuation.onTermination = { [weak self] _ in self?.stop() }
        queue.async {
            self.continuation?.finish()
            self.continuation = continuation
            if let central = self.central {
                self.startScanning(central)
            } else {
                self.central = CBCentralManager(delegate: self, queue: self.queue)
            }
        }
        return stream
    }

    public func stop() {
        queue.async {
            self.central?.stopScan()
            self.continuation?.finish()
            self.continuation = nil
        }
    }

    private func startScanning(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { return }
        for peripheral in central.retrieveConnectedPeripherals(withServices: [MeshCoreProtocol.BLE.service]) {
            continuation?.yield(DiscoveredRadio(id: peripheral.identifier, name: peripheral.name ?? "MeshCore radio", rssi: 0))
        }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }
}

extension BLEScanner: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn, continuation != nil {
            startScanning(central)
        }
    }

    public func centralManager(
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
/// Concurrency: all CoreBluetooth state is confined to `queue`, which is also the delegate queue.
public final class BLETransport: NSObject, MeshTransport, @unchecked Sendable {
    public let peripheralID: UUID
    private let openTimeout: Duration
    private let queue = DispatchQueue(label: "app.mcore.ble")

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var rxCharacteristic: CBCharacteristic?
    private var openContinuation: CheckedContinuation<Void, Error>?
    private var inbound: AsyncThrowingStream<Data, Error>.Continuation?
    private var writeContinuation: CheckedContinuation<Void, Error>?
    private var isClosing = false

    /// - Parameter openTimeout: Covers connecting, discovery and the user typing a pairing PIN.
    public init(peripheralID: UUID, openTimeout: Duration = .seconds(60)) {
        self.peripheralID = peripheralID
        self.openTimeout = openTimeout
        super.init()
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
                self.inbound = continuation
                self.openContinuation = opened
                self.central = CBCentralManager(delegate: self, queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + self.openTimeout.timeInterval) {
                    if self.openContinuation != nil { self.finish(error: TransportError.timedOut) }
                }
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

    /// Tears down the connection and completes any waiters. Must run on `queue`.
    private func finish(error: Error?) {
        if let central, let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
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
        central?.delegate = nil
        central = nil
    }
}

extension BLETransport: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            guard peripheral == nil, openContinuation != nil else { return }
            guard let target = central.retrievePeripherals(withIdentifiers: [peripheralID]).first else {
                finish(error: TransportError.peripheralNotFound)
                return
            }
            peripheral = target
            target.delegate = self
            central.connect(target)
        case .unauthorized:
            finish(error: TransportError.bluetoothUnavailable("Bluetooth permission is denied"))
        case .poweredOff:
            finish(error: TransportError.bluetoothUnavailable("Bluetooth is off"))
        case .unsupported:
            finish(error: TransportError.bluetoothUnavailable("Bluetooth LE is not supported"))
        default:
            break
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([MeshCoreProtocol.BLE.service])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        finish(error: TransportError.connectionFailed(error?.localizedDescription ?? "failed to connect"))
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard !isClosing else { return }
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
