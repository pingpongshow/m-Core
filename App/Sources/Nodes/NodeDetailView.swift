import Charts
import CoreLocation
import MeshCoreKit
import MeshDesign
import MeshServices
import MeshStore
import SwiftUI

struct NodeDetailView: View {
    let keyHex: String
    @Environment(MessagingService.self) private var messaging
    @Environment(ContactsService.self) private var contacts
    @Environment(TelemetryService.self) private var telemetry
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var status: String?
    @State private var isWorking = false
    @State private var showingShare = false
    @State private var showingLogin = false
    @State private var showingRename = false
    @State private var showingRemove = false
    @State private var nickname = ""

    private var contact: ContactRecord? {
        _ = messaging.revision
        return messaging.store?.contact(keyHex: keyHex)
    }

    var body: some View {
        if let contact {
            List {
                header(contact)
                actions(contact)
                if let status {
                    Section { Text(status).font(.footnote).foregroundStyle(.secondary) }
                }
                telemetrySection(contact)
                info(contact)
                settings(contact)
                if let coordinate = contact.coordinate {
                    Section("Location") {
                        LocationPreview(latitude: coordinate.latitude, longitude: coordinate.longitude)
                            .frame(maxWidth: .infinity)
                            .listRowInsets(EdgeInsets())
                        Button("Show on map", systemImage: "map") { router.showOnMap(keyHex) }
                        Button("Navigate in Apple Maps", systemImage: "arrow.triangle.turn.up.right.diamond") {
                            AppleMaps.open(latitude: coordinate.latitude, longitude: coordinate.longitude, label: contact.displayName)
                        }
                        let history = messaging.store?.positions(keyHex: keyHex).count ?? 0
                        if history > 1 { LabeledContent("Positions recorded", value: "\(history)") }
                    }
                }
                Section {
                    Button("Remove from radio", systemImage: "trash", role: .destructive) { showingRemove = true }
                        .foregroundStyle(MCColor.critical)
                        .confirmationDialog("Remove \(contact.displayName)?", isPresented: $showingRemove, titleVisibility: .visible) {
                            Button("Remove", role: .destructive) {
                                run("Removed.") {
                                    try await contacts.remove(keyHex: keyHex)
                                    dismiss()
                                }
                            }
                        } message: {
                            Text("The radio forgets this contact until it hears another advert. Message history stays on this device.")
                        }
                }
            }
            .navigationTitle(contact.displayName)
            .toolbarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingShare) {
                ShareCodeSheet(
                    title: contact.displayName,
                    url: MeshLink.contact(name: contact.name, keyHex: contact.keyHex, type: contact.typeRaw).url,
                    note: "Scan with m-Core or another MeshCore app to add this contact."
                )
            }
            .sheet(isPresented: $showingLogin) {
                RemoteLoginSheet(keyHex: keyHex, title: contact.displayName)
            }
            .alert("Nickname", isPresented: $showingRename) {
                TextField(contact.name, text: $nickname)
                Button("Save") { contacts.setNickname(nickname, keyHex: keyHex) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Only shown on this device.")
            }
        } else {
            ContentUnavailableView("Contact not found", systemImage: "person.crop.circle.badge.questionmark")
        }
    }

    // MARK: Sections

    private func header(_ contact: ContactRecord) -> some View {
        Section {
            VStack(spacing: MCSpacing.s) {
                AvatarView(name: contact.displayName, kind: contact.avatarKind, size: MCSize.avatarDetail)
                Text(contact.displayName).font(.title2.weight(.semibold))
                Text(contact.advertType.label).foregroundStyle(.secondary)
                if contact.hasLocation {
                    // Not a Label: in a list row, a label's icon gets a fixed-width column, leaving a gap when centred.
                    HStack(spacing: MCSpacing.xs) {
                        Image(systemName: "location.fill")
                        Text("Has location")
                    }
                    .font(.caption)
                    .foregroundStyle(MCColor.positive)
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .listRowBackground(Color.clear)
        }
    }

    private func actions(_ contact: ContactRecord) -> some View {
        Section {
            if [.chat, .room].contains(contact.advertType) {
                Button("Send message", systemImage: "bubble.left.fill") {
                    router.openConversation(ConversationID.direct(keyHex: keyHex).description)
                }
            }
            if [.repeater, .room].contains(contact.advertType) {
                Button("Log in", systemImage: "person.badge.key") { showingLogin = true }
            }
            // Room servers answer the same status, settings and command-line requests as repeaters.
            if [.repeater, .room].contains(contact.advertType) {
                NavigationLink {
                    RepeaterAdminView(keyHex: keyHex)
                } label: {
                    Label(contact.advertType == .room ? "Manage room" : "Manage repeater", systemImage: "slider.horizontal.3")
                }
            }
            Button("Request telemetry", systemImage: "chart.xyaxis.line") {
                run("Telemetry received.") { try await telemetry.request(from: keyHex) }
            }
            if let route = traceRoute(to: contact) {
                Button("Trace path", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
                    router.trace(through: route)
                }
            }
            Button("Ping (find path)", systemImage: "dot.radiowaves.up.forward") {
                runWithResult {
                    let (result, roundTrip) = try await contacts.discoverPath(keyHex: keyHex)
                    let hops = result.outPath?.hashes.count ?? 0
                    let time = roundTrip.formatted(.units(allowed: [.seconds, .milliseconds], width: .abbreviated))
                    return "Reached in \(time), \(hops) hop\(hops == 1 ? "" : "s")."
                }
            }
            Button(
                contact.isFavourite ? "Remove from favorites" : "Add to favorites",
                systemImage: contact.isFavourite ? "star.slash" : "star"
            ) {
                run(nil) { try await contacts.setFavourite(!contact.isFavourite, keyHex: keyHex) }
            }
            Button("Share contact", systemImage: "qrcode") { showingShare = true }
            Button("Share via advert", systemImage: "dot.radiowaves.left.and.right") {
                run("Advert sent.") { try await contacts.shareViaAdvert(keyHex: keyHex) }
            }
        }
        .disabled(isWorking)
    }

    private func telemetrySection(_ contact: ContactRecord) -> some View {
        let readings = telemetry.latest[keyHex] ?? []
        // Only whether any history exists; the chart screen loads it.
        let hasHistory = !(messaging.store?.telemetry(keyHex: keyHex, limit: 1) ?? []).isEmpty
        return Group {
            if !readings.isEmpty || hasHistory {
                Section("Telemetry") {
                    ForEach(readings.filter { $0.kind != .gps }, id: \.self) { reading in
                        LabeledContent(reading.kind.title, value: reading.formattedValue)
                    }
                    if hasHistory {
                        NavigationLink("Telemetry history") { TelemetryHistoryView(keyHex: keyHex, title: contact.displayName) }
                    }
                }
            }
        }
    }

    private func info(_ contact: ContactRecord) -> some View {
        Section("Info") {
            LabeledContent("Nickname") {
                Button(contact.nickname ?? "None") {
                    nickname = contact.nickname ?? ""
                    showingRename = true
                }
            }
            LabeledContent("Name", value: contact.name)
            LabeledContent("Public key") {
                Text(contact.keyHex.prefix(12).uppercased()).font(.body.monospaced())
            }
            .contextMenu {
                Button("Copy full key", systemImage: "doc.on.doc") { UIPasteboard.general.string = contact.keyHex }
            }
            if contact.lastAdvert > 0 {
                LabeledContent(
                    "Last advert",
                    value: Date(timeIntervalSince1970: TimeInterval(contact.lastAdvert)).formatted(date: .abbreviated, time: .shortened)
                )
            }
            if let lastHeard = contact.lastHeard {
                LabeledContent("Last heard", value: lastHeard.formatted(date: .abbreviated, time: .shortened))
            }
            if let snr = contact.lastSNR {
                LabeledContent("Signal") {
                    HStack { SignalBars(snr: snr); Text(String(format: "%.1f dB", snr)) }
                }
            }
            LabeledContent("Path") {
                if let hashes = contact.outPathHashes, !hashes.isEmpty {
                    PathChip(.direct(hops: hashes))
                } else {
                    PathChip(contact.outPathHashes == nil ? .flood : .direct(hops: []))
                }
            }
            if contact.outPathHashes != nil {
                Button("Reset path", systemImage: "arrow.triangle.branch") {
                    run("Path reset; the next message will flood.") { try await contacts.resetPath(keyHex: keyHex) }
                }
            }
        }
    }

    private func settings(_ contact: ContactRecord) -> some View {
        Section {
            Toggle("Alert when heard", isOn: Binding(
                get: { contact.alertWhenHeard },
                set: { contacts.setAlertWhenHeard($0, keyHex: keyHex) }
            ))
            Toggle("Block", isOn: Binding(
                get: { contact.isBlocked },
                set: { contacts.setBlocked($0, keyHex: keyHex) }
            ))
        } footer: {
            Text("Blocked contacts' messages are dropped on this device.")
        }
    }

    // MARK: Helpers

    /// Repeaters to trace through to reach this node: its known path, plus the node itself when it's a repeater or
    /// room (which echo traces). Nil when a hop isn't a known repeater or there's nothing to trace.
    private func traceRoute(to contact: ContactRecord) -> [String]? {
        let repeaters = (messaging.store?.contacts() ?? []).filter { $0.advertType == .repeater }
        var keys: [String] = []
        for hash in contact.outPathHashes ?? [] {
            guard let hop = repeaters.first(where: { $0.keyHex.hasPrefix(hash.lowercased()) }) else { return nil }
            keys.append(hop.keyHex)
        }
        if contact.advertType == .repeater || contact.advertType == .room { keys.append(contact.keyHex) }
        return keys.isEmpty ? nil : keys
    }

    private func run(_ success: String?, _ work: @escaping () async throws -> Void) {
        runWithResult {
            try await work()
            return success
        }
    }

    private func runWithResult(_ work: @escaping () async throws -> String?) {
        isWorking = true
        status = "Working…"
        Task {
            defer { isWorking = false }
            do {
                status = try await work()
            } catch RemoteRequestError.timedOut {
                status = "No answer. The node may be out of range."
            } catch {
                status = "Failed: \(errorMessage(error))"
            }
        }
    }
}

extension LPPKind {
    var title: String {
        switch self {
        case .voltage: "Battery"
        case .temperature: "Temperature"
        case .humidity: "Humidity"
        case .barometer: "Pressure"
        case .altitude: "Altitude"
        case .illuminance: "Light"
        case .current: "Current"
        case .power: "Power"
        case .percentage: "Level"
        default: name.prefix(1).uppercased() + name.dropFirst()
        }
    }
}

extension LPPReading {
    var formattedValue: String {
        let number = values.count == 1 ? value.formatted(.number.precision(.fractionLength(0...2))) :
            values.map { $0.formatted(.number.precision(.fractionLength(0...4))) }.joined(separator: ", ")
        return kind.unit.isEmpty ? number : "\(number) \(kind.unit)"
    }
}

/// Charts of recorded telemetry, one per kind.
struct TelemetryHistoryView: View {
    let keyHex: String
    let title: String
    @Environment(MessagingService.self) private var messaging

    var body: some View {
        let samples = messaging.store?.telemetry(keyHex: keyHex) ?? []
        let kinds = Array(Set(samples.map(\.kind))).sorted()
        List {
            ForEach(kinds, id: \.self) { kind in
                let points = samples.filter { $0.kind == kind }
                let lppKind = LPPKind.allCases.first { $0.name == kind }
                Section(lppKind?.title ?? kind) {
                    Chart(points, id: \.recordedAt) { sample in
                        LineMark(x: .value("Time", sample.recordedAt), y: .value(kind, sample.value))
                            .interpolationMethod(.monotone)
                        PointMark(x: .value("Time", sample.recordedAt), y: .value(kind, sample.value))
                            .symbolSize(20)
                    }
                    .chartYScale(domain: ChartScale.paddedDomain(points.map(\.value)))
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 4)) {
                            AxisGridLine()
                            AxisValueLabel(format: .dateTime.hour().minute())
                        }
                    }
                    .frame(height: 180)
                    .accessibilityLabel("\(lppKind?.title ?? kind) history, \(points.count) readings")
                    // The store returns newest first.
                    if let last = points.max(by: { $0.recordedAt < $1.recordedAt }) {
                        LabeledContent(
                            "Latest",
                            value: "\(last.value.formatted(.number.precision(.fractionLength(0...2)))) \(lppKind?.unit ?? "")"
                        )
                    }
                }
            }
        }
        .navigationTitle("\(title) telemetry")
        .overlay {
            if samples.isEmpty { ContentUnavailableView("No telemetry yet", systemImage: "chart.xyaxis.line") }
        }
    }
}
