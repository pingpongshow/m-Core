import CoreLocation
import MeshCoreKit
import MeshDesign
import MeshMaps
import MeshServices
import MeshStore
import SwiftUI
import UniformTypeIdentifiers

/// Build a path from known repeaters, trace it, see it on the map and share the result as a card.
struct TraceView: View {
    @Environment(TraceService.self) private var traces
    @Environment(MessagingService.self) private var messaging
    @Environment(RadioController.self) private var radio
    @Environment(OfflineMapStore.self) private var offlineMaps
    @Environment(AppRouter.self) private var router
    @Environment(\.colorScheme) private var colorScheme
    @State private var path: [ContactRecord] = []
    @State private var status: String?
    @State private var isRunning = false
    @State private var style = MapStyleProvider()
    @State private var camera: MapCameraRequest?
    @State private var shownOutcomeID: UUID?
    /// Small renderings of each trace's share card, for the share sheet's preview.
    @State private var cardThumbnails: [UUID: Image] = [:]

    var body: some View {
        let repeaters = (messaging.store?.contacts() ?? []).filter { $0.advertType == .repeater }
        List {
            pathSection(repeaters: repeaters)
            Section {
                Button(isRunning ? "Tracing…" : "Run trace", systemImage: "play.fill") { run() }
                    .disabled(path.isEmpty || isRunning)
                if let status { Text(status).font(.footnote).foregroundStyle(.secondary) }
            }
            if let shown = shownOutcome { mapSection(shown) }
            ForEach(traces.history) { outcome in
                outcomeSection(outcome)
            }
        }
        .navigationTitle("Trace Path")
        .toolbar { EditButton() }
        .onAppear {
            updateStyle()
            fitCamera()
            if let keys = router.tracePrefill {
                router.tracePrefill = nil
                path = keys.compactMap { messaging.store?.contact(keyHex: $0) }
            }
        }
        .onChange(of: colorScheme) { updateStyle() }
        .onChange(of: traces.history.first?.id) {
            shownOutcomeID = traces.history.first?.id
            fitCamera()
        }
    }

    private var shownOutcome: TraceOutcome? {
        traces.history.first { $0.id == shownOutcomeID } ?? traces.history.first
    }

    // MARK: Sections

    private func pathSection(repeaters: [ContactRecord]) -> some View {
        Section {
            if path.isEmpty {
                Text("Add repeaters in the order the trace should travel.").foregroundStyle(.secondary)
            }
            ForEach(Array(path.enumerated()), id: \.offset) { index, hop in
                HStack {
                    Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    AvatarView(name: hop.displayName, kind: .repeater, size: 28)
                    Text(hop.displayName)
                    Spacer()
                    Text(hop.keyHex.prefix(2).uppercased()).font(.body.monospaced()).foregroundStyle(.secondary)
                }
            }
            .onDelete { path.remove(atOffsets: $0) }
            .onMove { path.move(fromOffsets: $0, toOffset: $1) }
            Menu("Add repeater", systemImage: "plus") {
                ForEach(repeaters, id: \.keyHex) { repeater in
                    Button(repeater.displayName) { path.append(repeater) }
                }
            }
            .disabled(repeaters.isEmpty)
        } header: {
            Text("Path")
        }
    }

    private func mapSection(_ outcome: TraceOutcome) -> some View {
        let route = mapRoute(for: outcome)
        return Section {
            MeshMapView(styleURL: style.styleURL, pins: route.pins, lines: route.lines, showsUserLocation: false, camera: camera)
                .frame(height: 240)
                .listRowInsets(EdgeInsets())
            if route.unknownCount > 0 {
                Text(route.unknownCount == 1
                     ? "1 hop has no known position and isn't drawn."
                     : "\(route.unknownCount) hops have no known position and aren't drawn.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Map · \(outcome.date.formatted(date: .omitted, time: .standard))")
        }
    }

    private func outcomeSection(_ outcome: TraceOutcome) -> some View {
        Section(outcome.date.formatted(date: .omitted, time: .standard)) {
            ForEach(Array(outcome.hops.enumerated()), id: \.offset) { _, hop in
                LabeledContent(hopName(hop)) {
                    HStack { SignalBars(snr: hop.snr); Text("\(hop.snr.formatted()) dB") }
                }
            }
            LabeledContent("Back to you") {
                HStack { SignalBars(snr: outcome.finalSNR); Text("\(outcome.finalSNR.formatted()) dB") }
            }
            LabeledContent("Round trip", value: Self.roundTripText(outcome.roundTrip))
            if outcome.id != shownOutcome?.id {
                Button("Show on map", systemImage: "map") {
                    shownOutcomeID = outcome.id
                    fitCamera()
                }
            }
            ShareLink(item: card(for: outcome), preview: SharePreview(
                "Trace \(outcome.date.formatted(date: .abbreviated, time: .shortened))",
                // A symbol image shows as a blank tile in the share sheet; the card itself is a better preview.
                image: cardThumbnails[outcome.id] ?? Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
            )) {
                Label("Share card", systemImage: "square.and.arrow.up")
            }
        }
        .task(id: outcome.id) {
            guard cardThumbnails[outcome.id] == nil else { return }
            let card = card(for: outcome)
            let renderer = ImageRenderer(content: TraceShareCard(outcome: outcome, radioName: card.radioName, hopNames: card.hopNames))
            renderer.scale = 1
            if let image = renderer.uiImage { cardThumbnails[outcome.id] = Image(uiImage: image) }
        }
    }

    // MARK: Map

    private struct MapRoute {
        var pins: [MapPin] = []
        var lines: [MapLine] = []
        var coordinates: [CLLocationCoordinate2D] = []
        var unknownCount = 0
    }

    /// Your radio, then each hop with a known position, joined in order. Hops without a position are skipped.
    private func mapRoute(for outcome: TraceOutcome) -> MapRoute {
        var route = MapRoute()
        if let info = radio.selfInfo, info.latitudeE6 != 0 || info.longitudeE6 != 0 {
            let coordinate = CLLocationCoordinate2D(latitude: info.latitude, longitude: info.longitude)
            route.pins.append(MapPin(id: "trace-radio", coordinate: coordinate, title: info.name, kind: .contact, isRadio: true))
            route.coordinates.append(coordinate)
        }
        for (index, hop) in outcome.hops.enumerated() {
            guard let contact = messaging.store?.contact(prefixHex: hop.hashHex), let coordinate = contact.coordinate else {
                route.unknownCount += 1
                continue
            }
            route.pins.append(MapPin(id: "trace-\(index)-\(contact.keyHex)", coordinate: coordinate,
                                     title: "\(index + 1). \(contact.displayName) · \(hop.snr.formatted()) dB", kind: .repeater))
            route.coordinates.append(coordinate)
        }
        if route.coordinates.count > 1 {
            route.lines.append(MapLine(id: "trace-\(outcome.id)", coordinates: route.coordinates, color: .systemBlue, width: 3))
        }
        return route
    }

    private func fitCamera() {
        guard let outcome = shownOutcome else { return }
        let coordinates = mapRoute(for: outcome).coordinates
        guard let first = coordinates.first else { return }
        camera = coordinates.count == 1
            ? MapCameraRequest(target: .center(first, zoom: 12))
            : MapCameraRequest(target: .fit(coordinates))
    }

    private func updateStyle() {
        style.update(areas: offlineMaps.mapSourceURLs, dark: colorScheme == .dark)
    }

    // MARK: Helpers

    private func hopName(_ hop: TraceHop) -> String {
        messaging.store?.contact(prefixHex: hop.hashHex)?.displayName ?? hop.hashHex
    }

    private func card(for outcome: TraceOutcome) -> TraceCardImage {
        TraceCardImage(
            outcome: outcome,
            radioName: radio.selfInfo?.name ?? "My radio",
            hopNames: outcome.hops.map(hopName)
        )
    }

    static func roundTripText(_ duration: Duration) -> String {
        duration.formatted(.units(allowed: [.seconds, .milliseconds], width: .abbreviated))
    }

    private func run() {
        isRunning = true
        status = nil
        Task {
            defer { isRunning = false }
            do {
                let hashes = path.compactMap { Data(hexString: String($0.keyHex.prefix(2))).map { [UInt8]($0) } }
                _ = try await traces.trace(path: hashes)
            } catch RemoteRequestError.timedOut {
                status = "The trace didn't come back. A repeater on the path may be out of range."
            } catch {
                status = "Failed: \(errorMessage(error))"
            }
        }
    }
}

/// A finished trace as a shareable PNG, rendered only when the user shares it.
struct TraceCardImage: Transferable {
    let outcome: TraceOutcome
    let radioName: String
    let hopNames: [String]

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { card in
            try await MainActor.run {
                let content = TraceShareCard(outcome: card.outcome, radioName: card.radioName, hopNames: card.hopNames)
                let renderer = ImageRenderer(content: content)
                renderer.scale = 3
                guard let data = renderer.uiImage?.pngData() else { throw CocoaError(.fileWriteUnknown) }
                return data
            }
        }
        .suggestedFileName { "m-Core trace \($0.outcome.date.formatted(.iso8601.year().month().day())).png" }
    }
}

/// The share card: the hop timeline with SNR per hop, the round trip and the date.
struct TraceShareCard: View {
    let outcome: TraceOutcome
    let radioName: String
    let hopNames: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: MCSpacing.m) {
            HStack {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                    .foregroundStyle(MCColor.accent)
                Text("Trace path").font(.headline)
                Spacer()
                Text(outcome.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 0) {
                timelineRow(title: radioName, detail: "Start", snr: nil, isEnd: false, symbol: "antenna.radiowaves.left.and.right")
                ForEach(Array(outcome.hops.enumerated()), id: \.offset) { index, hop in
                    timelineRow(title: index < hopNames.count ? hopNames[index] : hop.hashHex, detail: "Hop \(index + 1) · \(hop.hashHex)",
                                snr: hop.snr, isEnd: false, symbol: "dot.radiowaves.up.forward")
                }
                timelineRow(title: radioName, detail: "Back to you", snr: outcome.finalSNR, isEnd: true, symbol: "arrow.uturn.backward")
            }
            Divider()
            HStack {
                Label("Round trip \(TraceView.roundTripText(outcome.roundTrip))", systemImage: "timer")
                Spacer()
                Text("\(outcome.hops.count) hop\(outcome.hops.count == 1 ? "" : "s")")
            }
            .font(.subheadline)
            Text("m-Core · MeshCore").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(MCSpacing.l)
        .frame(width: 360)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }

    private func timelineRow(title: String, detail: String, snr: Double?, isEnd: Bool, symbol: String) -> some View {
        HStack(alignment: .top, spacing: MCSpacing.m) {
            VStack(spacing: 0) {
                Image(systemName: symbol)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(MCColor.accent, in: Circle())
                if !isEnd {
                    Rectangle().fill(MCColor.accent.opacity(0.4)).frame(width: 2, height: 18)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let snr {
                SignalBars(snr: snr)
                Text("\(snr.formatted()) dB").font(.caption.monospacedDigit())
            }
        }
    }
}
