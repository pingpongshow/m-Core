import MapKit
import MeshDesign
import MeshMaps
import Network
import SwiftUI

/// Frame an area on the map, see its exact size, and download it.
struct DownloadAreaView: View {
    let styleURL: URL?
    var startBounds: GeoBounds?
    @Environment(OfflineMapStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var search = PlaceSearch()
    @State private var bounds: GeoBounds?
    @State private var detail: OfflineMapDetail = .standard
    @State private var name = ""
    @State private var estimate: Estimate = .idle
    @State private var camera: MapCameraRequest?
    @State private var network = NetworkCost()
    /// Fixed for a given text size (see `panel`), but scaled with Dynamic Type so two lines are never clipped.
    @ScaledMetric(relativeTo: .footnote) private var estimateHeight = 36.0

    enum Estimate: Equatable {
        case idle
        case tooLarge
        /// The frame spans the 180° meridian, which an area can't cross.
        case crossesAntimeridian
        case calculating
        case ready(bytes: Int64, tiles: Int)
        /// Fits the size limits but not the user's storage cap.
        case overCap(bytes: Int64, available: Int64)
        case failed(String)
    }

    /// Larger areas take too long to plan and download on a phone.
    private static let maxTiles = 6_000_000
    private static let maxBytes: Int64 = 3_000_000_000

    var body: some View {
        MeshMapView(styleURL: styleURL, showsUserLocation: true, camera: camera, onRegionChange: { newBounds, _ in
            // Layout passes report the same region with tiny differences; only real moves re-measure.
            let rounded = newBounds.rounded
            if rounded != bounds { bounds = rounded }
        })
        .overlay {
            // Exactly the map's frame (which is the area measured), so all four edges show above the panel.
            Rectangle()
                .strokeBorder(MCColor.accent, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                .allowsHitTesting(false)
        }
        // No gap between the map and the panel.
        .safeAreaInset(edge: .bottom, spacing: 0) { panel }
        .navigationTitle("Download Area")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search for a place")
        .searchSuggestions {
            ForEach(search.completions, id: \.self) { completion in
                Button {
                    Task { await go(to: completion) }
                } label: {
                    // Plain text colours: in a button the whole suggestion list would otherwise be accent blue.
                    VStack(alignment: .leading) {
                        Text(completion.title).foregroundStyle(Color.primary)
                        if !completion.subtitle.isEmpty {
                            Text(completion.subtitle).font(.caption).foregroundStyle(Color.secondary)
                        }
                    }
                }
            }
        }
        .task(id: EstimateKey(bounds: bounds, detail: detail)) { await updateEstimate() }
        .onAppear {
            if camera == nil, let startBounds { camera = MapCameraRequest(target: .fit(startBounds.corners)) }
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: MCSpacing.m) {
            Text("Everything inside the dashed frame will be saved.")
                .font(.footnote).foregroundStyle(.secondary)
            TextField("Area name", text: $name)
                .textFieldStyle(.roundedBorder)
            Picker("Detail", selection: $detail) {
                ForEach(OfflineMapDetail.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(detail.summary).font(.caption).foregroundStyle(.secondary)
            // Fixed height: a panel that changes size would resize the map, change the area and re-measure.
            estimateText
                .frame(maxWidth: .infinity, minHeight: estimateHeight, maxHeight: estimateHeight, alignment: .leading)
            Label("You're on cellular data.", systemImage: "antenna.radiowaves.left.and.right")
                .font(.caption).foregroundStyle(MCColor.warning)
                .opacity(network.isExpensive ? 1 : 0)
            Button {
                startDownload()
            } label: {
                Text("Download").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canDownload)
        }
        .padding(MCSpacing.l)
        .background(.regularMaterial)
    }

    @ViewBuilder private var estimateText: some View {
        switch estimate {
        case .idle:
            EmptyView()
        case .calculating:
            HStack(spacing: MCSpacing.s) {
                ProgressView().controlSize(.small)
                Text("Measuring…").font(.footnote).foregroundStyle(.secondary)
            }
        case .tooLarge:
            Label(detail == .high ? "That area is too big. Zoom in or pick Standard detail." : "That area is too big. Zoom in.",
                  systemImage: "exclamationmark.triangle")
                .font(.footnote).foregroundStyle(MCColor.warning)
        case .crossesAntimeridian:
            Label("Areas can't cross the 180° line. Move the frame to one side of it.", systemImage: "exclamationmark.triangle")
                .font(.footnote).foregroundStyle(MCColor.warning)
        case let .ready(bytes, tiles):
            Text("\(bytes.formatted(.byteCount(style: .file))) · \(tiles.formatted()) tiles")
                .font(.footnote.weight(.semibold).monospacedDigit())
        case let .overCap(bytes, available):
            Label(OfflineMapStoreError.storageCapExceeded(required: bytes, available: available).errorDescription ?? "",
                  systemImage: "externaldrive.badge.exclamationmark")
                .font(.caption).foregroundStyle(MCColor.warning)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        case .failed(let message):
            Label(message, systemImage: "wifi.exclamationmark").font(.footnote).foregroundStyle(MCColor.critical)
        }
    }

    private var canDownload: Bool {
        guard case .ready = estimate, store.activeDownload == nil else { return false }
        return !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func updateEstimate() async {
        guard let bounds else { return }
        let tiles = TileRange(bounds: bounds.normalized, zoom: detail.zoomRange.upperBound).count
        guard tiles <= Self.maxTiles else {
            estimate = .tooLarge
            return
        }
        // MapLibre reports a view across the antimeridian as every longitude; small enough to get here, that is a
        // thin strip around the whole world rather than the framed area.
        guard bounds.maxLongitude - bounds.minLongitude < 359.9 else {
            estimate = .crossesAntimeridian
            return
        }
        estimate = .calculating
        // Wait for the map to settle before measuring.
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled else { return }
        do {
            let plan = try await store.estimate(bounds: bounds, detail: detail)
            guard !Task.isCancelled else { return }
            if plan.estimatedFileSize > Self.maxBytes {
                estimate = .tooLarge
            } else if let available = store.remainingCapacity(), plan.estimatedFileSize > available {
                estimate = .overCap(bytes: plan.estimatedFileSize, available: available)
            } else {
                estimate = .ready(bytes: plan.estimatedFileSize, tiles: plan.tileCount)
            }
        } catch is CancellationError {
            return
        } catch {
            if !Task.isCancelled { estimate = .failed("Couldn't reach the map server. Check your connection.") }
        }
    }

    private func go(to completion: MKLocalSearchCompletion) async {
        guard let region = await search.region(for: completion) else { return }
        if name.isEmpty { name = completion.title }
        search.query = ""
        let span = region.span
        camera = MapCameraRequest(target: .fit([
            CLLocationCoordinate2D(latitude: region.center.latitude - span.latitudeDelta / 2,
                                   longitude: region.center.longitude - span.longitudeDelta / 2),
            CLLocationCoordinate2D(latitude: region.center.latitude + span.latitudeDelta / 2,
                                   longitude: region.center.longitude + span.longitudeDelta / 2)
        ]))
    }

    private func startDownload() {
        guard let bounds else { return }
        let name = name
        let detail = detail
        // Not tied to this screen: the download carries on after it closes, and can be paused and resumed.
        OfflineMapActivity.shared.run(store) { try await $0.download(name: name, bounds: bounds, detail: detail) }
        dismiss()
    }
}

private extension GeoBounds {
    /// About 10 m precision.
    var rounded: GeoBounds {
        func round4(_ value: Double) -> Double { (value * 10_000).rounded() / 10_000 }
        return GeoBounds(minLongitude: round4(minLongitude), minLatitude: round4(minLatitude),
                         maxLongitude: round4(maxLongitude), maxLatitude: round4(maxLatitude))
    }
}

private struct EstimateKey: Equatable {
    var bounds: GeoBounds?
    var detail: OfflineMapDetail
}

/// Place search for framing an area, backed by MapKit's search completer.
@MainActor
@Observable
final class PlaceSearch: NSObject, @MainActor MKLocalSearchCompleterDelegate {
    var query = "" {
        didSet { completer.queryFragment = query }
    }

    private(set) var completions: [MKLocalSearchCompletion] = []
    @ObservationIgnored private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func region(for completion: MKLocalSearchCompletion) async -> MKCoordinateRegion? {
        let response = try? await MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start()
        return response?.boundingRegion
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        completions = Array(completer.results.prefix(8))
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: any Error) {}
}

/// Whether the current network is metered (cellular or a personal hotspot).
@MainActor
@Observable
final class NetworkCost {
    private(set) var isExpensive = false
    @ObservationIgnored private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let expensive = path.isExpensive
            Task { @MainActor in self?.isExpensive = expensive }
        }
        monitor.start(queue: .main)
    }

    deinit { monitor.cancel() }
}
