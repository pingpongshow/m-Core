import Foundation
import MeshCoreKit
import MeshStore
import MeshTools
import Testing
@testable import MeshServices

private let start = Date(timeIntervalSince1970: 1_800_000_000)
private let sanFrancisco = Coordinate(latitude: 37.7749, longitude: -122.4194)

private func north(of origin: Coordinate, metres: Double) -> Coordinate {
    Coordinate(latitude: origin.latitude + metres / 111_195, longitude: origin.longitude)
}

private func fix(_ coordinate: Coordinate, accuracy: Double = 5, at date: Date, altitude: Double? = nil) -> LocationEvent {
    .fix(LocationFix(coordinate: coordinate, horizontalAccuracy: accuracy, timestamp: date, altitude: altitude))
}

struct RxLogCSVTests {
    @Test func csvHasOneRowPerRecordOldestFirst() {
        let decoded = RxLogRecord(id: 1, date: start.addingTimeInterval(5), snr: 6.75, rssi: -88, raw: sampleRawPacket,
                                  packet: MeshPacket.decode(sampleRawPacket))
        let garbage = RxLogRecord(id: 0, date: start, snr: -2.5, rssi: -120, raw: Data([0xFF]), packet: nil)
        let csv = RxLogService.csv([decoded, garbage])
        let rows = csv.components(separatedBy: "\r\n")
        #expect(rows[0] == "time,snr,rssi,type,route,hops,hash,raw")
        #expect(rows[1] == "2027-01-15T08:00:00Z,-2.5,-120,,,,,FF")
        let packet = decoded.packet
        #expect(packet != nil)
        #expect(rows[2] == "2027-01-15T08:00:05Z,6.75,-88,\(packet?.payloadType.name ?? ""),flood,0,\(packet?.hashHex ?? ""),0900A1B2C3D4")
        #expect(rows.count == 4)
        #expect(rows[3].isEmpty)
    }

    @Test func emptyLogIsJustTheHeader() {
        #expect(RxLogService.csv([]) == "time,snr,rssi,type,route,hops,hash,raw\r\n")
    }
}

@MainActor
struct RouteRecorderTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "routes-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test func recordsFilteredTrackAndPersists() async throws {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = MutableClock(start)
        let location = MockLocationProvider()
        let recorder = RouteRecorderService(directory: folder, locationProvider: location, now: { clock.now })
        #expect(recorder.routes.isEmpty)

        recorder.start()
        #expect(recorder.isRecording)
        #expect(location.isRunning)
        location.send(fix(sanFrancisco, at: start, altitude: 12))
        location.send(fix(north(of: sanFrancisco, metres: 5), at: start.addingTimeInterval(5)))     // too close
        location.send(fix(north(of: sanFrancisco, metres: 40), accuracy: 80, at: start.addingTimeInterval(6))) // inaccurate
        try await waitUntil { recorder.lastAccuracy == 80 }
        #expect(recorder.current?.points.count == 1)
        clock.now = start.addingTimeInterval(120)
        location.send(fix(north(of: sanFrancisco, metres: 60), at: start.addingTimeInterval(10)))   // stale by now
        location.send(fix(north(of: sanFrancisco, metres: 100), at: clock.now))
        try await waitUntil { recorder.current?.points.count == 2 }
        #expect(recorder.lastAccuracy == 5)

        clock.now = start.addingTimeInterval(180)
        let route = try #require(recorder.stop())
        #expect(!recorder.isRecording)
        #expect(!location.isRunning)
        #expect(route.points.count == 2)
        #expect(route.points[0].altitude == 12)
        #expect(abs(route.distance - 100) < 1)
        #expect(route.duration == 180)
        #expect(recorder.routes.map(\.id) == [route.id])

        // A new service instance reads it back from disk.
        let reloaded = RouteRecorderService(directory: folder, locationProvider: MockLocationProvider())
        #expect(reloaded.routes.count == 1)
        #expect(reloaded.routes.first?.points == route.points)
        #expect(reloaded.routes.first?.endedAt == route.endedAt)
    }

    @Test func emptyRecordingIsDiscarded() {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let recorder = RouteRecorderService(directory: folder, locationProvider: MockLocationProvider())
        recorder.start()
        #expect(recorder.stop() == nil)
        #expect(recorder.routes.isEmpty)
    }

    @Test func renameDeleteAndGPX() async throws {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = MutableClock(start)
        let location = MockLocationProvider()
        let recorder = RouteRecorderService(directory: folder, locationProvider: location, now: { clock.now })
        recorder.start()
        location.send(fix(sanFrancisco, at: start, altitude: 15.25))
        location.send(fix(north(of: sanFrancisco, metres: 50), at: start))
        try await waitUntil { recorder.current?.points.count == 2 }
        let route = try #require(recorder.stop())

        recorder.rename(route, to: "  Twin <Peaks> & back ")
        let renamed = try #require(recorder.routes.first)
        #expect(renamed.name == "Twin <Peaks> & back")
        #expect(RouteRecorderService(directory: folder, locationProvider: MockLocationProvider()).routes.first?.name == renamed.name)

        let gpx = renamed.gpx()
        #expect(gpx.contains(#"<gpx version="1.1" creator="m-Core" xmlns="http://www.topografix.com/GPX/1/1">"#))
        #expect(gpx.contains("<name>Twin &lt;Peaks&gt; &amp; back</name>"))
        #expect(gpx.contains(#"<trkpt lat="37.7749000" lon="-122.4194000">"#))
        #expect(gpx.contains("<ele>15.2</ele>") || gpx.contains("<ele>15.3</ele>"))
        #expect(gpx.contains("<time>2027-01-15T08:00:00Z</time>"))
        #expect(gpx.components(separatedBy: "<trkpt").count == 3)
        #expect(renamed.exportFileName == "Twin -Peaks- & back.gpx")

        recorder.delete(renamed)
        #expect(recorder.routes.isEmpty)
        #expect(RouteRecorderService(directory: folder, locationProvider: MockLocationProvider()).routes.isEmpty)
    }

    @Test func interruptedRecordingIsRecoveredOnLaunch() async throws {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = MutableClock(start)
        let location = MockLocationProvider()
        let recorder = RouteRecorderService(directory: folder, locationProvider: location, now: { clock.now })
        recorder.start()
        for step in 0..<RouteRecorderService.saveEvery {
            let time = start.addingTimeInterval(Double(step))
            clock.now = time
            location.send(fix(north(of: sanFrancisco, metres: Double(step) * 20), at: time))
        }
        try await waitUntil { recorder.current?.points.count == RouteRecorderService.saveEvery }
        // The app is killed here, without stop(); the periodic save kept the track.
        let relaunched = RouteRecorderService(directory: folder, locationProvider: MockLocationProvider())
        let recovered = try #require(relaunched.routes.first)
        #expect(recovered.points.count == RouteRecorderService.saveEvery)
        #expect(recovered.endedAt == recovered.points.last?.time)
    }
}

@MainActor
struct ObserverBackgroundTests {
    @Test func pausesInBackgroundOnlyWhenChosen() async throws {
        let mock = MockRadio()
        let radio = RadioController(defaults: UserDefaults(suiteName: "obsbg.\(UUID().uuidString)")!, simulatedRadio: mock)
        await radio.connect(to: .simulator)
        try await waitUntil { radio.isConnected }
        let observer = ObserverService(
            radio: radio, defaults: UserDefaults(suiteName: "obsbg.\(UUID().uuidString)")!, secrets: MemorySecrets(),
            reachability: FakeReachability(isOnWiFi: true), clientVersion: "m-Core test", makeTransport: { _ in FakeMQTTTransport() }
        )
        var settings = observer.settings
        #expect(settings.pauseInBackground == false)
        settings.isEnabled = true
        settings.iata = "SFO"
        observer.update(settings)
        try await waitUntil { if case .connected = observer.status { true } else { false } }

        // Without the option, going to the background keeps the uplink.
        observer.setAppActive(false)
        if case .connected = observer.status {} else { Issue.record("expected to stay connected, got \(observer.status)") }

        settings.pauseInBackground = true
        observer.update(settings)
        #expect(observer.status == .pausedInBackground)

        observer.setAppActive(true)
        try await waitUntil { if case .connected = observer.status { true } else { false } }
        observer.setAppActive(false)
        #expect(observer.status == .pausedInBackground)
        await radio.disconnect()
    }

    @Test func settingsFromOlderVersionsStillLoad() throws {
        let old = #"{"isEnabled":true,"broker":"custom","iata":"LAX","wifiOnly":false,"customHost":"h","customPort":1884,"#
            + #""customTransport":"tls","customPath":"/mqtt","customUsername":"u"}"#
        let settings = try JSONDecoder().decode(ObserverSettings.self, from: Data(old.utf8))
        #expect(settings.isEnabled)
        #expect(settings.customPort == 1884)
        #expect(settings.pauseInBackground == false)
        let roundTrip = try JSONDecoder().decode(ObserverSettings.self, from: JSONEncoder().encode(settings))
        #expect(roundTrip == settings)
    }
}

struct RemoteSettingCommandTests {
    @Test func commandStrings() {
        let radio = RemoteRadioParameters(frequencyMHz: 869.618, bandwidthKHz: 62.5, spreadingFactor: 8, codingRate: 5)
        #expect(RemoteSetting.name("Hilltop RPT").command == "set name Hilltop RPT")
        #expect(RemoteSetting.radio(radio).command == "set radio 869.618,62.5,8,5")
        #expect(RemoteSetting.radio(RemoteRadioParameters(frequencyMHz: 910.525, bandwidthKHz: 250, spreadingFactor: 11, codingRate: 8))
            .command == "set radio 910.525,250,11,8")
        #expect(RemoteSetting.txPower(20).command == "set tx 20")
        #expect(RemoteSetting.advertInterval(minutes: 120).command == "set advert.interval 120")
        #expect(RemoteSetting.floodAdvertInterval(hours: 47).command == "set flood.advert.interval 47")
        #expect(RemoteSetting.floodMaxHops(8).command == "set flood.max 8")
        #expect(RemoteSetting.guestPassword("hello").command == "set guest.password hello")
        #expect(RemoteSetting.adminPassword("s3cret").command == "password s3cret")
        #expect(RemoteSetting.latitude(37.7544).command == "set lat 37.7544")
        #expect(RemoteSetting.longitude(-122.4477).command == "set lon -122.4477")
        #expect(RemoteSetting.repeatEnabled(false).command == "set repeat off")
        #expect(RemoteSetting.sendAdvert.command == "advert")
        #expect(RemoteSetting.sendZeroHopAdvert.command == "advert.zerohop")
        #expect(RemoteSetting.reboot.command == "reboot")
        #expect(RemoteSettingKey.radio.getCommand == "get radio")
        #expect(RemoteSettingKey.floodAdvertInterval.getCommand == "get flood.advert.interval")
    }

    @Test func validation() {
        #expect(RemoteSetting.name("bad,name").validationError != nil)
        #expect(RemoteSetting.name(String(repeating: "x", count: 32)).validationError != nil)
        #expect(RemoteSetting.advertInterval(minutes: 30).validationError != nil)
        #expect(RemoteSetting.advertInterval(minutes: 0).validationError == nil)
        #expect(RemoteSetting.floodAdvertInterval(hours: 2).validationError != nil)
        #expect(RemoteSetting.floodMaxHops(65).validationError != nil)
        #expect(RemoteSetting.txPower(30).validationError != nil)
        #expect(RemoteSetting.guestPassword(String(repeating: "p", count: 16)).validationError != nil)
        #expect(RemoteSetting.radio(RemoteRadioParameters(frequencyMHz: 869.5, bandwidthKHz: 62.5, spreadingFactor: 13, codingRate: 5))
            .validationError != nil)
    }

    @Test func replyParsing() {
        #expect(RemoteCLIReply.value(of: "> 47") == "47")
        #expect(RemoteCLIReply.value(of: "> ") == "")
        #expect(RemoteCLIReply.value(of: "??: radio") == nil)
        #expect(RemoteCLIReply.isError("Error, max 64"))
        #expect(RemoteCLIReply.isError("ERROR: af must be 0-9"))
        #expect(RemoteCLIReply.isError("unknown config: foo"))
        #expect(RemoteCLIReply.isError("??: foo"))
        #expect(!RemoteCLIReply.isError("OK - reboot to apply"))
        #expect(!RemoteCLIReply.isError("OK - repeat is now OFF"))

        var settings = RemoteNodeSettings()
        settings.apply("869.618,62.5,8,5", for: .radio)
        settings.apply("on", for: .repeatEnabled)
        settings.apply("-122.4477", for: .longitude)
        settings.apply("garbage", for: .txPower)
        #expect(settings.radio == RemoteRadioParameters(frequencyMHz: 869.618, bandwidthKHz: 62.5, spreadingFactor: 8, codingRate: 5))
        #expect(settings.repeatEnabled == true)
        #expect(settings.longitude == -122.4477)
        #expect(settings.txPowerDbm == nil)
    }
}

@MainActor
struct RemoteSettingsServiceTests {
    private let repeater = MockRadio.demoKey(0x10).hex

    struct Connection {
        let mock: MockRadio
        let radio: RadioController
        let remote: RemoteNodeService
    }

    private func connect() async throws -> Connection {
        let mock = MockRadio(state: MockRadio.demoState)
        let radio = RadioController(defaults: UserDefaults(suiteName: "rset.\(UUID().uuidString)")!, simulatedRadio: mock)
        let messaging = MessagingService(
            radio: radio, defaults: UserDefaults(suiteName: "rset.\(UUID().uuidString)")!,
            storeFactory: { try RadioStore(radioKeyHex: $0, inMemory: true) }
        )
        let remote = RemoteNodeService(radio: radio, messaging: messaging)
        await radio.connect(to: .simulator)
        try await waitUntil { messaging.store != nil && !messaging.isSyncing && messaging.revision > 0 }
        _ = try await remote.login(keyHex: repeater, password: "password")
        return Connection(mock: mock, radio: radio, remote: remote)
    }

    @Test func readsEverySetting() async throws {
        let connection = try await connect()
        let (mock, radio, remote) = (connection.mock, connection.radio, connection.remote)
        var updates = 0
        let settings = try await remote.readSettings(keyHex: repeater) { _ in updates += 1 }
        #expect(settings.name == "Charlie Node")
        #expect(settings.radio == RemoteRadioParameters(frequencyMHz: 910.525, bandwidthKHz: 62.5, spreadingFactor: 7, codingRate: 5))
        #expect(settings.txPowerDbm == 22)
        #expect(settings.advertIntervalMinutes == 0)
        #expect(settings.floodAdvertIntervalHours == 47)
        #expect(settings.floodMaxHops == 64)
        #expect(settings.guestPassword == "")
        #expect(settings.latitude == 37.7544)
        #expect(settings.repeatEnabled == true)
        #expect(updates == RemoteSettingKey.allCases.count)
        #expect(mock.current.remoteCLICommands == RemoteSettingKey.allCases.map(\.getCommand))
        await radio.disconnect()
    }

    @Test func appliesChangesAndReportsRejections() async throws {
        let connection = try await connect()
        let mock = connection.mock
        let radio = connection.radio
        let remote = connection.remote
        #expect(try await remote.apply(.floodMaxHops(8), keyHex: repeater) == "OK")
        #expect(mock.current.remoteSettings["flood.max"] == "8")
        let radioReply = try await remote.apply(
            .radio(RemoteRadioParameters(frequencyMHz: 869.618, bandwidthKHz: 62.5, spreadingFactor: 8, codingRate: 5)), keyHex: repeater
        )
        #expect(radioReply == "OK - reboot to apply")
        #expect(mock.current.remoteSettings["radio"] == "869.618,62.5,8,5")
        #expect(try await remote.apply(.repeatEnabled(false), keyHex: repeater) == "OK - repeat is now OFF")
        #expect(try await remote.readSetting(.repeatEnabled, keyHex: repeater) == "off")
        #expect(try await remote.apply(.sendAdvert, keyHex: repeater) == "OK - Advert sent")
        #expect(try await remote.apply(.adminPassword("newpass"), keyHex: repeater) == "password now: newpass")

        // Values the firmware would refuse aren't sent at all.
        let sent = mock.current.remoteCLICommands.count
        await #expect(throws: RemoteSettingError.self) { try await remote.apply(.floodMaxHops(99), keyHex: repeater) }
        #expect(mock.current.remoteCLICommands.count == sent)

        // An error reply from the node is surfaced.
        mock.update { $0.remoteSettings["flood.max"] = nil }
        await #expect(throws: RemoteSettingError.rejected("unknown config: flood.max 4")) {
            try await remote.apply(.floodMaxHops(4), keyHex: repeater)
        }
        await radio.disconnect()
    }
}
