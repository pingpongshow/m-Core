import Foundation
import MeshCoreKit
import Testing
@testable import MeshServices

private let start = Date(timeIntervalSince1970: 1_800_000_000)
private let sanFrancisco = Coordinate(latitude: 37.7749, longitude: -122.4194)

@MainActor
final class FakePowerMonitor: PowerStateMonitor {
    var isLowPowerModeEnabled: Bool
    var onChange: (() -> Void)?

    init(lowPower: Bool = false) {
        isLowPowerModeEnabled = lowPower
    }

    func set(_ lowPower: Bool) {
        isLowPowerModeEnabled = lowPower
        onChange?()
    }
}

@MainActor
final class FakeFeedAlerts: GPSFeedAlerting {
    private(set) var lost: [String?] = []
    private(set) var reconnected = 0

    func radioConnectionLost(radioName: String?) { lost.append(radioName) }
    func radioReconnected() { reconnected += 1 }
}

private func defaults() -> UserDefaults {
    UserDefaults(suiteName: "feature.\(UUID().uuidString)")!
}

@MainActor
struct GPSFeedLowPowerAndAlertTests {
    struct Setup {
        let mock: MockRadio
        let controller: RadioController
        let feed: GPSFeedService
        let location: MockLocationProvider
        let power: FakePowerMonitor
        let alerts: FakeFeedAlerts
    }

    private func connected(lowPower: Bool = false, clock: MutableClock = MutableClock(start)) async throws -> Setup {
        let mock = MockRadio()
        let store = defaults()
        let controller = RadioController(defaults: store, simulatedRadio: mock)
        let location = MockLocationProvider()
        let power = FakePowerMonitor(lowPower: lowPower)
        let alerts = FakeFeedAlerts()
        let feed = GPSFeedService(
            radio: controller, locationProvider: location, defaults: store, powerMonitor: power, alerts: alerts, now: { clock.now }
        )
        await controller.connect(to: .simulator)
        try await waitUntil { feed.source == .phone }
        return Setup(mock: mock, controller: controller, feed: feed, location: location, power: power, alerts: alerts)
    }

    @Test func pausesInLowPowerModeOnlyWhenChosen() async throws {
        let clock = MutableClock(start)
        let setup = try await connected(clock: clock)
        #expect(setup.feed.pauseInLowPowerMode == false)

        // Low Power Mode alone changes nothing while the option is off.
        setup.power.set(true)
        #expect(setup.location.isRunning)
        #expect(setup.feed.status == .waitingForLocation)

        setup.feed.setPauseInLowPowerMode(true)
        #expect(!setup.location.isRunning)
        #expect(setup.feed.isPausedForLowPower)
        #expect(setup.feed.status == .pausedLowPower)

        // Leaving Low Power Mode resumes the feed, and positions are written again.
        setup.power.set(false)
        #expect(setup.location.isRunning)
        #expect(setup.feed.status == .waitingForLocation)
        setup.location.send(.fix(LocationFix(coordinate: sanFrancisco, horizontalAccuracy: 5, timestamp: start)))
        try await waitUntil { setup.mock.current.positionWrites == 1 }

        // Turning Low Power Mode back on pauses again; the option is remembered.
        setup.power.set(true)
        #expect(!setup.location.isRunning)
        await setup.controller.disconnect()
    }

    @Test func startsPausedWhenAlreadyInLowPowerMode() async throws {
        let mock = MockRadio()
        let store = defaults()
        store.set(true, forKey: "gpsfeed.pauseInLowPowerMode")
        let controller = RadioController(defaults: store, simulatedRadio: mock)
        let location = MockLocationProvider()
        let feed = GPSFeedService(
            radio: controller, locationProvider: location, defaults: store, powerMonitor: FakePowerMonitor(lowPower: true)
        )
        await controller.connect(to: .simulator)
        try await waitUntil { feed.source == .phone }
        #expect(feed.pauseInLowPowerMode)
        #expect(location.startCount == 0)
        #expect(feed.status == .pausedLowPower)
        await controller.disconnect()
    }

    @Test func systemMonitorFollowsPowerStateNotification() async throws {
        let center = NotificationCenter()
        let state = LowPowerFlag()
        let monitor = SystemPowerStateMonitor(center: center, read: { state.value })
        var changes = 0
        monitor.onChange = { changes += 1 }
        #expect(!monitor.isLowPowerModeEnabled)
        state.value = true
        center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        try await waitUntil { monitor.isLowPowerModeEnabled }
        #expect(changes == 1)
    }

    @Test func alertsOncePerDropButNotForUserDisconnect() async throws {
        let setup = try await connected()
        setup.mock.simulateDisconnect()
        try await waitUntil { setup.alerts.lost.count == 1 }
        #expect(setup.alerts.lost.first == "m-Core Sim")
        #expect(setup.controller.lastDisconnectWasRequested == false)

        // The connection comes back by itself; the alert is withdrawn.
        try await waitUntil { setup.controller.isConnected && setup.feed.source == .phone }
        #expect(setup.alerts.reconnected == 1)

        // A disconnect the user asked for doesn't alert.
        await setup.controller.disconnect()
        #expect(setup.controller.lastDisconnectWasRequested)
        #expect(setup.alerts.lost.count == 1)
    }

    @Test func noAlertWhenFeedIsOffOrPaused() async throws {
        let setup = try await connected()
        setup.feed.update { $0.isEnabled = false }
        setup.mock.simulateDisconnect()
        try await waitUntil { !setup.controller.isConnected }
        try await waitUntil { setup.controller.isConnected && setup.feed.source == .phone }
        #expect(setup.alerts.lost.isEmpty)

        setup.feed.update { $0.isEnabled = true }
        setup.feed.setPauseInLowPowerMode(true)
        setup.power.set(true)
        setup.mock.simulateDisconnect()
        try await waitUntil { !setup.controller.isConnected }
        #expect(setup.alerts.lost.isEmpty)
        await setup.controller.disconnect()
    }
}

/// A Low Power Mode reading shared with the monitor's `@Sendable` reader.
final class LowPowerFlag: @unchecked Sendable {
    var value = false
}

@MainActor
struct KnownRadiosTests {
    private let radioA = RadioTarget.bluetooth(id: UUID(), name: "MeshCore-Alpha")
    private let radioB = RadioTarget.tcp(host: "192.168.1.20", port: 5000)

    @Test func storeRecordsRenamesAndForgets() {
        let store = KnownRadiosStore(defaults: defaults())
        #expect(store.load().isEmpty)
        store.recordConnection(to: radioA, radioName: "Alpha", at: start)
        store.recordConnection(to: radioB, radioName: "Base", at: start.addingTimeInterval(60))
        // Most recent first.
        #expect(store.load().map(\.target) == [radioB, radioA])

        store.recordConnection(to: radioA, radioName: "Alpha 2", at: start.addingTimeInterval(120))
        var radios = store.load()
        #expect(radios.count == 2)
        #expect(radios[0].target == radioA)
        #expect(radios[0].displayName == "Alpha 2")

        let alpha = radios[0]
        store.rename(id: alpha.id, to: "  Truck radio ")
        #expect(store.load()[0].displayName == "Truck radio")
        store.rename(id: alpha.id, to: "")
        #expect(store.load()[0].displayName == "Alpha 2")

        radios = store.forget(id: alpha.id)
        #expect(radios.map(\.target) == [radioB])
        #expect(store.load().map(\.target) == [radioB])
    }

    @Test func simulatorIsNotRememberedAndAddDoesNotDuplicate() {
        let store = KnownRadiosStore(defaults: defaults())
        store.recordConnection(to: .simulator, radioName: "Sim", at: start)
        #expect(store.load().isEmpty)
        store.add(radioA, radioName: "Alpha")
        store.add(radioA, radioName: "Alpha again")
        #expect(store.load().count == 1)
        #expect(store.load()[0].lastConnected == nil)
        // TCP hosts compare case-insensitively.
        store.add(.tcp(host: "Radio.local", port: 5000), radioName: nil)
        store.add(.tcp(host: "radio.local", port: 5000), radioName: nil)
        #expect(store.load().count == 2)
    }

    @Test func controllerRemembersConnectedRadios() async throws {
        let store = defaults()
        let lastTarget = try JSONEncoder().encode(radioB)
        store.set(lastTarget, forKey: "radio.lastTarget")
        let clock = MutableClock(start)
        let controller = RadioController(defaults: store, simulatedRadio: MockRadio(), now: { clock.now })
        // The radio used before the list existed is carried over.
        #expect(controller.knownRadios.map(\.target) == [radioB])

        controller.addKnownRadio(radioA, name: "MeshCore-Alpha")
        #expect(controller.knownRadios.count == 2)
        controller.renameKnownRadio(try #require(controller.knownRadios.first { $0.target == radioA }), to: "Pocket")
        #expect(controller.knownRadios.contains { $0.displayName == "Pocket" })
        await controller.forgetKnownRadio(try #require(controller.knownRadios.first { $0.target == radioB }))
        #expect(controller.lastTarget == nil)
        #expect(controller.knownRadios.map(\.target) == [radioA])
    }

    @Test func unauthorizedBluetoothRadioIsNotConnected() async throws {
        let controller = RadioController(defaults: defaults(), simulatedRadio: MockRadio())
        let access = FakeBluetoothAccess()
        controller.bluetoothAccess = access
        await controller.connect(to: radioA)
        #expect(controller.connectionProblem != nil)
        #expect(controller.state == .idle)
        #expect(controller.target == nil)

        await controller.forgetKnownRadio(KnownRadio(target: radioA))
        guard case .bluetooth(let id, _) = radioA else { return }
        #expect(access.forgotten == [id])
    }
}

@MainActor
final class FakeBluetoothAccess: BluetoothAccessAuthority {
    var authorized: Set<UUID> = []
    private(set) var forgotten: [UUID] = []

    func ready() async {}
    func mayConnect(to peripheralID: UUID) -> Bool { authorized.contains(peripheralID) }
    func forget(peripheralID: UUID) async { forgotten.append(peripheralID) }
}

struct BatteryChemistryTests {
    @Test func lithiumIonCurve() {
        let chemistry = BatteryChemistry.lithiumIon
        #expect(chemistry.percent(millivolts: 4_200) == 100)
        #expect(chemistry.percent(millivolts: 4_350) == 100)
        #expect(chemistry.percent(millivolts: 3_840) == 50)
        #expect(chemistry.percent(millivolts: 3_270) == 0)
        #expect(chemistry.percent(millivolts: 3_000) == 0)
        // Halfway between 3.69 V (10%) and 3.71 V (15%).
        #expect(chemistry.percent(millivolts: 3_700) == 13)
        #expect(chemistry.percent(millivolts: 0) == nil)
    }

    @Test func lithiumIronPhosphateCurve() {
        let chemistry = BatteryChemistry.lithiumIronPhosphate
        #expect(chemistry.percent(millivolts: 3_650) == 100)
        #expect(chemistry.percent(millivolts: 3_260) == 50)
        #expect(chemistry.percent(millivolts: 3_100) == 15)
        #expect(chemistry.percent(millivolts: 2_400) == 0)
        // The same voltage means very different charge for Li-ion.
        #expect(BatteryChemistry.lithiumIon.percent(millivolts: 3_300)! < 5)
    }

    @Test func nickelMetalHydrideCurve() {
        let chemistry = BatteryChemistry.nickelMetalHydride3Cell
        #expect(chemistry.percent(millivolts: 3_750) == 50)
        #expect(chemistry.percent(millivolts: 4_125) == 95)
        #expect(chemistry.percent(millivolts: 2_900) == 0)
    }

    @Test func curvesRiseMonotonically() {
        for chemistry in BatteryChemistry.allCases {
            let curve = chemistry.curve
            #expect(curve.first?.percent == 0)
            #expect(curve.last?.percent == 100)
            for (lower, upper) in zip(curve, curve.dropFirst()) {
                #expect(lower.millivolts < upper.millivolts)
                #expect(lower.percent < upper.percent)
            }
        }
    }

    @Test func describesVoltsAndPercent() {
        #expect(BatteryChemistry.lithiumIon.describe(millivolts: 3_840) == "3.84 V · 50%")
        #expect(BatteryChemistry.lithiumIon.describe(millivolts: 0) == "0.00 V")
    }

    @MainActor
    @Test func chemistryIsRememberedPerRadio() async throws {
        let store = defaults()
        let mock = MockRadio()
        let controller = RadioController(defaults: store, simulatedRadio: mock)
        await controller.connect(to: .simulator)
        try await waitUntil { controller.battery != nil }
        #expect(controller.batteryChemistry == .lithiumIon)
        // The sample radio reports 4.05 V: 83% for Li-ion (between 4.02 V = 80% and 4.08 V = 85%).
        #expect(controller.batteryPercent == 83)
        controller.setBatteryChemistry(.lithiumIronPhosphate)
        #expect(controller.batteryPercent == 100)
        await controller.disconnect()
        #expect(controller.batteryChemistry == .lithiumIon)

        await controller.connect(to: .simulator)
        try await waitUntil { controller.battery != nil }
        #expect(controller.batteryChemistry == .lithiumIronPhosphate)
        await controller.disconnect()
    }

    /// USA and Canada have identical LoRa settings, so the chosen preset can't be read back from the radio.
    @MainActor
    @Test func appliedPresetIsRememberedPerRadio() async throws {
        let store = defaults()
        let mock = MockRadio()
        let controller = RadioController(defaults: store, simulatedRadio: mock)
        await controller.connect(to: .simulator)
        try await waitUntil { controller.selfInfo != nil }
        #expect(controller.appliedPresetID == nil)

        controller.setAppliedPresetID("us")
        #expect(controller.appliedPresetID == "us")
        await controller.disconnect()
        // Nothing to answer for with no radio connected.
        #expect(controller.appliedPresetID == nil)

        await controller.connect(to: .simulator)
        try await waitUntil { controller.selfInfo != nil }
        #expect(controller.appliedPresetID == "us")
        controller.setAppliedPresetID(nil)
        #expect(controller.appliedPresetID == nil)
        await controller.disconnect()
    }
}
