import CoreLocation
import MapLibre
import MeshDesign
import MeshMaps
import SwiftUI
import UIKit

/// A marker on the map: a node, or the position the connected radio reports.
struct MapPin: Identifiable, Equatable {
    var id: String
    var coordinate: CLLocationCoordinate2D
    var title: String
    var kind: AvatarKind
    var isStale = false
    /// The radio's own reported position, drawn as a distinct marker.
    var isRadio = false
    /// A node from the Internet Map that isn't a contact yet.
    var isInternet = false

    static func == (lhs: MapPin, rhs: MapPin) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.kind == rhs.kind && lhs.isStale == rhs.isStale
            && lhs.isRadio == rhs.isRadio && lhs.isInternet == rhs.isInternet
            && lhs.coordinate.latitude == rhs.coordinate.latitude && lhs.coordinate.longitude == rhs.coordinate.longitude
    }
}

/// A line drawn over the map: a contact's trail, or the phone-to-radio offset.
struct MapLine: Identifiable, Equatable {
    var id: String
    var coordinates: [CLLocationCoordinate2D]
    var color: UIColor
    var width: Double = 3

    static func == (lhs: MapLine, rhs: MapLine) -> Bool {
        lhs.id == rhs.id && lhs.color == rhs.color && lhs.width == rhs.width
            && lhs.coordinates.map(\.latitude) == rhs.coordinates.map(\.latitude)
            && lhs.coordinates.map(\.longitude) == rhs.coordinates.map(\.longitude)
    }
}

/// A small coloured dot, e.g. one coverage-walk sample.
struct MapDot: Identifiable, Equatable {
    var id: String
    var coordinate: CLLocationCoordinate2D
    var color: UIColor

    static func == (lhs: MapDot, rhs: MapDot) -> Bool {
        lhs.id == rhs.id && lhs.color == rhs.color
            && lhs.coordinate.latitude == rhs.coordinate.latitude && lhs.coordinate.longitude == rhs.coordinate.longitude
    }
}

/// A one-off request to move the camera. A new `id` triggers the move.
struct MapCameraRequest: Equatable {
    enum Target {
        case center(CLLocationCoordinate2D, zoom: Double)
        case fit([CLLocationCoordinate2D])
        case resetNorth
    }

    let id = UUID()
    var target: Target

    static func == (lhs: MapCameraRequest, rhs: MapCameraRequest) -> Bool { lhs.id == rhs.id }
}

/// MapLibre map showing the offline basemap, node pins and lines.
struct MeshMapView: UIViewRepresentable {
    var styleURL: URL?
    var pins: [MapPin] = []
    var lines: [MapLine] = []
    var dots: [MapDot] = []
    var selectedID: String?
    var showsUserLocation = true
    /// Groups pins that overlap at the current zoom into count bubbles (the selected and radio pins never are).
    var clustersPins = false
    /// Shows MapLibre's scale bar.
    var showsScale = false
    var camera: MapCameraRequest?
    var onSelect: (String?) -> Void = { _ in }
    var onRegionChange: (GeoBounds, Double) -> Void = { _, _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MLNMapView {
        // A nil style URL makes MapLibre fetch its online demo style, so until the real style is ready show a blank one.
        let map = styleURL.map { MLNMapView(frame: .zero, styleURL: $0) }
            ?? MLNMapView(frame: .zero, styleJSON: MapStyle.placeholderJSON)
        map.delegate = context.coordinator
        map.logoView.isHidden = true
        map.attributionButton.isHidden = true
        map.compassView.compassVisibility = .adaptive
        map.maximumZoomLevel = 18
        map.showsScale = showsScale
        map.scaleBarPosition = .bottomRight
        // Sits above the attribution line drawn at the bottom of the map screen.
        map.scaleBarMargins = CGPoint(x: 16, y: 40)
        map.setCenter(CLLocationCoordinate2D(latitude: 30, longitude: 0), zoomLevel: 1, animated: false)
        context.coordinator.styleURL = styleURL
        return map
    }

    func updateUIView(_ map: MLNMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if coordinator.styleURL != styleURL, let styleURL {
            coordinator.styleURL = styleURL
            map.styleURL = styleURL
        }
        if map.showsUserLocation != showsUserLocation { map.showsUserLocation = showsUserLocation }
        if map.showsScale != showsScale { map.showsScale = showsScale }
        coordinator.sync(pins: pins, selectedID: selectedID, clusters: clustersPins, on: map)
        coordinator.sync(lines: lines, on: map)
        coordinator.sync(dots: dots, on: map)
        if let camera, camera != coordinator.lastCamera {
            coordinator.lastCamera = camera
            coordinator.apply(camera, to: map)
        }
    }
}

extension MeshMapView {
    @MainActor
    final class Coordinator: NSObject, @MainActor MLNMapViewDelegate {
        var parent: MeshMapView?
        var styleURL: URL?
        var lastCamera: MapCameraRequest?
        /// Pins currently drawn on their own (not inside a cluster).
        var pinAnnotations: [String: PinAnnotation] = [:]
        var clusterAnnotations: [String: ClusterAnnotation] = [:]
        private var lineAnnotations: [String: LineAnnotation] = [:]
        private var dotAnnotations: [String: DotAnnotation] = [:]
        var pinViews: [String: PinAnnotationView] = [:]
        /// Every pin the map should show, drawn alone or as part of a cluster.
        var wantedPins: [String: MapPin] = [:]
        /// Pin IDs in a stable order, so the same pins seed the same clusters between layouts.
        var pinOrder: [String] = []
        var clustersEnabled = false
        var selectedID: String?
        private var pendingCamera: MapCameraRequest?

        /// Pins whose centres are closer than this on screen are clustered.
        static let clusterRadius: CGFloat = 44

        func sync(pins: [MapPin], selectedID: String?, clusters: Bool, on map: MLNMapView) {
            let wanted = Dictionary(pins.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let pinsChanged = wanted != wantedPins || clusters != clustersEnabled
            for (id, pin) in wanted {
                guard let existing = pinAnnotations[id], existing.pin != pin else { continue }
                existing.pin = pin
                existing.coordinate = pin.coordinate
                existing.title = pin.title
                pinViews[id]?.configure(pin: pin, selected: id == selectedID)
            }
            let selectionChanged = selectedID != self.selectedID
            if selectionChanged {
                let previous = self.selectedID
                self.selectedID = selectedID
                for id in [previous, selectedID].compactMap({ $0 }) {
                    if let pin = wanted[id] { pinViews[id]?.configure(pin: pin, selected: id == selectedID) }
                }
            }
            guard pinsChanged || (selectionChanged && clusters) else { return }
            if pinsChanged {
                wantedPins = wanted
                pinOrder = wanted.keys.sorted()
                clustersEnabled = clusters
            }
            layoutPins(on: map)
        }

        func sync(lines: [MapLine], on map: MLNMapView) {
            let wanted = Dictionary(lines.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for (id, annotation) in lineAnnotations where wanted[id] != annotation.line {
                map.removeAnnotation(annotation)
                lineAnnotations[id] = nil
            }
            for line in lines where lineAnnotations[line.id] == nil && line.coordinates.count > 1 {
                var coordinates = line.coordinates
                let annotation = LineAnnotation(coordinates: &coordinates, count: UInt(coordinates.count))
                annotation.line = line
                lineAnnotations[line.id] = annotation
                map.addAnnotation(annotation)
            }
        }

        func sync(dots: [MapDot], on map: MLNMapView) {
            let wanted = Dictionary(dots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let stale = dotAnnotations.filter { wanted[$0.key] != $0.value.dot }
            if !stale.isEmpty {
                map.removeAnnotations(Array(stale.values))
                for id in stale.keys { dotAnnotations[id] = nil }
            }
            // From the de-duplicated set, so a repeated id can't add an annotation that is never removed.
            let added = wanted.values.filter { dotAnnotations[$0.id] == nil }.map { dot in
                let annotation = DotAnnotation(dot: dot)
                dotAnnotations[dot.id] = annotation
                return annotation
            }
            if !added.isEmpty { map.addAnnotations(added) }
        }

        func apply(_ request: MapCameraRequest, to map: MLNMapView) {
            // Fitting needs the view's size; before layout, wait until the style has loaded.
            guard map.bounds.width > 0, map.style != nil else {
                pendingCamera = request
                // didFinishLoading applies it once the style loads. With the style loaded but layout still to come,
                // retry shortly (only then, so a style that never loads doesn't poll forever).
                guard map.style != nil else { return }
                Task { @MainActor [weak self, weak map] in
                    try? await Task.sleep(for: .milliseconds(150))
                    guard let self, let map, self.pendingCamera == request else { return }
                    self.apply(request, to: map)
                }
                return
            }
            pendingCamera = nil
            switch request.target {
            case let .center(coordinate, zoom):
                map.setCenter(coordinate, zoomLevel: max(zoom, map.zoomLevel), animated: true)
            case .fit(let coordinates):
                guard let first = coordinates.first else { return }
                if coordinates.count == 1 {
                    map.setCenter(first, zoomLevel: max(13, map.zoomLevel), animated: true)
                    return
                }
                var bounds = MLNCoordinateBounds(sw: first, ne: first)
                for coordinate in coordinates {
                    bounds.sw.latitude = min(bounds.sw.latitude, coordinate.latitude)
                    bounds.sw.longitude = min(bounds.sw.longitude, coordinate.longitude)
                    bounds.ne.latitude = max(bounds.ne.latitude, coordinate.latitude)
                    bounds.ne.longitude = max(bounds.ne.longitude, coordinate.longitude)
                }
                // Room for the full-screen map's controls and cards; small embedded maps (e.g. Trace) get a
                // proportional margin instead, as fixed insets taller than the view would zoom out to the whole world.
                // Pins carry a name label about 120 pt wide, and the right edge holds the control column, so the
                // horizontal margins allow for both. The map runs under the status and tab bars, so their insets add on.
                let size = map.bounds.size
                let safe = map.safeAreaInsets
                let padding = UIEdgeInsets(
                    top: min(120, size.height * 0.2) + safe.top, left: min(70, size.width * 0.15) + safe.left,
                    bottom: min(180, size.height * 0.25) + safe.bottom, right: min(140, size.width * 0.25) + safe.right
                )
                let camera = map.cameraThatFitsCoordinateBounds(bounds, edgePadding: padding)
                camera.altitude = max(camera.altitude, 1_500)
                map.setCamera(camera, animated: true)
            case .resetNorth:
                map.resetNorth()
            }
        }

        // MARK: MLNMapViewDelegate

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            if let pendingCamera { apply(pendingCamera, to: mapView) }
            layoutPins(on: mapView)
        }

        func mapView(_ mapView: MLNMapView, viewFor annotation: any MLNAnnotation) -> MLNAnnotationView? {
            if let dot = annotation as? DotAnnotation {
                let view = MLNAnnotationView(annotation: dot, reuseIdentifier: nil)
                view.frame = CGRect(x: 0, y: 0, width: 12, height: 12)
                view.backgroundColor = dot.dot.color
                view.layer.cornerRadius = 6
                view.layer.borderColor = UIColor.white.cgColor
                view.layer.borderWidth = 1.5
                return view
            }
            if let cluster = annotation as? ClusterAnnotation {
                return ClusterAnnotationView(annotation: cluster)
            }
            guard let annotation = annotation as? PinAnnotation else { return nil }
            let view = PinAnnotationView(annotation: annotation, reuseIdentifier: nil)
            view.configure(pin: annotation.pin, selected: annotation.pin.id == selectedID)
            pinViews[annotation.pin.id] = view
            return view
        }

        func mapView(_ mapView: MLNMapView, annotationCanShowCallout annotation: any MLNAnnotation) -> Bool { false }

        func mapView(_ mapView: MLNMapView, didSelect annotation: any MLNAnnotation) {
            if let cluster = annotation as? ClusterAnnotation {
                mapView.deselectAnnotation(cluster, animated: false)
                zoom(into: cluster, on: mapView)
                return
            }
            guard let annotation = annotation as? PinAnnotation else { return }
            parent?.onSelect(annotation.pin.id)
            mapView.deselectAnnotation(annotation, animated: false)
        }

        func mapView(_ mapView: MLNMapView, strokeColorForShapeAnnotation annotation: MLNShape) -> UIColor {
            (annotation as? LineAnnotation)?.line?.color ?? .systemBlue
        }

        func mapView(_ mapView: MLNMapView, lineWidthForPolylineAnnotation annotation: MLNPolyline) -> CGFloat {
            CGFloat((annotation as? LineAnnotation)?.line?.width ?? 3)
        }

        func mapView(_ mapView: MLNMapView, alphaForShapeAnnotation annotation: MLNShape) -> CGFloat { 0.85 }

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            if clustersEnabled { layoutPins(on: mapView) }
            let bounds = mapView.visibleCoordinateBounds
            parent?.onRegionChange(
                GeoBounds(minLongitude: bounds.sw.longitude, minLatitude: bounds.sw.latitude,
                          maxLongitude: bounds.ne.longitude, maxLatitude: bounds.ne.latitude),
                mapView.zoomLevel
            )
        }
    }
}
