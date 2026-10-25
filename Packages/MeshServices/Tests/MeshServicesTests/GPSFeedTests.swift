import Foundation
import MeshCoreKit
import Testing
@testable import MeshServices

private let start = Date(timeIntervalSince1970: 1_800_000_000)
private let sanFrancisco = Coordinate(latitude: 37.7749, longitude: -122.4194)

/// Coordinate `metres` north of `origin`.
private func north(of origin: Coordinate, metres: Double) -> Coordinate {
    Coordinate(latitude: origin.latitude + metres / 111_195, longitude: origin.longitude)
}

private func fix(_ coordinate: Coordinate, accuracy: Double = 5, at date: Date) -> LocationFix {
    LocationFix(coordinate: coordinate, horizontalAccuracy: accuracy, timestamp: date)
}

struct CoordinateTests {
    @Test func distanceAndBearing() {
        let oneKmNorth = north(of: sanFrancisco, metres: 1_000)
        #expect(abs(sanFrancisco.distance(to: oneKmNorth) - 1_000) < 1)
        #expect(abs(sanFrancisco.bearing(to: oneKmNorth)) < 0.01)
        #expect(Coordinate(latitude: 0, longitude: 0).isSet == false)
        #expect(Coordinate(latitude: 91, longitude: 0).isValid == false)
    }

    @Test func microdegreesRoundTrip() {
        let coordinate = Coordinate(latitudeE6: 37_774_900, longitudeE6: -122_419_400)
        #expect(coordinate.latitudeE6 == 37_774_900)
        #expect(coordinate.longitudeE6 == -122_419_400)
    }

    @Test func rounding() {
        let precise = Coordinate(latitude: 37.774_929, longitude: -122.419_416)
        #expect(GPSFeedSettings.Rounding.approx100m.apply(precise) == Coordinate(latitude: 37.775, longitude: -122.419))
        #expect(GPSFeedSettings.Rounding.approx1km.apply(precise) == Coordinate(latitude: 37.77, longitude: -122.42))
        #expect(GPSFeedSettings.Rounding.exact.apply(precise) == precise)
    }
}

struct GPSFeedGateTests {
    private var gate = GPSFeedGate(settings: GPSFeedSettings())

    @Test func firstGoodFixIsSent() {
        #expect(gate.evaluate(fix(sanFrancisco, at: start), now: start, radioPosition: nil) == .send(sanFrancisco))
    }

    @Test func badFixesAreFiltered() {
        #expect(gate.evaluate(fix(sanFrancisco, accuracy: 80, at: start), now: start, radioPosition: nil) == .skip(.inaccurate))
        #expect(gate.evaluate(fix(sanFrancisco, accuracy: -1, at: start), now: start, radioPosition: nil) == .skip(.inaccurate))
        #expect(gate.evaluate(fix(sanFrancisco, at: start), now: start.addingTimeInterval(60), radioPosition: nil) == .skip(.stale))
        #expect(gate.evaluate(fix(Coordinate(latitude: 0, longitude: 0), at: start), now: start, radioPosition: nil) == .skip(.invalid))
    }

    @Test mutating func movementAndTimeGate() {
        gate.recordSent(sanFrancisco, at: start)
        let small = north(of: sanFrancisco, metres: 10)
        let big = north(of: sanFrancisco, metres: 40)
        let at60 = start.addingTimeInterval(60)
        let at10 = start.addingTimeInterval(10)
        let at31 = start.addingTimeInterval(31)
        #expect(gate.evaluate(fix(small, at: at60), now: at60, radioPosition: sanFrancisco) == .skip(.notMovedEnough))
        #expect(gate.evaluate(fix(big, at: at10), now: at10, radioPosition: sanFrancisco) == .skip(.tooSoon))
        #expect(gate.evaluate(fix(big, at: at31), now: at31, radioPosition: sanFrancisco) == .send(big))
    }

    @Test mutating func heartbeatResendsOnlyWhenRadioDrifted() {
        gate.recordSent(sanFrancisco, at: start)
        let later = start.addingTimeInterval(700)
        let here = north(of: sanFrancisco, metres: 5)
        #expect(gate.evaluate(fix(here, at: later), now: later, radioPosition: sanFrancisco) == .skip(.notMovedEnough))
        let drifted = north(of: sanFrancisco, metres: 500)
        #expect(gate.evaluate(fix(here, at: later), now: later, radioPosition: drifted) == .send(here))
    }

    @Test mutating func resetAdoptsRadioPosition() {
        gate.reset(radioPosition: sanFrancisco, at: start)
        let near = north(of: sanFrancisco, metres: 5)
        let later = start.addingTimeInterval(100)
        #expect(gate.evaluate(fix(near, at: later), now: later, radioPosition: sanFrancisco) == .skip(.notMovedEnough))
        gate.reset(radioPosition: Coordinate(latitude: 0, longitude: 0), at: start)
        #expect(gate.lastSent == nil)
    }

    @Test mutating func presetsChangeThresholds() {
        var settings = GPSFeedSettings()
        settings.preset = .driving
        gate.settings = settings
        gate.recordSent(sanFrancisco, at: start)
        let hundredMetres = north(of: sanFrancisco, metres: 100)
        let later = start.addingTimeInterval(60)
        #expect(gate.evaluate(fix(hundredMetres, at: later), now: later, radioPosition: sanFrancisco) == .skip(.notMovedEnough))
        settings.preset = .custom
        settings.custom.minDistance = 50
        gate.settings = settings
        #expect(gate.evaluate(fix(hundredMetres, at: later), now: later, radioPosition: sanFrancisco) == .send(hundredMetres))
    }
}

@MainActor
final class MockLocationProvider: LocationProvider {
    private(set) var startCount = 0
    private(set) var lastPreset: GPSFeedSettings.Preset?
    private var continuation: AsyncStream<LocationEvent>.Continuation?

    var isRunning: Bool { continuation != nil }

    func start(preset: GPSFeedSettings.Preset) -> AsyncStream<LocationEvent> {
        startCount += 1
        lastPreset = preset
        let (stream, continuation) = AsyncStream<LocationEvent>.makeStream()
        self.continuation = continuation
        return stream
    }

    func stop() {
        continuation?.finish()
        continuation = nil
    }

    func send(_ event: LocationEvent) {
        continuation?.yield(event)
    }
}

@MainActor
struct GPSFeedServiceTests {
    private func makeDefaults() -> UserDefaults {
        let name = "gps.\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    struct Connection {
        let controller: RadioController
        let feed: GPSFeedService
        let location: MockLocationProvider
    }

    /// Connects a controller to a simulated radio and waits for the GPS Feed to settle.
    private func connected(radio mock: MockRadio, clock: MutableClock) async throws -> Connection {
        let defaults = makeDefaults()
        let controller = RadioController(defaults: defaults, simulatedRadio: mock)
        let location = MockLocationProvider()
        let feed = GPSFeedService(radio: controller, locationProvider: location, defaults: defaults, now: { clock.now })
        await controller.connect(to: .simulator)
        try await waitUntil { feed.source != .unknown }
        return Connection(controller: controller, feed: feed, location: location)
    }

    @Test func radioWithoutGPSIsFedThePhonePosition() async throws {
        let mock = MockRadio()
        let clock = MutableClock(start)
        let connection = try await connected(radio: mock, clock: clock)
        let controller = connection.controller
        let feed = connection.feed
        let location = connection.location

        #expect(feed.source == .phone)
        #expect(location.isRunning)
        #expect(feed.status == .waitingForLocation)

        location.send(.fix(fix(sanFrancisco, at: start)))
        try await waitUntil { mock.current.positionWrites == 1 }
        #expect(mock.current.selfInfo.latitudeE6 == sanFrancisco.latitudeE6)
        try await waitUntil { feed.writesToday == 1 }
        #expect(feed.status == .phone(accuracy: 5, lastSync: start))
        try await waitUntil { controller.selfInfo?.latitudeE6 == sanFrancisco.latitudeE6 }

        // A small move soon after is not written.
        clock.now = start.addingTimeInterval(5)
        location.send(.fix(fix(north(of: sanFrancisco, metres: 10), at: clock.now)))
        try await Task.sleep(for: .milliseconds(100))
        #expect(mock.current.positionWrites == 1)

        // A real move after the interval is.
        clock.now = start.addingTimeInterval(60)
        location.send(.fix(fix(north(of: sanFrancisco, metres: 100), at: clock.now)))
        try await waitUntil { mock.current.positionWrites == 2 }
        await controller.disconnect()
        #expect(!location.isRunning)
        #expect(feed.status == .notConnected)
    }

    @Test func radioWithGPSIsNeverWritten() async throws {
        let mock = MockRadio()
        mock.update { $0.customVars = ["gps": "0"] }
        let clock = MutableClock(start)
        let connection = try await connected(radio: mock, clock: clock)
        let controller = connection.controller
        let feed = connection.feed
        let location = connection.location

        #expect(feed.source == .radioGPS(isOn: false))
        #expect(!location.isRunning)

        await feed.turnOnRadioGPS()
        #expect(feed.source == .radioGPS(isOn: true))
        #expect(mock.current.customVars["gps"] == "1")
        #expect(mock.current.positionWrites == 0)
        await controller.disconnect()
    }

    @Test func disablingStopsLocation() async throws {
        let clock = MutableClock(start)
        let connection = try await connected(radio: MockRadio(), clock: clock)
        let controller = connection.controller
        let feed = connection.feed
        let location = connection.location
        feed.update { $0.isEnabled = false }
        #expect(!location.isRunning)
        #expect(feed.status == .off)
        feed.update { $0.isEnabled = true }
        #expect(location.isRunning)
        feed.update { $0.preset = .driving }
        #expect(location.lastPreset == .driving)
        await controller.disconnect()
    }

    @Test func privacySettingsReachTheRadio() async throws {
        let mock = MockRadio()
        let clock = MutableClock(start)
        let connection = try await connected(radio: mock, clock: clock)
        let controller = connection.controller
        let feed = connection.feed

        await feed.setShareInAdverts(false)
        #expect(mock.current.selfInfo.advertLocationPolicy == 0)
        #expect(controller.selfInfo?.sharesLocationInAdverts == false)

        await feed.setLocationTelemetry(.deny)
        #expect(mock.current.selfInfo.telemetryModes.location == .deny)
        // Other settings written by the same command are preserved.
        #expect(mock.current.selfInfo.telemetryModes.base == .allowAll)
        #expect(mock.current.selfInfo.advertLocationPolicy == 0)
        await controller.disconnect()
    }

    @Test func advertsOnSignificantMove() async throws {
        let mock = MockRadio()
        let clock = MutableClock(start)
        let connection = try await connected(radio: mock, clock: clock)
        let controller = connection.controller
        let feed = connection.feed
        let location = connection.location
        feed.update { settings in
            settings.advertOnMove = true
            settings.advertDistance = 500
        }

        location.send(.fix(fix(sanFrancisco, at: start)))
        try await waitUntil { mock.current.advertsSent == 1 }

        clock.now = start.addingTimeInterval(60)
        location.send(.fix(fix(north(of: sanFrancisco, metres: 100), at: clock.now)))
        try await waitUntil { mock.current.positionWrites == 2 }
        #expect(mock.current.advertsSent == 1) // moved, but not far enough to re-advertise
        await controller.disconnect()
    }

    @Test func deniedLocationIsReported() async throws {
        let clock = MutableClock(start)
        let connection = try await connected(radio: MockRadio(), clock: clock)
        let controller = connection.controller
        let feed = connection.feed
        let location = connection.location
        location.send(.denied)
        try await waitUntil { feed.status == .locationDenied }
        await controller.disconnect()
    }
}

/// A settable clock for tests.
final class MutableClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

/// Polls `condition` on the main actor until it holds or the timeout passes.
@MainActor
func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("condition not met within \(timeout)")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}
