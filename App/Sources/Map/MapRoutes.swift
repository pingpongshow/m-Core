import CoreLocation
import MeshDesign
import MeshStore
import SwiftUI

/// A node that might be one of a route's hops.
struct RouteCandidate {
    var keyHex: String
    var coordinate: CLLocationCoordinate2D
    var isRepeater: Bool
    var lastSeen: Date
}

/// A route matched against known node positions.
struct ResolvedRoute {
    /// Start, each hop with a known position, then the far end, in travel order.
    var coordinates: [CLLocationCoordinate2D]
    var hopCount: Int
    /// Hop hashes no node with a position matches; they are skipped in the line.
    var unplacedHops: [String]
    /// The far end was named but has no position.
    var endpointUnplaced: Bool

    /// e.g. "3 hops · 2 hops without a position".
    var summary: String {
        var parts = [hopCount == 0 ? "Direct" : "\(hopCount) hop\(hopCount == 1 ? "" : "s")"]
        if !unplacedHops.isEmpty {
            parts.append("\(unplacedHops.count) hop\(unplacedHops.count == 1 ? "" : "s") without a position")
        }
        if endpointUnplaced { parts.append("destination has no position") }
        return parts.joined(separator: " · ")
    }
}

/// Matches hop hash prefixes to nodes with positions.
enum MapRouteResolver {
    /// - Parameters:
    ///   - hops: Hash prefixes in travel order (hex, any case).
    ///   - start: Where the route begins (our radio, else the phone), if known.
    ///   - end: The far end's position, if known.
    ///   - endpointNamed: Whether a far end was named at all (so a missing position is reported).
    ///   - candidates: Nodes with positions. Short hashes can match several: repeaters win, then the one nearest
    ///     the previous point, then the most recently heard.
    static func resolve(
        hops: [String], start: CLLocationCoordinate2D?, end: CLLocationCoordinate2D?, endpointNamed: Bool,
        candidates: [RouteCandidate]
    ) -> ResolvedRoute {
        var coordinates = start.map { [$0] } ?? []
        var unplaced: [String] = []
        var previous = start
        for hash in hops {
            let prefix = hash.lowercased()
            let matches = candidates.filter { !prefix.isEmpty && $0.keyHex.lowercased().hasPrefix(prefix) }
            let repeaters = matches.filter(\.isRepeater)
            let pool = repeaters.isEmpty ? matches : repeaters
            guard let chosen = best(in: pool, near: previous) else {
                unplaced.append(hash)
                continue
            }
            coordinates.append(chosen.coordinate)
            previous = chosen.coordinate
        }
        if let end { coordinates.append(end) }
        return ResolvedRoute(
            coordinates: coordinates, hopCount: hops.count, unplacedHops: unplaced, endpointUnplaced: endpointNamed && end == nil
        )
    }

    /// A route request, ending at `endpoint` when that contact is known.
    static func resolve(
        _ route: MapRouteRequest, start: CLLocationCoordinate2D?, endpoint: ContactRecord?, candidates: [RouteCandidate]
    ) -> ResolvedRoute {
        resolve(hops: route.hopHashes, start: start, end: endpoint?.coordinate, endpointNamed: route.endpointKeyHex != nil,
                candidates: candidates)
    }

    /// A contact's stored out path, from `start` to the contact; nil while its path is unknown (flood).
    static func path(to contact: ContactRecord, start: CLLocationCoordinate2D?, candidates: [RouteCandidate]) -> ResolvedRoute? {
        guard let hashes = contact.outPathHashes else { return nil }
        return resolve(hops: hashes, start: start, end: contact.coordinate, endpointNamed: true, candidates: candidates)
    }

    private static func best(in pool: [RouteCandidate], near point: CLLocationCoordinate2D?) -> RouteCandidate? {
        guard let point else { return pool.max { $0.lastSeen < $1.lastSeen } }
        let origin = CLLocation(latitude: point.latitude, longitude: point.longitude)
        return pool.min {
            origin.distance(from: CLLocation(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude))
                < origin.distance(from: CLLocation(latitude: $1.coordinate.latitude, longitude: $1.coordinate.longitude))
        }
    }

    /// Every contact with a position, as route candidates.
    static func candidates(from contacts: [ContactRecord]) -> [RouteCandidate] {
        contacts.compactMap { contact in
            guard let coordinate = contact.coordinate else { return nil }
            let kind = contact.avatarKind
            return RouteCandidate(keyHex: contact.keyHex, coordinate: coordinate, isRepeater: kind == .repeater, lastSeen: contact.lastSeen)
        }
    }
}

/// Floating banner naming the route drawn on the map, with a close button.
struct MapRouteBanner: View {
    let title: String
    let detail: String
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: MCSpacing.m) {
            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                .foregroundStyle(Color(uiColor: MapRouteBanner.lineColor))
            VStack(alignment: .leading, spacing: MCSpacing.xxs) {
                Text(title).font(.footnote.weight(.semibold)).lineLimit(1)
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            Button("Close route", systemImage: "xmark.circle.fill", action: onClose)
                .labelStyle(.iconOnly)
                .font(.title3)
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, MCSpacing.m)
        .padding(.vertical, MCSpacing.s)
        .mcFloatingSurface(in: RoundedRectangle(cornerRadius: MCRadius.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    /// Colour of route lines and the selected contact's path.
    static let lineColor = UIColor.systemPurple
}
