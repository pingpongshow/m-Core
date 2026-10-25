import CoreLocation
import MeshDesign
import MeshMaps
import MeshServices
import SwiftUI
import UniformTypeIdentifiers

/// Record the phone's GPS track, then view, rename, delete or export recordings as GPX.
struct RouteRecorderView: View {
    @Environment(RouteRecorderService.self) private var recorder
    @State private var renaming: RecordedRoute?
    @State private var newName = ""

    var body: some View {
        List {
            Section {
                if let current = recorder.current {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        LabeledContent("Recording", value: RouteFormat.duration(context.date.timeIntervalSince(current.startedAt)))
                    }
                    LabeledContent("Distance", value: RouteFormat.distance(current.distance))
                    LabeledContent("Points", value: current.points.count.formatted())
                    if let accuracy = recorder.lastAccuracy {
                        LabeledContent("GPS accuracy", value: "±\(Int(accuracy.rounded())) m")
                    }
                    Button("Stop recording", systemImage: "stop.fill", role: .destructive) { recorder.stop() }
                        .foregroundStyle(MCColor.critical)
                } else {
                    Button("Start recording", systemImage: "record.circle") { recorder.start() }
                }
                if let error = recorder.lastError {
                    Text(error).font(.footnote).foregroundStyle(MCColor.warning)
                }
            } footer: {
                Text("""
                    Records where you go, even with m-Core in the background (iOS shows a blue location indicator). \
                    Fixes less accurate than 50 m are skipped, and a point is kept every 10 m you move.
                    """)
            }
            if !recorder.routes.isEmpty {
                Section("Recordings") {
                    ForEach(recorder.routes) { route in
                        NavigationLink {
                            RouteDetailView(routeID: route.id)
                        } label: {
                            RouteRow(route: route)
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) { recorder.delete(route) }.tint(MCColor.critical)
                            Button("Rename") { startRenaming(route) }.tint(MCColor.accentFill)
                        }
                        .contextMenu {
                            Button("Rename", systemImage: "pencil") { startRenaming(route) }
                            ShareLink(item: RouteGPXFile(route: route), preview: SharePreview(route.name)) {
                                Label("Export GPX", systemImage: "square.and.arrow.up")
                            }
                            Button("Delete", systemImage: "trash", role: .destructive) { recorder.delete(route) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Route Recorder")
        .alert("Rename route", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") {
                if let renaming { recorder.rename(renaming, to: newName) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private func startRenaming(_ route: RecordedRoute) {
        newName = route.name
        renaming = route
    }
}

private struct RouteRow: View {
    let route: RecordedRoute

    var body: some View {
        VStack(alignment: .leading, spacing: MCSpacing.xxs) {
            Text(route.name)
            Text("\(RouteFormat.distance(route.distance)) · \(RouteFormat.duration(route.duration)) · "
                + route.startedAt.formatted(date: .abbreviated, time: .omitted))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// One recording on the map, with its stats and export.
struct RouteDetailView: View {
    let routeID: UUID
    @Environment(RouteRecorderService.self) private var recorder
    @Environment(OfflineMapStore.self) private var offlineMaps
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @State private var style = MapStyleProvider()
    @State private var camera: MapCameraRequest?
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDelete = false

    var body: some View {
        if let route = recorder.routes.first(where: { $0.id == routeID }) {
            content(route)
        } else {
            ContentUnavailableView("Route deleted", systemImage: "point.bottomleft.forward.to.point.topright.scurvepath")
        }
    }

    private func content(_ route: RecordedRoute) -> some View {
        let coordinates = route.points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        return List {
            Section {
                MeshMapView(
                    styleURL: style.styleURL, pins: pins(route),
                    lines: [MapLine(id: route.id.uuidString, coordinates: coordinates, color: .systemBlue, width: 4)],
                    showsUserLocation: false, camera: camera
                )
                .frame(height: 320)
                .listRowInsets(EdgeInsets())
            }
            statsSection(route)
            Section {
                ShareLink(item: RouteGPXFile(route: route), preview: SharePreview(route.name)) {
                    Label("Export GPX", systemImage: "square.and.arrow.up")
                }
                Button("Rename", systemImage: "pencil") {
                    newName = route.name
                    renaming = true
                }
                Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    .foregroundStyle(MCColor.critical)
                    .confirmationDialog("Delete this route?", isPresented: $confirmDelete, titleVisibility: .visible) {
                        Button("Delete", role: .destructive) {
                            recorder.delete(route)
                            dismiss()
                        }
                    }
            }
        }
        .navigationTitle(route.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            style.update(areas: offlineMaps.mapSourceURLs, dark: colorScheme == .dark)
            if coordinates.count > 1 {
                camera = MapCameraRequest(target: .fit(coordinates))
            } else if let first = coordinates.first {
                camera = MapCameraRequest(target: .center(first, zoom: 15))
            }
        }
        .onChange(of: colorScheme) { style.update(areas: offlineMaps.mapSourceURLs, dark: colorScheme == .dark) }
        .alert("Rename route", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Save") { recorder.rename(route, to: newName) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func statsSection(_ route: RecordedRoute) -> some View {
        Section {
            LabeledContent("Distance", value: RouteFormat.distance(route.distance))
            LabeledContent("Duration", value: RouteFormat.duration(route.duration))
            LabeledContent("Started", value: route.startedAt.formatted(date: .abbreviated, time: .shortened))
            LabeledContent("Points", value: route.points.count.formatted())
            if let range = altitudeRange(route) {
                LabeledContent("Elevation", value: range)
            }
        }
    }

    /// Start and end markers.
    private func pins(_ route: RecordedRoute) -> [MapPin] {
        guard let first = route.points.first, let last = route.points.last else { return [] }
        var pins = [MapPin(id: "start", coordinate: CLLocationCoordinate2D(latitude: first.latitude, longitude: first.longitude),
                           title: "Start", kind: .contact)]
        if route.points.count > 1 {
            pins.append(MapPin(id: "end", coordinate: CLLocationCoordinate2D(latitude: last.latitude, longitude: last.longitude),
                               title: "End", kind: .contact))
        }
        return pins
    }

    private func altitudeRange(_ route: RecordedRoute) -> String? {
        let altitudes = route.points.compactMap(\.altitude)
        guard let low = altitudes.min(), let high = altitudes.max() else { return nil }
        return "\(Int(low.rounded()))–\(Int(high.rounded())) m"
    }
}

/// A recording as a GPX file, written only when the user shares it.
struct RouteGPXFile: Transferable {
    let route: RecordedRoute

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: UTType(filenameExtension: "gpx", conformingTo: .xml) ?? .xml) { file in
            let url = FileManager.default.temporaryDirectory.appending(path: file.route.exportFileName)
            try file.route.gpx().write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
    }
}

enum RouteFormat {
    static func distance(_ metres: Double) -> String {
        Measurement(value: metres, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road, numberFormatStyle: .number.precision(.fractionLength(0...1))))
    }

    static func duration(_ seconds: TimeInterval) -> String {
        Duration.seconds(max(0, seconds)).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
    }
}
