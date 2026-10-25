import CoreLocation
import MeshCoreKit
import MeshDesign
import MeshServices
import MeshStore
import SwiftUI

enum NodeSegment: String, CaseIterable {
    case favourites = "Favorites"
    case contacts = "Contacts"
    case repeaters = "Repeaters"
    case rooms = "Rooms"
    case sensors = "Sensors"

    func includes(_ contact: ContactRecord) -> Bool {
        switch self {
        case .favourites: contact.isFavourite
        case .contacts: contact.advertType == .chat
        case .repeaters: contact.advertType == .repeater
        case .rooms: contact.advertType == .room
        case .sensors: contact.advertType == .sensor
        }
    }
}

enum NodeSort: String, CaseIterable {
    case lastHeard = "Last heard"
    case name = "Name"
    case distance = "Distance"
}

struct NodesView: View {
    @Environment(MessagingService.self) private var messaging
    @Environment(ContactsService.self) private var contacts
    @Environment(RadioController.self) private var radio
    @Environment(LocationTracker.self) private var location
    @State private var segment: NodeSegment = .contacts
    @State private var sort: NodeSort = .lastHeard
    @State private var search = ""
    @State private var status: String?
    /// Set when the list is the sidebar of the iPad split view.
    var selection: Binding<String?>?

    var body: some View {
        let nodes = filteredNodes
        AdaptiveList(selection: selection) {
            Section {
                FilterChipBar(options: NodeSegment.allCases, selection: $segment) { $0.rawValue }
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .listRowSeparator(.hidden)
                if let status {
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                }
                if let error = radioError {
                    HStack(alignment: .firstTextBaseline) {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(MCColor.warning)
                        Spacer()
                        Button("Dismiss", systemImage: "xmark") { messaging.clearError() }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                    }
                }
            }
            ForEach(nodes, id: \.keyHex) { node in
                NavigationLink(value: node.keyHex) {
                    NodeRow(contact: node, origin: origin)
                }
                // Drag a node into Messages, Notes or another m-Core window to share its contact link.
                .draggable(MeshLink.contact(name: node.displayName, keyHex: node.keyHex, type: node.typeRaw).url)
                .swipeActions {
                    Button(node.isFavourite ? "Unfavorite" : "Favorite", systemImage: node.isFavourite ? "star.slash" : "star") {
                        Task {
                            do {
                                try await contacts.setFavourite(!node.isFavourite, keyHex: node.keyHex)
                            } catch {
                                status = "Couldn't change the favourite: \(errorMessage(error))"
                            }
                        }
                    }
                    .tint(MCColor.warning)
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $search, prompt: "Search nodes (\(nodes.count))")
        .navigationTitle("Nodes")
        .navigationDestination(for: String.self) { NodeDetailView(keyHex: $0) }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { ConnectionButton() }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    // An inline picker shows no title in a menu, so it gets a section header.
                    Section("Sort by") {
                        Picker("Sort", selection: $sort) {
                            ForEach(NodeSort.allCases, id: \.self) { Text($0.rawValue) }
                        }
                    }
                    Button("Advertise to neighbours", systemImage: "dot.radiowaves.left.and.right") { advertise(flood: false) }
                    Button("Advertise to whole mesh", systemImage: "antenna.radiowaves.left.and.right") { advertise(flood: true) }
                } label: {
                    Label("Options", systemImage: "ellipsis")
                }
            }
        }
        .onAppear { location.start() }
        .onDisappear { location.stop() }
        .overlay {
            if messaging.store == nil {
                ContentUnavailableView(
                    "No radio",
                    systemImage: "antenna.radiowaves.left.and.right.slash",
                    description: Text("Connect a radio to see nodes.")
                )
            } else if nodes.isEmpty {
                ContentUnavailableView(search.isEmpty ? "No \(segment.rawValue.lowercased())" : "No results", systemImage: "person.2.slash")
            }
        }
    }

    /// Contact problems the radio reported (e.g. its contact list is full). Failed sends show on the message instead.
    private var radioError: String? {
        guard let error = messaging.lastError, !error.hasPrefix("Couldn't send") else { return nil }
        return error
    }

    /// Where distances are measured from: the phone, else the radio's position.
    private var origin: Coordinate? {
        if let current = location.current?.coordinate {
            return Coordinate(latitude: current.latitude, longitude: current.longitude)
        }
        guard let selfInfo = radio.selfInfo, selfInfo.latitudeE6 != 0 || selfInfo.longitudeE6 != 0 else { return nil }
        return Coordinate(latitudeE6: selfInfo.latitudeE6, longitudeE6: selfInfo.longitudeE6)
    }

    private var filteredNodes: [ContactRecord] {
        _ = messaging.revision
        let all = messaging.store?.contacts() ?? []
        let matching = all.filter { segment.includes($0) && (search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search)) }
        switch sort {
        case .name:
            return matching.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        case .lastHeard:
            return matching.sorted { $0.lastSeen > $1.lastSeen }
        case .distance:
            guard let origin else { return matching }
            return matching.sorted { ($0.distance(from: origin) ?? .infinity) < ($1.distance(from: origin) ?? .infinity) }
        }
    }

    private func advertise(flood: Bool) {
        Task {
            do {
                try await contacts.sendAdvert(flood: flood)
                status = flood ? "Advert flooded to the mesh." : "Advert sent to neighbours."
            } catch {
                status = "Couldn't advertise: \(errorMessage(error))"
            }
        }
    }
}

extension ContactRecord {
    /// Most recent of last heard and last advert.
    var lastSeen: Date {
        let advert = lastAdvert > 0 ? Date(timeIntervalSince1970: TimeInterval(lastAdvert)) : .distantPast
        return max(lastHeard ?? .distantPast, advert)
    }

    var isStale: Bool { Date().timeIntervalSince(lastSeen) > 86_400 }

    var location: Coordinate? {
        hasLocation ? Coordinate(latitudeE6: Int32(clamping: latitudeE6), longitudeE6: Int32(clamping: longitudeE6)) : nil
    }

    func distance(from origin: Coordinate) -> Double? {
        location.map { origin.distance(to: $0) }
    }
}

struct NodeRow: View {
    let contact: ContactRecord
    let origin: Coordinate?

    var body: some View {
        HStack(spacing: MCSpacing.m) {
            AvatarView(name: contact.displayName, kind: contact.avatarKind)
            VStack(alignment: .leading, spacing: MCSpacing.xxs) {
                HStack(spacing: MCSpacing.xs) {
                    Text(contact.keyHex.prefix(2).uppercased())
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                    Text(contact.displayName).lineLimit(1)
                    if contact.isFavourite {
                        Image(systemName: "star.fill").font(.caption).foregroundStyle(MCColor.warning)
                            .accessibilityLabel("Favourite")
                    }
                    if contact.isBlocked {
                        Image(systemName: "hand.raised.fill").font(.caption).foregroundStyle(MCColor.critical)
                            .accessibilityLabel("Blocked")
                    }
                    Spacer(minLength: MCSpacing.xs)
                    if contact.lastSeen > .distantPast {
                        Text(RelativeAge.text(seconds: Date().timeIntervalSince(contact.lastSeen)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: MCSpacing.s) {
                    Text(contact.hopsText)
                    if let origin, let location = contact.location {
                        Image(systemName: "location.north.fill")
                            .rotationEffect(.degrees(origin.bearing(to: location)))
                            .foregroundStyle(MCColor.positive)
                            .accessibilityLabel(Self.compassName(origin.bearing(to: location)))
                        Text(
                            Measurement(value: origin.distance(to: location), unit: UnitLength.meters)
                                .formatted(.measurement(width: .abbreviated, usage: .road))
                        )
                    }
                    Spacer()
                    if contact.lastSNR != nil { SignalBars(snr: contact.lastSNR) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            // Separators start under the name for every row, not under a contact's initials.
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        }
        .opacity(contact.isStale ? 0.55 : 1)
        .accessibilityElement(children: .combine)
        // The grey-out alone doesn't reach VoiceOver.
        .accessibilityValue(contact.isStale ? "Not heard for over a day" : "")
    }

    /// "north-east" etc. for VoiceOver, from a bearing in degrees.
    static func compassName(_ bearing: Double) -> String {
        let names = ["north", "north-east", "east", "south-east", "south", "south-west", "west", "north-west"]
        let index = Int(((bearing.truncatingRemainder(dividingBy: 360) + 360 + 22.5) / 45).rounded(.down)) % 8
        return names[index]
    }
}
