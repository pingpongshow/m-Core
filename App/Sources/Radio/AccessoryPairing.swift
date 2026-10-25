import AccessorySetupKit
import CoreBluetooth
import MeshCoreKit
import MeshServices
import Observation
import UIKit

/// Adds Bluetooth radios with AccessorySetupKit (iOS 18) when the app declares it in Info.plist.
///
/// How it coexists with CoreBluetooth (see the AccessorySetupKit docs, "Discovering and configuring accessories", and
/// WWDC24 "Meet AccessorySetupKit"):
/// - Declaring `NSAccessorySetupKitSupports` = `Bluetooth` puts the whole app in AccessorySetupKit mode as soon as it
///   launches: no Bluetooth permission prompt, the central manager only powers on once a radio is authorized, and a
///   CoreBluetooth scan only returns radios authorized for the app. Asking CoreBluetooth for any other peripheral can
///   terminate the app, so ``mayConnect(to:)`` gates every Bluetooth connect in `RadioController`.
/// - The picker (``showPicker()``) is therefore the way to add a radio; the CoreBluetooth scan stays as the fallback for
///   finding radios that are already authorized (e.g. after reinstalling) and is the only path when a build drops the
///   Info.plist keys (``isEnabled`` is then false and the app behaves as a plain CoreBluetooth app).
/// - Radios remembered from CoreBluetooth-only builds are offered for migration with `ASMigrationDisplayItem`, which only
///   works before the first `CBCentralManager` of the process exists (`CoreBluetoothUsage`).
@MainActor
@Observable
final class AccessoryPairing: BluetoothAccessAuthority {
    /// Whether Info.plist opts into AccessorySetupKit for Bluetooth.
    let isEnabled: Bool
    private(set) var isReady = false
    private(set) var isPickerShowing = false
    private(set) var lastError: String?
    /// Radios authorized for the app, by Bluetooth identifier.
    private(set) var authorizedIDs: Set<UUID> = []

    static let productImageName = "RadioAccessory"
    private static let readyTimeout: Duration = .seconds(3)

    @ObservationIgnored private let radio: RadioController
    @ObservationIgnored private var session: ASAccessorySession?
    @ObservationIgnored private var accessories: [UUID: ASAccessory] = [:]
    @ObservationIgnored private var readyWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var picked: ASAccessory?

    init(radio: RadioController, bundle: Bundle = .main) {
        self.radio = radio
        let supports = bundle.object(forInfoDictionaryKey: "NSAccessorySetupKitSupports") as? [String] ?? []
        isEnabled = supports.contains("Bluetooth")
        guard isEnabled else {
            isReady = true
            return
        }
        radio.bluetoothAccess = self
        activate()
    }

    // MARK: BluetoothAccessAuthority

    func ready() async {
        guard !isReady else { return }
        await withCheckedContinuation { continuation in
            readyWaiters.append(continuation)
            Task { [weak self] in
                try? await Task.sleep(for: Self.readyTimeout)
                // If the session never activates (e.g. unsupported environment), stop waiting; unknown radios stay blocked.
                self?.markReady()
            }
        }
    }

    func mayConnect(to peripheralID: UUID) -> Bool {
        !isEnabled || authorizedIDs.contains(peripheralID)
    }

    func forget(peripheralID: UUID) async {
        guard let session, let accessory = accessories[peripheralID] else { return }
        let message: String? = await withCheckedContinuation { continuation in
            session.removeAccessory(accessory) { @Sendable error in
                continuation.resume(returning: error?.localizedDescription)
            }
        }
        if let message {
            lastError = "Couldn't remove the radio from Accessories: \(message)"
        } else {
            authorizedIDs.remove(peripheralID)
            accessories[peripheralID] = nil
        }
    }

    // MARK: Picker

    /// Shows the system accessory picker for MeshCore radios (anything advertising the Nordic UART service).
    func showPicker() {
        guard let session, !isPickerShowing else { return }
        guard let image = UIImage(named: Self.productImageName) else {
            lastError = "The accessory picker image is missing."
            return
        }
        lastError = nil
        let descriptor = Self.descriptor()
        var items = [ASPickerDisplayItem(name: "MeshCore radio", productImage: image, descriptor: descriptor)]
        items += migrationItems(image: image, descriptor: descriptor)
        session.showPicker(for: items) { @Sendable error in
            let message = error.map { Self.describe($0 as NSError) }
            Task { @MainActor [weak self] in
                if let message { self?.lastError = message }
            }
        }
    }

    /// Known radios found by CoreBluetooth in earlier builds, offered for adoption into the accessory list.
    private func migrationItems(image: UIImage, descriptor: ASDiscoveryDescriptor) -> [ASPickerDisplayItem] {
        guard !CoreBluetoothUsage.hasCreatedCentralManager else { return [] }
        return radio.knownRadios.compactMap { known in
            guard case .bluetooth(let id, _) = known.target, !authorizedIDs.contains(id) else { return nil }
            let item = ASMigrationDisplayItem(name: known.displayName, productImage: image, descriptor: descriptor)
            item.peripheralIdentifier = id
            return item
        }
    }

    /// Must match `NSAccessorySetupBluetoothServices` in Info.plist, or the picker crashes the app.
    private static func descriptor() -> ASDiscoveryDescriptor {
        let descriptor = ASDiscoveryDescriptor()
        descriptor.bluetoothServiceUUID = CBUUID(string: MeshCoreProtocol.BLE.serviceUUID)
        return descriptor
    }

    /// Pure; called from the picker's completion handler, which isn't on the main actor.
    nonisolated private static func describe(_ error: NSError) -> String? {
        guard error.domain == ASErrorDomain else { return error.localizedDescription }
        switch ASError.Code(rawValue: error.code) {
        case .userCancelled, .pickerAlreadyActive: return nil
        case .discoveryTimeout: return "No radio found. Make sure it's on, nearby and not connected to another phone."
        case .pickerRestricted: return "Open m-Core to add a radio."
        case .userRestricted: return "Adding accessories is restricted on this device."
        default: return error.localizedDescription
        }
    }

    // MARK: Session

    private func activate() {
        let session = ASAccessorySession()
        self.session = session
        // Events arrive on the main queue, in order (accessoryAdded comes before pickerDidDismiss).
        session.activate(on: .main) { @Sendable [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
    }

    private func handle(_ event: ASAccessoryEvent) {
        switch event.eventType {
        case .activated, .migrationComplete:
            refreshAccessories()
            markReady()
        case .accessoryAdded:
            refreshAccessories()
            picked = event.accessory
        case .accessoryChanged, .accessoryRemoved:
            refreshAccessories()
        case .pickerDidPresent:
            isPickerShowing = true
        case .pickerDidDismiss:
            isPickerShowing = false
            if let accessory = picked, let id = accessory.bluetoothIdentifier {
                picked = nil
                let target = RadioTarget.bluetooth(id: id, name: accessory.displayName)
                radio.addKnownRadio(target, name: accessory.displayName)
                Task { await radio.connect(to: target) }
            }
        case .pickerSetupFailed:
            lastError = event.error.map { $0.localizedDescription } ?? "Setting up the radio failed."
        case .invalidated:
            session = nil
            markReady()
        default:
            break
        }
    }

    /// Mirrors the session's authorized radios, and adds any the user authorized to the known-radios list.
    private func refreshAccessories() {
        guard let session else { return }
        var byID: [UUID: ASAccessory] = [:]
        for accessory in session.accessories where accessory.state == .authorized {
            guard let id = accessory.bluetoothIdentifier else { continue }
            byID[id] = accessory
            radio.addKnownRadio(.bluetooth(id: id, name: accessory.displayName), name: accessory.displayName)
        }
        accessories = byID
        authorizedIDs = Set(byID.keys)
    }

    private func markReady() {
        guard !isReady || !readyWaiters.isEmpty else { return }
        isReady = true
        let waiters = readyWaiters
        readyWaiters = []
        waiters.forEach { $0.resume() }
    }
}
