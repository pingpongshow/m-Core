import CryptoKit
import MeshCoreKit
import MeshDesign
import SwiftUI

/// Node types the map can show.
enum MapNodeFilter: String, CaseIterable, Identifiable {
    case contacts, repeaters, rooms, sensors

    var id: String { rawValue }

    var title: String {
        switch self {
        case .contacts: "Contacts"
        case .repeaters: "Repeaters"
        case .rooms: "Rooms"
        case .sensors: "Sensors"
        }
    }

    var advertTypes: [AdvertType] {
        switch self {
        case .contacts: [.chat]
        case .repeaters: [.repeater]
        case .rooms: [.room]
        case .sensors: [.sensor]
        }
    }

    func matches(_ kind: AvatarKind) -> Bool {
        switch self {
        case .contacts: kind == .contact
        case .repeaters: kind == .repeater
        case .rooms: kind == .room
        case .sensors: kind == .sensor
        }
    }
}

/// How recently a node must have been heard to be shown.
enum MapHeardFilter: Int, CaseIterable, Identifiable {
    case any = 0
    case day = 86_400
    case week = 604_800

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .any: "Any time"
        case .day: "Last 24 hours"
        case .week: "Last 7 days"
        }
    }
}

/// How many repeater hops away a contact may be, judged by its stored out path.
enum MapHopFilter: Int, CaseIterable, Identifiable {
    case any = -1
    case direct = 0
    case one = 1
    case two = 2
    case three = 3

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .any: "Any"
        case .direct: "Direct"
        case .one: "Up to 1 hop"
        case .two: "Up to 2 hops"
        case .three: "Up to 3 hops"
        }
    }

    /// Flood or unknown paths (nil) only pass under ``any``.
    func matches(_ hashes: [String]?) -> Bool {
        guard self != .any else { return true }
        guard let hashes else { return false }
        return hashes.count <= rawValue
    }
}

/// Builds and caches the style file for the current offline areas and colour scheme.
@MainActor
@Observable
final class MapStyleProvider {
    private(set) var styleURL: URL?
    @ObservationIgnored private var key: String?

    func update(areas: [String], dark: Bool) {
        let sources = [MapStyle.overviewSource].compactMap { $0 } + areas
        let key = (sources + [dark ? "dark" : "light"]).joined(separator: "|")
        guard key != self.key else { return }
        self.key = key
        let style = MapStyle(sources: sources, palette: dark ? .dark : .light, glyphsDirectory: MapStyle.bundledGlyphs)
        // A file name per variant makes MapLibre reload the style; it's stable across launches so files don't pile up.
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        styleURL = try? style.write(named: "mcore-style-\(digest)")
    }
}

/// The map's filter menu: node types, last heard, hops and optional layers.
struct MapFilterMenu: View {
    @Binding var visibleTypes: Set<MapNodeFilter>
    @Binding var heard: MapHeardFilter
    @Binding var hops: MapHopFilter
    @Binding var showInternetNodes: Bool
    @Binding var showCoverage: Bool

    var body: some View {
        Menu {
            Section("Show") {
                ForEach(MapNodeFilter.allCases) { filter in
                    Toggle(filter.title, isOn: Binding(
                        get: { visibleTypes.contains(filter) },
                        set: { if $0 { visibleTypes.insert(filter) } else { visibleTypes.remove(filter) } }
                    ))
                }
            }
            // Inline pickers in a menu show no title of their own, so each gets a section header.
            Section("Last heard") {
                Picker("Heard", selection: $heard) {
                    ForEach(MapHeardFilter.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("Hops") {
                Picker("Hops", selection: $hops) {
                    ForEach(MapHopFilter.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("Layers") {
                Toggle("Internet Map nodes", systemImage: "globe", isOn: $showInternetNodes)
                Toggle("Coverage walk", systemImage: "dot.radiowaves.left.and.right", isOn: $showCoverage)
            }
        } label: {
            Image(systemName: visibleTypes.count < MapNodeFilter.allCases.count || heard != .any || hops != .any
                  ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .font(.title3.weight(.medium))
                .frame(width: MCSize.control, height: MCSize.control)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .mcFloatingSurface(in: Circle())
        .accessibilityLabel("Filter nodes")
    }
}
