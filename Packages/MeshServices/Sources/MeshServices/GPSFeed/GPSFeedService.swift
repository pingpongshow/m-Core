import Foundation
import MeshCoreKit
import Observation

/// Keeps the connected radio's position accurate (PLAN.md §4.1):
/// a radio with GPS uses its own; a radio without GPS is fed the phone's position.
@MainActor
@Observable
public final class GPSFeedService: RadioEventHandler {
    public enum Source: Equatable, Sendable {
        case unknown
        /// The radio has a GPS module; `isOn` mirrors its `gps` setting.
        case radioGPS(isOn: Bool)
        case phone
    }

    public enum Status: Equatable, Sendable {
        case notConnected
        case off
        case radioGPS(isOn: Bool)
        case waitingForLocation
        case locationDenied
        /// Paused because Low Power Mode is on and the user chose to pause then.
        case pausedLowPower
        case phone(accuracy: Double, lastSync: Date?)
    }

    public private(set) var source: Source = .unknown
    public private(set) var lastFix: LocationFix?
    public private(set) var lastSentAt: Date?
    public private(set) var lastSent: Coordinate?
    public private(set) var writesToday = 0
    public private(set) var lastError: String?
    private(set) var locationDenied = false
    public private(set) var settings = GPSFeedSettings()
    /// Stop phone location and writes while Low Power Mode is on (a phone-wide setting, off by default).
    public private(set) var pauseInLowPowerMode: Bool
    public private(set) var isLowPowerModeOn: Bool
    /// Receives the lost-connection alert; set by the app.
    @ObservationIgnored public var alerts: (any GPSFeedAlerting)?

    @ObservationIgnored private let radio: RadioController
    @ObservationIgnored private let locationProvider: any LocationProvider
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var gate = GPSFeedGate(settings: GPSFeedSettings())
    @ObservationIgnored private var session: MeshSession?
    @ObservationIgnored private var radioKey: String?
    @ObservationIgnored private var locationTask: Task<Void, Never>?
    @ObservationIgnored private var lastAdvert: (Coordinate, Date)?
    @ObservationIgnored private var isWriting = false
    @ObservationIgnored private let powerMonitor: any PowerStateMonitor
    @ObservationIgnored private var radioName: String?
    @ObservationIgnored private var alertedForDrop = false
    private static let pauseInLowPowerKey = "gpsfeed.pauseInLowPowerMode"

    public init(
        radio: RadioController,
        locationProvider: any LocationProvider,
        defaults: UserDefaults = .standard,
        powerMonitor: any PowerStateMonitor = SystemPowerStateMonitor(),
        alerts: (any GPSFeedAlerting)? = nil,
        now: @escaping () -> Date = { Date() }
    ) {
        self.radio = radio
        self.locationProvider = locationProvider
        self.defaults = defaults
        self.powerMonitor = powerMonitor
        self.alerts = alerts
        self.now = now
        pauseInLowPowerMode = defaults.bool(forKey: Self.pauseInLowPowerKey)
        isLowPowerModeOn = powerMonitor.isLowPowerModeEnabled
        radio.addHandler(self)
        powerMonitor.onChange = { [weak self] in self?.powerStateChanged() }
    }

    /// Whether the phone feed is held off by Low Power Mode right now.
    public var isPausedForLowPower: Bool { pauseInLowPowerMode && isLowPowerModeOn }

    public var status: Status {
        guard session != nil else { return .notConnected }
        switch source {
        case .unknown: return .notConnected
        case .radioGPS(let isOn): return .radioGPS(isOn: isOn)
        case .phone:
            guard settings.isEnabled else { return .off }
            if isPausedForLowPower { return .pausedLowPower }
            if locationDenied { return .locationDenied }
            guard let lastFix else { return .waitingForLocation }
            return .phone(accuracy: lastFix.horizontalAccuracy, lastSync: lastSentAt)
        }
    }

    // MARK: RadioEventHandler

    public func radioDidConnect(_ info: ConnectionInfo, session: MeshSession) async {
        self.session = session
        radioKey = info.selfInfo.publicKey.hex
        radioName = info.selfInfo.name
        if alertedForDrop {
            alertedForDrop = false
            alerts?.radioReconnected()
        }
        settings = loadSettings()
        gate = GPSFeedGate(settings: settings)
        gate.reset(radioPosition: Coordinate(latitudeE6: info.selfInfo.latitudeE6, longitudeE6: info.selfInfo.longitudeE6), at: now())
        lastSent = gate.lastSent
        lastSentAt = nil
        lastError = nil
        loadWriteCount()

        source = await Self.detectSource { try await session.getCustomVars() }
        switch source {
        case .phone:
            restartLocationIfNeeded()
        case .radioGPS:
            stopLocation()
        case .unknown:
            stopLocation()
            lastError = "Couldn't check whether the radio has its own GPS, so the phone's position isn't sent. Reconnect to try again."
        }
    }

    public func radioDidDisconnect() {
        let wasFeeding = source == .phone && settings.isEnabled && !isPausedForLowPower
        session = nil
        source = .unknown
        stopLocation()
        // One alert per drop; a disconnect the user asked for is not a problem.
        if wasFeeding, !radio.lastDisconnectWasRequested, !alertedForDrop {
            alertedForDrop = true
            alerts?.radioConnectionLost(radioName: radioName)
        }
    }

    public func radioDidReceive(_ push: Push, session: MeshSession) async {}

    // MARK: Settings

    public func update(_ change: (inout GPSFeedSettings) -> Void) {
        let oldPreset = settings.preset
        let wasEnabled = settings.isEnabled
        change(&settings)
        gate.settings = settings
        saveSettings()
        if settings.isEnabled != wasEnabled || settings.preset != oldPreset {
            restartLocationIfNeeded()
        }
    }

    public func setPauseInLowPowerMode(_ pause: Bool) {
        guard pause != pauseInLowPowerMode else { return }
        let wasPaused = isPausedForLowPower
        pauseInLowPowerMode = pause
        defaults.set(pause, forKey: Self.pauseInLowPowerKey)
        if isPausedForLowPower != wasPaused { restartLocationIfNeeded() }
    }

    private func powerStateChanged() {
        let wasPaused = isPausedForLowPower
        isLowPowerModeOn = powerMonitor.isLowPowerModeEnabled
        if isPausedForLowPower != wasPaused { restartLocationIfNeeded() }
    }

    /// Turns on the radio's own GPS (`gps:1`).
    public func turnOnRadioGPS() async {
        guard let session else { return }
        do {
            try await session.perform(.setCustomVar(name: "gps", value: "1"))
            source = .radioGPS(isOn: true)
            lastError = nil
        } catch {
            lastError = "Couldn't turn on the radio's GPS: \(error.readable)"
        }
    }

    /// Shares (or stops sharing) the position in adverts (`advert_loc_policy`).
    public func setShareInAdverts(_ share: Bool) async {
        await updateOtherParams { $0.advertLocationPolicy = share ? 1 : 0 }
    }

    /// Who may read the position through telemetry requests (`telemetry_mode_loc`).
    public func setLocationTelemetry(_ mode: TelemetryMode) async {
        await updateOtherParams { $0.telemetryModes.location = mode }
    }

    private func updateOtherParams(_ change: (inout OtherParams) -> Void) async {
        guard let session, let selfInfo = radio.selfInfo else { return }
        var params = OtherParams(from: selfInfo)
        change(&params)
        do {
            try await session.perform(.setOtherParams(params))
            await radio.refreshSelfInfo()
            lastError = nil
        } catch {
            lastError = "Couldn't update the radio: \(error.readable)"
        }
    }

    // MARK: Location

    private func restartLocationIfNeeded() {
        stopLocation()
        guard session != nil, source == .phone, settings.isEnabled, !isPausedForLowPower else { return }
        let events = locationProvider.start(preset: settings.preset)
        locationTask = Task { [weak self] in
            for await event in events {
                await self?.handle(event)
            }
        }
    }

    private func stopLocation() {
        locationTask?.cancel()
        locationTask = nil
        locationProvider.stop()
    }

    func handle(_ event: LocationEvent) async {
        switch event {
        case .denied:
            locationDenied = true
        case .unavailable:
            break
        case .fix(let fix):
            locationDenied = false
            lastFix = fix
            await consider(fix)
        }
    }

    private func consider(_ fix: LocationFix) async {
        guard let session, source == .phone, settings.isEnabled, !isPausedForLowPower, !isWriting else { return }
        let radioPosition = radio.selfInfo.map { Coordinate(latitudeE6: $0.latitudeE6, longitudeE6: $0.longitudeE6) }
        guard case .send(let coordinate) = gate.evaluate(fix, now: now(), radioPosition: radioPosition) else { return }

        isWriting = true
        defer { isWriting = false }
        do {
            try await session.perform(.setAdvertLatLon(latitudeE6: coordinate.latitudeE6, longitudeE6: coordinate.longitudeE6))
            let sentAt = now()
            gate.recordSent(coordinate, at: sentAt)
            lastSent = coordinate
            lastSentAt = sentAt
            countWrite()
            lastError = nil
            await radio.refreshSelfInfo()
            await advertIfMoved(coordinate, session: session, at: sentAt)
        } catch {
            lastError = "Couldn't send position: \(error.readable)"
        }
    }

    private func advertIfMoved(_ coordinate: Coordinate, session: MeshSession, at date: Date) async {
        guard settings.advertOnMove else { return }
        if let (lastCoordinate, lastDate) = lastAdvert {
            guard coordinate.distance(to: lastCoordinate) >= settings.advertDistance,
                  date.timeIntervalSince(lastDate) >= settings.advertMinInterval else { return }
        }
        do {
            try await session.perform(.sendSelfAdvert(flood: settings.advertFlood))
            lastAdvert = (coordinate, date)
        } catch {
            lastError = "Couldn't send advert: \(error.readable)"
        }
    }

    // MARK: Persistence

    private var settingsKey: String { "gpsfeed.settings.\(radioKey ?? "default")" }

    private func loadSettings() -> GPSFeedSettings {
        guard let data = defaults.data(forKey: settingsKey),
              let stored = try? JSONDecoder().decode(GPSFeedSettings.self, from: data) else { return GPSFeedSettings() }
        return stored
    }

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: settingsKey)
        }
    }

    private var todayKey: String {
        let day = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: now())
        return "gpsfeed.writes.\(radioKey ?? "default").\(day.year ?? 0)-\(day.month ?? 0)-\(day.day ?? 0)"
    }

    private func loadWriteCount() {
        writesToday = defaults.integer(forKey: todayKey)
    }

    private func countWrite() {
        let key = todayKey
        writesToday = defaults.integer(forKey: key) + 1
        defaults.set(writesToday, forKey: key)
    }
}

extension GPSFeedService {
    /// Reads the radio's custom variables: a `gps` variable means it has a GPS module. Firmware that refuses the command
    /// has no GPS support. When the radio doesn't answer (twice) the source stays unknown, so the phone's position is
    /// never written to a radio that may have a GPS of its own.
    static func detectSource(_ readCustomVars: () async throws -> [String: String]) async -> Source {
        for attempt in 1...2 {
            do {
                let customVars = try await readCustomVars()
                return customVars["gps"].map { .radioGPS(isOn: $0 == "1") } ?? .phone
            } catch MeshError.device, MeshError.disabled, MeshError.unexpectedResponse {
                return .phone
            } catch {
                if attempt == 2 { return .unknown }
            }
        }
        return .unknown
    }
}
