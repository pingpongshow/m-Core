import CoreLocation
import MeshDesign
import MeshMaps
import MeshServices
import MeshStore
import MeshTools
import SwiftUI
import UniformTypeIdentifiers

/// Walk or drive around while m-Core pings a repeater, then export where it worked as GPX or CSV.
struct CoverageView: View {
    @Environment(CoverageService.self) private var coverage
    @Environment(MessagingService.self) private var messaging
    @Environment(LocationTracker.self) private var location
    @Environment(OfflineMapStore.self) private var offlineMaps
    @Environment(\.colorScheme) private var colorScheme
    @State private var style = MapStyleProvider()
    @State private var targetKey: String?
    @State private var interval = 30
    @State private var camera: MapCameraRequest?

    var body: some View {
        let repeaters = (messaging.store?.contacts() ?? []).filter { $0.advertType == .repeater }
        List {
            Section {
                MeshMapView(styleURL: style.styleURL, dots: dots, camera: camera)
                    .frame(height: 260)
                    .listRowInsets(EdgeInsets())
                HStack {
                    Label("\(coverage.successCount) heard", systemImage: "checkmark.circle.fill").foregroundStyle(MCColor.positive)
                    Spacer()
                    Label("\(coverage.samples.count - coverage.successCount) missed", systemImage: "xmark.circle.fill")
                        .foregroundStyle(MCColor.critical)
                }
                .font(.footnote)
            }
            Section {
                Picker("Ping", selection: $targetKey) {
                    Text("Nothing (just listen)").tag(String?.none)
                    ForEach(repeaters, id: \.keyHex) { Text($0.displayName).tag(Optional($0.keyHex)) }
                }
                .disabled(coverage.isRunning)
                Picker("Every", selection: $interval) {
                    Text("15 s").tag(15)
                    Text("30 s").tag(30)
                    Text("1 min").tag(60)
                    Text("2 min").tag(120)
                }
                .disabled(coverage.isRunning)
                if coverage.isRunning {
                    Button("Stop", systemImage: "stop.fill", role: .destructive) {
                        coverage.stop()
                        location.stop()
                    }
                    // The app-wide accent tint would otherwise colour the icon of a destructive button.
                    .foregroundStyle(MCColor.critical)
                } else {
                    Button("Start", systemImage: "figure.walk") { start(repeaters: repeaters) }
                }
                if let error = coverage.lastError {
                    Text(error).font(.footnote).foregroundStyle(MCColor.warning)
                }
            } footer: {
                Text("""
                    Each ping traces a path to the repeater and back. Packets your radio overhears are logged too. \
                    Keep m-Core open while you walk.
                    """)
            }
            if !coverage.samples.isEmpty {
                Section {
                    ShareLink(item: CoverageGPXFile(samples: coverage.samples), preview: SharePreview("Coverage (GPX)")) {
                        Label("Export GPX", systemImage: "square.and.arrow.up")
                    }
                    ShareLink(item: CoverageCSVFile(samples: coverage.samples), preview: SharePreview("Coverage (CSV)")) {
                        Label("Export CSV", systemImage: "tablecells")
                    }
                    Button("Clear", systemImage: "trash", role: .destructive) { coverage.clear() }
                        .foregroundStyle(MCColor.critical)
                        .disabled(coverage.isRunning)
                }
                Section("Samples") {
                    ForEach(Array(coverage.samples.enumerated().reversed()), id: \.offset) { _, sample in
                        HStack {
                            Image(systemName: sample.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(sample.success ? MCColor.positive : MCColor.critical)
                            VStack(alignment: .leading) {
                                Text(sample.note ?? (sample.success ? "Heard" : "Missed")).font(.subheadline)
                                Text(sample.time.formatted(date: .omitted, time: .standard)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let snr = sample.snr { Text("\(snr.formatted()) dB").font(.caption.monospacedDigit()) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Coverage Walk")
        .onAppear { style.update(areas: offlineMaps.mapSourceURLs, dark: colorScheme == .dark) }
        // Start on the walk so far, or on the phone, rather than the whole world.
        .task {
            if !dots.isEmpty {
                camera = MapCameraRequest(target: .fit(dots.map(\.coordinate)))
            } else if let phone = await PhoneLocation.current(), coverage.samples.isEmpty {
                camera = MapCameraRequest(target: .center(phone.coordinate, zoom: 13))
            }
        }
        .onChange(of: colorScheme) { style.update(areas: offlineMaps.mapSourceURLs, dark: colorScheme == .dark) }
        .onChange(of: coverage.samples.count) {
            if let last = coverage.samples.last {
                camera = MapCameraRequest(target: .center(CLLocationCoordinate2D(latitude: last.coordinate.latitude,
                                                                                 longitude: last.coordinate.longitude), zoom: 14))
            }
        }
    }

    private var dots: [MapDot] {
        coverage.samples.enumerated().map { index, sample in
            MapDot(id: "\(index)",
                   coordinate: CLLocationCoordinate2D(latitude: sample.coordinate.latitude, longitude: sample.coordinate.longitude),
                   color: sample.success ? .systemGreen : .systemRed)
        }
    }

    private func start(repeaters: [ContactRecord]) {
        location.start()
        let target: CoverageService.Target = repeaters.first { $0.keyHex == targetKey }
            .map { .repeater(hashHex: String($0.keyHex.prefix(2)), name: $0.displayName) } ?? .listenOnly
        coverage.start(target: target, interval: .seconds(interval))
    }
}

/// Coverage samples as a GPX file, written only when the user shares it.
struct CoverageGPXFile: Transferable {
    let samples: [CoverageSample]

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: UTType(filenameExtension: "gpx", conformingTo: .xml) ?? .xml) { file in
            let name = "m-Core coverage \(Date().formatted(date: .abbreviated, time: .shortened))"
            let url = FileManager.default.temporaryDirectory.appending(path: "coverage.gpx")
            try CoverageExport.gpx(file.samples, name: name).write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
    }
}

/// Coverage samples as a CSV file, written only when the user shares it.
struct CoverageCSVFile: Transferable {
    let samples: [CoverageSample]

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .commaSeparatedText) { file in
            let url = FileManager.default.temporaryDirectory.appending(path: "coverage.csv")
            try CoverageExport.csv(file.samples).write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
    }
}
