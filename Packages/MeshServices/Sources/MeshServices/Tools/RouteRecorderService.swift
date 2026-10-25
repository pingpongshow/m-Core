import Foundation
import MeshTools
import Observation

/// One kept point of a recorded route.
public struct RoutePoint: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double
    /// Metres above sea level, when known.
    public var altitude: Double?
    /// Horizontal accuracy in metres.
    public var accuracy: Double
    public var time: Date

    public init(latitude: Double, longitude: Double, altitude: Double? = nil, accuracy: Double, time: Date) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.accuracy = accuracy
        self.time = time
    }

    public var coordinate: Coordinate { Coordinate(latitude: latitude, longitude: longitude) }
}

/// A GPS track of the phone, recorded with the route recorder.
public struct RecordedRoute: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var startedAt: Date
    /// Nil while recording.
    public var endedAt: Date?
    public var points: [RoutePoint]

    public init(id: UUID = UUID(), name: String, startedAt: Date, endedAt: Date? = nil, points: [RoutePoint] = []) {
        self.id = id
        self.name = name
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.points = points
    }

    /// Length of the track in metres.
    public var distance: Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + $1.0.coordinate.distance(to: $1.1.coordinate) }
    }

    /// From the start to the end of recording (or the last point while recording).
    public var duration: TimeInterval {
        let end = endedAt ?? points.last?.time ?? startedAt
        return max(0, end.timeIntervalSince(startedAt))
    }

    /// The track as GPX 1.1: one `<trk>` with a `<trkpt>` (time, and elevation when known) per point.
    public func gpx(creator: String = "m-Core") -> String {
        let name = CoverageExport.xmlEscape(name)
        var lines = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            #"<gpx version="1.1" creator="\#(CoverageExport.xmlEscape(creator))" xmlns="http://www.topografix.com/GPX/1/1">"#,
            "  <metadata>",
            "    <name>\(name)</name>",
            "    <time>\(Self.isoTime(startedAt))</time>",
            "  </metadata>",
            "  <trk>",
            "    <name>\(name)</name>",
            "    <trkseg>",
        ]
        for point in points {
            lines.append(String(format: #"      <trkpt lat="%.7f" lon="%.7f">"#, point.latitude, point.longitude))
            if let altitude = point.altitude { lines.append(String(format: "        <ele>%.1f</ele>", altitude)) }
            lines += ["        <time>\(Self.isoTime(point.time))</time>", "      </trkpt>"]
        }
        lines += ["    </trkseg>", "  </trk>", "</gpx>"]
        return lines.joined(separator: "\n") + "\n"
    }

    /// A file name for exports, e.g. "Morning walk.gpx".
    public var exportFileName: String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|")).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        return (cleaned.isEmpty ? "Route" : cleaned) + ".gpx"
    }

    private static func isoTime(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: .gmt))
    }
}

/// Records the phone's GPS track on request (PLAN.md §4.5) and keeps recordings on disk as JSON, one file each,
/// in Application Support.
///
/// Fixes worse than ``maxAccuracy`` are dropped, and a point is only kept once you've moved ``minDistance`` from the
/// last one, so standing still doesn't grow the file.
@MainActor
@Observable
public final class RouteRecorderService {
    public private(set) var routes: [RecordedRoute] = []
    /// The recording in progress.
    public private(set) var current: RecordedRoute?
    public private(set) var lastError: String?
    /// Accuracy of the latest fix, kept or not, so the UI can show GPS quality while recording.
    public private(set) var lastAccuracy: Double?
    public private(set) var locationDenied = false

    public static let maxAccuracy = 50.0
    public static let minDistance = 10.0
    /// Fixes older than this when they arrive are cached ones and are ignored.
    static let maxFixAge: TimeInterval = 30
    /// The in-progress recording is saved every this many points, so a crash loses little.
    static let saveEvery = 10

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let locationProvider: any LocationProvider
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var locationTask: Task<Void, Never>?
    @ObservationIgnored private var unsavedPoints = 0

    /// - Parameters:
    ///   - directory: Where recordings are kept; Application Support/Routes by default.
    ///   - locationProvider: A provider of its own (not the GPS Feed's), so both can run at once.
    public init(directory: URL? = nil, locationProvider: any LocationProvider, now: @escaping () -> Date = { Date() }) {
        self.directory = directory ?? URL.applicationSupportDirectory.appending(path: "Routes", directoryHint: .isDirectory)
        self.locationProvider = locationProvider
        self.now = now
        load()
    }

    public var isRecording: Bool { current != nil }

    // MARK: Recording

    public func start() {
        guard current == nil else { return }
        let started = now()
        current = RecordedRoute(name: started.formatted(date: .abbreviated, time: .shortened), startedAt: started)
        lastError = nil
        lastAccuracy = nil
        unsavedPoints = 0
        let events = locationProvider.start(preset: .walking)
        locationTask = Task { [weak self] in
            for await event in events {
                self?.handle(event)
            }
        }
    }

    /// Stops recording and saves the route; a recording with no points is discarded.
    @discardableResult
    public func stop() -> RecordedRoute? {
        locationTask?.cancel()
        locationTask = nil
        locationProvider.stop()
        guard var route = current else { return nil }
        current = nil
        guard !route.points.isEmpty else {
            try? FileManager.default.removeItem(at: fileURL(for: route.id))
            return nil
        }
        route.endedAt = now()
        save(route)
        routes.insert(route, at: 0)
        return route
    }

    func handle(_ event: LocationEvent) {
        switch event {
        case .denied:
            locationDenied = true
            lastError = "Location access is off. Allow it in Settings to record routes."
        case .unavailable:
            break
        case .fix(let fix):
            locationDenied = false
            lastAccuracy = fix.horizontalAccuracy
            record(fix)
        }
    }

    private func record(_ fix: LocationFix) {
        guard var route = current, fix.coordinate.isValid else { return }
        guard fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= Self.maxAccuracy else { return }
        guard now().timeIntervalSince(fix.timestamp) <= Self.maxFixAge, fix.timestamp >= route.startedAt.addingTimeInterval(-1) else {
            return
        }
        if let last = route.points.last, last.coordinate.distance(to: fix.coordinate) < Self.minDistance { return }
        route.points.append(RoutePoint(
            latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude, altitude: fix.altitude,
            accuracy: fix.horizontalAccuracy, time: fix.timestamp
        ))
        current = route
        unsavedPoints += 1
        if unsavedPoints >= Self.saveEvery {
            save(route)
            unsavedPoints = 0
        }
    }

    // MARK: Managing recordings

    public func rename(_ route: RecordedRoute, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = routes.firstIndex(where: { $0.id == route.id }) else { return }
        routes[index].name = trimmed
        save(routes[index])
    }

    public func delete(_ route: RecordedRoute) {
        routes.removeAll { $0.id == route.id }
        do {
            try FileManager.default.removeItem(at: fileURL(for: route.id))
        } catch {
            lastError = "Couldn't delete the route: \(error.localizedDescription)"
        }
    }

    // MARK: Persistence

    private func fileURL(for id: UUID) -> URL {
        directory.appending(path: "\(id.uuidString).json")
    }

    private func save(_ route: RecordedRoute) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            // Recording continues while the phone is locked, so the file must stay writable after first unlock.
            let options: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            try encoder.encode(route).write(to: fileURL(for: route.id), options: options)
        } catch {
            lastError = "Couldn't save the route: \(error.localizedDescription)"
        }
    }

    private func load() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        routes = files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard var route = try? decoder.decode(RecordedRoute.self, from: Data(contentsOf: url)) else { return nil }
            // A recording interrupted by the app quitting ends at its last saved point.
            if route.endedAt == nil {
                route.endedAt = route.points.last?.time ?? route.startedAt
                save(route)
            }
            return route
        }
        .sorted { $0.startedAt > $1.startedAt }
    }
}
