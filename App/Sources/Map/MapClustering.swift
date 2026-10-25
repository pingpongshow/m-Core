import CoreGraphics
import CoreLocation
import MapLibre
import MeshDesign
import UIKit

/// Groups points that would overlap on screen. Greedy and grid-bucketed, so a few hundred pins cluster in well
/// under a millisecond: each point joins the first cluster whose seed is within `radius`, else seeds its own.
enum PinClusterer {
    /// Indices of `points`, grouped. Input order decides which point seeds a cluster, so pass a stable order.
    static func groups(_ points: [CGPoint], radius: CGFloat) -> [[Int]] {
        guard radius > 0 else { return points.indices.map { [$0] } }
        struct Cell: Hashable {
            let x: Int
            let y: Int
        }
        var seeds: [CGPoint] = []
        var members: [[Int]] = []
        var grid: [Cell: [Int]] = [:]
        let radiusSquared = radius * radius
        for (index, point) in points.enumerated() {
            guard point.x.isFinite, point.y.isFinite else {
                members.append([index])
                seeds.append(point)
                continue
            }
            let cell = Cell(x: Int((point.x / radius).rounded(.down)), y: Int((point.y / radius).rounded(.down)))
            var joined: Int?
            search: for dx in -1...1 {
                for dy in -1...1 {
                    for cluster in grid[Cell(x: cell.x + dx, y: cell.y + dy)] ?? [] {
                        let seed = seeds[cluster]
                        let distanceX = seed.x - point.x
                        let distanceY = seed.y - point.y
                        if distanceX * distanceX + distanceY * distanceY <= radiusSquared {
                            joined = cluster
                            break search
                        }
                    }
                }
            }
            if let joined {
                members[joined].append(index)
            } else {
                grid[cell, default: []].append(seeds.count)
                seeds.append(point)
                members.append([index])
            }
        }
        return members
    }
}

extension MeshMapView.Coordinator {
    /// Works out which pins overlap at the current zoom and swaps them for cluster annotations.
    func layoutPins(on map: MLNMapView) {
        var singles = Set(wantedPins.keys)
        var clusters: [String: (ids: [String], coordinates: [CLLocationCoordinate2D])] = [:]
        // At the deepest zoom nothing can be separated by zooming in, so every pin stays tappable.
        if clustersEnabled, map.bounds.width > 0, map.zoomLevel < map.maximumZoomLevel - 0.5 {
            let candidates = pinOrder.compactMap { wantedPins[$0] }.filter { !$0.isRadio && $0.id != selectedID }
            if candidates.count > 1 {
                let points = candidates.map { map.convert($0.coordinate, toPointTo: map) }
                for group in PinClusterer.groups(points, radius: Self.clusterRadius) where group.count > 1 {
                    let members = group.map { candidates[$0] }
                    members.forEach { singles.remove($0.id) }
                    let key = ClusterAnnotation.key(for: members.map { "\($0.id)@\($0.coordinate.latitude),\($0.coordinate.longitude)" })
                    clusters[key] = (members.map(\.id), members.map(\.coordinate))
                }
            }
        }

        var removed: [any MLNAnnotation] = []
        for (id, annotation) in pinAnnotations where !singles.contains(id) {
            removed.append(annotation)
            pinAnnotations[id] = nil
            pinViews[id] = nil
        }
        for (key, annotation) in clusterAnnotations where clusters[key] == nil {
            removed.append(annotation)
            clusterAnnotations[key] = nil
        }
        if !removed.isEmpty { map.removeAnnotations(removed) }

        var added: [any MLNAnnotation] = []
        for id in singles where pinAnnotations[id] == nil {
            guard let pin = wantedPins[id] else { continue }
            let annotation = PinAnnotation(pin: pin)
            pinAnnotations[id] = annotation
            added.append(annotation)
        }
        for (key, cluster) in clusters where clusterAnnotations[key] == nil {
            let annotation = ClusterAnnotation(key: key, memberIDs: cluster.ids, coordinates: cluster.coordinates)
            clusterAnnotations[key] = annotation
            added.append(annotation)
        }
        if !added.isEmpty { map.addAnnotations(added) }
    }

    /// Zooms so a cluster's pins spread apart.
    func zoom(into cluster: ClusterAnnotation, on map: MLNMapView) {
        let coordinates = cluster.memberCoordinates
        guard let first = coordinates.first else { return }
        var bounds = MLNCoordinateBounds(sw: first, ne: first)
        for coordinate in coordinates {
            bounds.sw.latitude = min(bounds.sw.latitude, coordinate.latitude)
            bounds.sw.longitude = min(bounds.sw.longitude, coordinate.longitude)
            bounds.ne.latitude = max(bounds.ne.latitude, coordinate.latitude)
            bounds.ne.longitude = max(bounds.ne.longitude, coordinate.longitude)
        }
        let padding = UIEdgeInsets(top: 120, left: 60, bottom: 180, right: 100)
        let fitted = map.cameraThatFitsCoordinateBounds(bounds, edgePadding: padding)
        // Pins at (nearly) the same place, or a fit that barely zooms: step in around the bubble instead.
        if fitted.altitude > map.camera.altitude * 0.5 {
            map.setCenter(cluster.coordinate, zoomLevel: min(map.zoomLevel + 2, map.maximumZoomLevel), animated: true)
        } else {
            map.setCamera(fitted, animated: true)
        }
    }
}

/// Several pins drawn as one bubble with a count.
final class ClusterAnnotation: MLNPointAnnotation {
    let key: String
    let memberIDs: [String]
    let memberCoordinates: [CLLocationCoordinate2D]

    init(key: String, memberIDs: [String], coordinates: [CLLocationCoordinate2D]) {
        self.key = key
        self.memberIDs = memberIDs
        self.memberCoordinates = coordinates
        super.init()
        let count = Double(max(coordinates.count, 1))
        coordinate = CLLocationCoordinate2D(
            latitude: coordinates.reduce(0) { $0 + $1.latitude } / count,
            longitude: coordinates.reduce(0) { $0 + $1.longitude } / count
        )
        title = "\(memberIDs.count) nodes"
    }

    required init?(coder: NSCoder) { nil }

    /// Stable identity for a set of members, so an unchanged cluster keeps its annotation.
    static func key(for ids: [String]) -> String {
        ids.sorted().joined(separator: ",")
    }
}

/// Round accent-coloured bubble showing how many pins it stands for.
final class ClusterAnnotationView: MLNAnnotationView {
    private let label = UILabel()

    init(annotation: ClusterAnnotation) {
        super.init(annotation: annotation, reuseIdentifier: nil)
        let count = annotation.memberIDs.count
        let side: CGFloat = count < 10 ? 34 : (count < 100 ? 40 : 46)
        frame = CGRect(x: 0, y: 0, width: side, height: side)
        backgroundColor = UIColor(MCColor.accentFill)
        layer.cornerRadius = side / 2
        layer.borderColor = UIColor.white.cgColor
        layer.borderWidth = 2.5
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 2
        layer.shadowOffset = CGSize(width: 0, height: 1)
        layer.zPosition = 1.5
        label.text = count > 999 ? "999+" : "\(count)"
        label.font = .systemFont(ofSize: count < 100 ? 14 : 12, weight: .bold)
        label.textColor = .white
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.frame = bounds.insetBy(dx: 3, dy: 3)
        addSubview(label)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "\(count) nodes"
        accessibilityHint = "Zooms in to show them"
    }

    override init(annotation: (any MLNAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
    }

    required init?(coder: NSCoder) { nil }
}
