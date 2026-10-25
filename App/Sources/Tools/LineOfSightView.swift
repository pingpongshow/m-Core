import Charts
import CoreLocation
import MeshDesign
import MeshServices
import MeshStore
import MeshTools
import SwiftUI

/// Terrain profile between two points (optionally through a relay), with earth bulge and the Fresnel zone.
struct LineOfSightView: View {
    enum Site: Hashable {
        case myLocation
        case node(String)
    }

    @Environment(MessagingService.self) private var messaging
    @Environment(RadioController.self) private var radio
    @Environment(LocationTracker.self) private var location
    @State private var from: Site = .myLocation
    @State private var to: Site?
    @State private var relay: Site?
    @State private var fromHeight = 2.0
    @State private var toHeight = 10.0
    @State private var relayHeight = 10.0
    @State private var analysis: LinkAnalysis?
    @State private var isRunning = false
    @State private var error: String?

    var body: some View {
        let nodes = (messaging.store?.contacts() ?? []).filter(\.hasLocation)
        Form {
            Section {
                sitePicker(
                    "From",
                    selection: Binding(get: { Optional(from) }, set: { from = $0 ?? .myLocation }),
                    nodes: nodes,
                    allowNone: false
                )
                heightStepper("Antenna height", value: $fromHeight)
            }
            Section {
                sitePicker("To", selection: $to, nodes: nodes, allowNone: false)
                heightStepper("Antenna height", value: $toHeight)
            }
            Section {
                sitePicker("Via relay", selection: $relay, nodes: nodes, allowNone: true)
                if relay != nil { heightStepper("Relay height", value: $relayHeight) }
            } footer: {
                Text("""
                    Heights are above the ground. Terrain comes from Open-Meteo's elevation service, so this needs an \
                    internet connection.
                    """)
            }
            Section {
                Button(isRunning ? "Checking…" : "Check line of sight", systemImage: "mountain.2") { run(nodes: nodes) }
                    .disabled(isRunning || to == nil)
                if let error { Text(error).font(.footnote).foregroundStyle(MCColor.critical) }
            }
            if let analysis {
                ForEach(Array(analysis.segments.enumerated()), id: \.offset) { index, segment in
                    Section(analysis.segments.count > 1 ? "Leg \(index + 1)" : "Result") {
                        SegmentSummary(segment: segment)
                        ProfileChart(segment: segment).frame(height: 200)
                    }
                }
            }
        }
        .navigationTitle("Line of Sight")
        .onAppear { location.start() }
        .onDisappear { location.stop() }
    }

    private func sitePicker(_ title: String, selection: Binding<Site?>, nodes: [ContactRecord], allowNone: Bool) -> some View {
        Picker(title, selection: selection) {
            if allowNone { Text("None").tag(Site?.none) }
            if !allowNone && selection.wrappedValue == nil { Text("Choose").tag(Site?.none) }
            Text("My location").tag(Optional(Site.myLocation))
            ForEach(nodes, id: \.keyHex) { node in
                Text(node.displayName).tag(Optional(Site.node(node.keyHex)))
            }
        }
    }

    private func heightStepper(_ title: String, value: Binding<Double>) -> some View {
        Stepper(value: value, in: 0...300, step: 1) {
            LabeledContent(title, value: "\(Int(value.wrappedValue)) m")
        }
    }

    private func coordinate(of site: Site, nodes: [ContactRecord]) -> GeoCoordinate? {
        switch site {
        case .myLocation:
            return location.current.map { GeoCoordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) }
        case .node(let keyHex):
            return nodes.first { $0.keyHex == keyHex }?.coordinate.map { GeoCoordinate(latitude: $0.latitude, longitude: $0.longitude) }
        }
    }

    private func run(nodes: [ContactRecord]) {
        guard let to else { return }
        guard let start = coordinate(of: from, nodes: nodes), let end = coordinate(of: to, nodes: nodes) else {
            error = from == .myLocation || to == .myLocation ? "Your location isn't known yet." : "That node has no position."
            return
        }
        let relaySite = relay.flatMap { coordinate(of: $0, nodes: nodes) }.map { LinkSite(coordinate: $0, antennaHeight: relayHeight) }
        let frequency = radio.selfInfo.map { Double($0.radio.frequencyKHz) / 1000 } ?? 910
        isRunning = true
        error = nil
        Task {
            defer { isRunning = false }
            do {
                analysis = try await LinkPlanner(elevation: OpenMeteoElevationProvider()).analyze(
                    from: LinkSite(coordinate: start, antennaHeight: fromHeight),
                    via: relaySite,
                    to: LinkSite(coordinate: end, antennaHeight: toHeight),
                    parameters: LineOfSightParameters(frequencyMHz: frequency)
                )
            } catch {
                self.error = "Couldn't get terrain data. Check your connection and try again."
            }
        }
    }
}

private struct SegmentSummary: View {
    let segment: LineOfSightSegment

    var body: some View {
        LabeledContent {
            Text(verdict).foregroundStyle(color).fontWeight(.semibold)
        } label: {
            Label("Path", systemImage: segment.isClear ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(color)
        }
        // In km like the profile chart below it (and metres like the heights), not the locale's road unit.
        LabeledContent("Distance", value: Measurement(value: segment.distance / 1000, unit: UnitLength.kilometers)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0...1)))))
        if let clearance = segment.minimumClearancePercent {
            LabeledContent("Worst Fresnel clearance", value: "\(Int(clearance.rounded()))%")
        }
        LabeledContent("Fresnel zone radius", value: "\(Int(segment.maxFresnelRadius.rounded())) m at midpoint")
    }

    private var verdict: String {
        if segment.isObstructed { return "Blocked by terrain" }
        return segment.isClear ? "Clear" : "Marginal"
    }

    private var color: Color {
        if segment.isObstructed { return MCColor.critical }
        return segment.isClear ? MCColor.positive : MCColor.warning
    }
}

private struct ProfileChart: View {
    let segment: LineOfSightSegment

    var body: some View {
        Chart {
            ForEach(Array(segment.profile.enumerated()), id: \.offset) { _, point in
                AreaMark(x: .value("Distance", point.distance / 1000), y: .value("Terrain", point.adjustedTerrain))
                    .foregroundStyle(.brown.opacity(0.35))
                LineMark(x: .value("Distance", point.distance / 1000), y: .value("Height", point.lineOfSight),
                         series: .value("Line", "Line of sight"))
                    .foregroundStyle(MCColor.accent)
                LineMark(x: .value("Distance", point.distance / 1000), y: .value("Height", point.fresnelLower),
                         series: .value("Line", "Fresnel zone"))
                    .foregroundStyle(MCColor.warning)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .chartXAxisLabel("km")
        .chartYAxisLabel("m")
        .chartYScale(domain: .automatic(includesZero: false))
        .chartForegroundStyleScale(["Line of sight": MCColor.accent, "Fresnel zone": MCColor.warning])
    }
}
