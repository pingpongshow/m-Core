import CoreLocation
import MeshCoreKit
import MeshDesign
import MeshMaps
import MeshServices
import MeshStore
import MeshTools
import SwiftUI

struct MapScreen: View {
    @Environment(MessagingService.self) private var messaging
    @Environment(RadioController.self) private var radio
    @Environment(OfflineMapStore.self) private var offlineMaps
    @Environment(AppRouter.self) private var router
    @Environment(LocationTracker.self) private var location
    @Environment(InternetMapService.self) private var internetMap
    @Environment(CoverageService.self) private var coverage
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("map.showInternetNodes") private var showInternetNodes = false
    @AppStorage("map.showCoverage") private var showCoverage = false
    @State private var style = MapStyleProvider()
    @State private var selectedID: String?
    @State private var camera: MapCameraRequest?
    @State private var visibleTypes = Set(MapNodeFilter.allCases)
    @State private var heard = MapHeardFilter.any
    @State private var hops = MapHopFilter.any
    /// A route handed over by ``AppRouter/showRoute(_:)``, drawn until closed.
    @State private var route: MapRouteRequest?
    @State private var isFullscreen = false
    @State private var showOfflineMaps = false
    @State private var didFitInitially = false
    @State private var visibleBounds: GeoBounds?
    @State private var visibleZoom: Double = 1
    @State private var internetCache = InternetNodeCache()

    var body: some View {
        let all = allContacts
        let contacts = visibleContacts(in: all)
        let pins = pins(for: contacts) + internetPins(excluding: contacts)
        let candidates = MapRouteResolver.candidates(from: all)
        let resolvedRoute = route.map { resolve($0, candidates: candidates) }
        MeshMapView(
            styleURL: style.styleURL,
            pins: pins,
            lines: lines(route: resolvedRoute, candidates: candidates),
            dots: showCoverage ? MapDot.coverage(coverage.samples) : [],
            selectedID: selectedID,
            clustersPins: true,
            showsScale: true,
            camera: camera,
            onSelect: { id in withAnimation(.snappy) { selectedID = id } },
            onRegionChange: { bounds, zoom in
                visibleBounds = bounds
                visibleZoom = zoom
            }
        )
        // The map runs to every edge; its overlays still keep to the safe area.
        .ignoresSafeArea()
        .overlay(alignment: .topTrailing) { controls.padding(MCSpacing.l) }
        .overlay(alignment: .topLeading) {
            if !isFullscreen {
                VStack(alignment: .leading, spacing: MCSpacing.s) {
                    ConnectionButton(isFloating: true)
                    if offlineMaps.areas.isEmpty && offlineMaps.activeDownload == nil {
                        MapOverviewBanner { showOfflineMaps = true }
                    } else if let download = offlineMaps.activeDownload {
                        DownloadChip(download: download)
                            .onTapGesture { showOfflineMaps = true }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityHint("Opens Offline Maps")
                    }
                    if let route, let resolvedRoute {
                        MapRouteBanner(title: route.title, detail: resolvedRoute.summary) {
                            withAnimation(.snappy) { self.route = nil }
                        }
                        .frame(maxWidth: 320, alignment: .leading)
                    }
                }
                .padding(MCSpacing.l)
            }
        }
        .overlay(alignment: .bottom) {
            VStack(alignment: .leading, spacing: MCSpacing.s) {
                if let selectedID, let card = card(for: selectedID, contacts: contacts, candidates: candidates) {
                    card.transition(.move(edge: .bottom).combined(with: .opacity))
                }
                MapAttribution()
            }
            .padding(.horizontal, MCSpacing.l)
            .padding(.bottom, MCSpacing.s)
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(isFullscreen ? .hidden : .automatic, for: .tabBar)
        .sheet(isPresented: $showOfflineMaps) {
            OfflineMapsView(styleURL: style.styleURL, startBounds: visibleBounds) { area in
                showOfflineMaps = false
                camera = MapCameraRequest(target: .fit(area.bounds.corners))
            }
        }
        .onAppear {
            location.start()
            updateStyle()
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "MCOpenOfflineMaps") { showOfflineMaps = true }
            #endif
            focusIfRequested()
            showRouteIfRequested()
            openImportIfRequested()
            fitInitially(pins)
            OfflineMapThumbnails.shared.generateMissing(in: offlineMaps)
        }
        .onChange(of: pins.count) { fitInitially(pins) }
        .onDisappear { location.stop() }
        .onChange(of: offlineMaps.areas) {
            updateStyle()
            OfflineMapThumbnails.shared.generateMissing(in: offlineMaps)
        }
        .onChange(of: colorScheme) { updateStyle() }
        .onChange(of: router.mapFocusKeyHex) { focusIfRequested() }
        .onChange(of: router.mapRoute) { showRouteIfRequested() }
        .onChange(of: router.pendingMapImport) { openImportIfRequested() }
    }

    // MARK: Data

    /// Where routes start: the radio's reported position, else the phone's.
    private var routeStart: CLLocationCoordinate2D? {
        radioCoordinate ?? location.current?.coordinate
    }

    private func resolve(_ route: MapRouteRequest, candidates: [RouteCandidate]) -> ResolvedRoute {
        let endpoint = route.endpointKeyHex.flatMap { messaging.store?.contact(keyHex: $0) }
        return MapRouteResolver.resolve(route, start: routeStart, endpoint: endpoint, candidates: candidates)
    }

    private func selectedPath(for contact: ContactRecord, candidates: [RouteCandidate]) -> ResolvedRoute? {
        MapRouteResolver.path(to: contact, start: routeStart, candidates: candidates)
    }

    private var radioCoordinate: CLLocationCoordinate2D? {
        guard let info = radio.selfInfo, info.latitudeE6 != 0 || info.longitudeE6 != 0 else { return nil }
        return CLLocationCoordinate2D(latitude: Double(info.latitudeE6) / 1e6, longitude: Double(info.longitudeE6) / 1e6)
    }

    private func pins(for contacts: [ContactRecord]) -> [MapPin] {
        var pins = contacts.compactMap { contact -> MapPin? in
            guard let coordinate = contact.coordinate else { return nil }
            return MapPin(id: contact.keyHex, coordinate: coordinate, title: contact.displayName,
                          kind: contact.avatarKind, isStale: contact.isStale)
        }
        if let radioCoordinate {
            pins.append(MapPin(id: Self.radioPinID, coordinate: radioCoordinate,
                               title: radio.selfInfo?.name ?? "Radio", kind: .contact, isRadio: true))
        }
        return pins
    }

    private func lines(route resolvedRoute: ResolvedRoute?, candidates: [RouteCandidate]) -> [MapLine] {
        var lines: [MapLine] = []
        // The offset between where the radio thinks it is and where the phone is.
        if let radioCoordinate, let phone = location.current?.coordinate,
           CLLocation(latitude: phone.latitude, longitude: phone.longitude)
               .distance(from: CLLocation(latitude: radioCoordinate.latitude, longitude: radioCoordinate.longitude)) > 30 {
            lines.append(MapLine(id: "radio-offset", coordinates: [phone, radioCoordinate], color: .systemOrange, width: 2))
        }
        if let selectedID, selectedID != Self.radioPinID, let store = messaging.store {
            let trail = store.positions(keyHex: selectedID).reversed().map {
                CLLocationCoordinate2D(latitude: Double($0.latitudeE6) / 1e6, longitude: Double($0.longitudeE6) / 1e6)
            }
            if trail.count > 1 {
                lines.append(MapLine(id: "trail-\(selectedID)", coordinates: trail, color: UIColor(MCColor.accent)))
            }
            if let contact = store.contact(keyHex: selectedID), let path = selectedPath(for: contact, candidates: candidates),
               path.coordinates.count > 1 {
                lines.append(MapLine(id: "path-\(selectedID)", coordinates: path.coordinates, color: MapRouteBanner.lineColor))
            }
        }
        if let route, let resolvedRoute, resolvedRoute.coordinates.count > 1 {
            let color = MapRouteBanner.lineColor
            lines.append(MapLine(id: "route-\(route.id)", coordinates: resolvedRoute.coordinates, color: color, width: 4))
        }
        return lines
    }

    private static let radioPinID = "radio"
    fileprivate static let internetPrefix = "imap:"
    /// Below this zoom the Internet Map would cover the screen with pins.
    fileprivate static let internetMinZoom = 7.0

    private func updateStyle() {
        style.update(areas: offlineMaps.mapSourceURLs, dark: colorScheme == .dark)
    }

    /// Frames every node the first time any are known.
    private func fitInitially(_ pins: [MapPin]) {
        guard !didFitInitially, !pins.isEmpty, selectedID == nil else { return }
        didFitInitially = true
        camera = MapCameraRequest(target: .fit(pins.map(\.coordinate)))
    }

    /// Draws a route handed over by the router and frames it.
    private func showRouteIfRequested() {
        guard let request = router.mapRoute else { return }
        router.mapRoute = nil
        withAnimation(.snappy) {
            route = request
            selectedID = nil
        }
        let coordinates = resolve(request, candidates: MapRouteResolver.candidates(from: allContacts)).coordinates
        if !coordinates.isEmpty { camera = MapCameraRequest(target: .fit(coordinates)) }
    }

    /// A map file opened from Files or AirDrop: Offline Maps takes it from the router.
    private func openImportIfRequested() {
        if router.pendingMapImport != nil { showOfflineMaps = true }
    }

    private func focusIfRequested() {
        guard let keyHex = router.mapFocusKeyHex else { return }
        router.mapFocusKeyHex = nil
        if let contact = messaging.store?.contact(keyHex: keyHex), let coordinate = contact.coordinate {
            visibleTypes.insert(MapNodeFilter.allCases.first { $0.matches(contact.avatarKind) } ?? .contacts)
            heard = .any
            selectedID = keyHex
            camera = MapCameraRequest(target: .center(coordinate, zoom: 14))
        }
    }

    // MARK: Overlays

    private var controls: some View {
        VStack(spacing: MCSpacing.s) {
            FloatingMapControls([
                MapControl(systemImage: "location.north.line", accessibilityLabel: "Reset north") {
                    camera = MapCameraRequest(target: .resetNorth)
                },
                MapControl(systemImage: location.current == nil ? "location.slash" : "location", accessibilityLabel: "Show my location") {
                    if let phone = location.current?.coordinate { camera = MapCameraRequest(target: .center(phone, zoom: 14)) }
                },
                MapControl(systemImage: "circle.grid.cross", accessibilityLabel: "Show all nodes") {
                    let coordinates = pins(for: visibleContacts(in: allContacts)).map(\.coordinate)
                    if !coordinates.isEmpty { camera = MapCameraRequest(target: .fit(coordinates)) }
                },
                MapControl(
                    systemImage: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                    accessibilityLabel: isFullscreen ? "Exit fullscreen" : "Fullscreen"
                ) {
                    withAnimation { isFullscreen.toggle() }
                }
            ])
            MapFilterMenu(
                visibleTypes: $visibleTypes, heard: $heard, hops: $hops,
                showInternetNodes: $showInternetNodes, showCoverage: $showCoverage
            )
            FloatingIconButton(systemImage: "square.and.arrow.down.on.square", accessibilityLabel: "Offline maps") {
                showOfflineMaps = true
            }
        }
    }

    private func card(for id: String, contacts: [ContactRecord], candidates: [RouteCandidate]) -> AnyView? {
        if id.hasPrefix(Self.internetPrefix) {
            let key = String(id.dropFirst(Self.internetPrefix.count))
            guard let node = internetCache.nodes.first(where: { $0.publicKeyHex == key })
                ?? internetMap.nodes.first(where: { $0.publicKeyHex == key }) else { return nil }
            return AnyView(InternetNodeCard(node: node, phone: location.current) { selectedID = nil })
        }
        if id == Self.radioPinID, let info = radio.selfInfo {
            return AnyView(RadioPinCard(name: info.name, coordinate: radioCoordinate, phone: location.current) { selectedID = nil })
        }
        guard let contact = contacts.first(where: { $0.keyHex == id }) ?? messaging.store?.contact(keyHex: id) else { return nil }
        let path = selectedPath(for: contact, candidates: candidates)
        return AnyView(NodePinCard(contact: contact, phone: location.current, onClose: { selectedID = nil }, onDetails: {
            router.openNode(contact.keyHex)
        }, onMessage: contact.advertType == .chat || contact.advertType == .room ? {
            router.openConversation(ConversationID.direct(keyHex: contact.keyHex).description)
        } : nil, pathNote: path.flatMap { $0.hopCount > 0 ? "Path: \($0.summary)" : nil }))
    }
}

// MARK: Contacts

extension MapScreen {
    /// Every stored contact (one fetch per render; the body re-renders on each location fix).
    private var allContacts: [ContactRecord] {
        _ = messaging.revision
        return messaging.store?.contacts() ?? []
    }

    private func visibleContacts(in all: [ContactRecord]) -> [ContactRecord] {
        let now = Date()
        return all.filter { contact in
            guard contact.hasLocation, !contact.isBlocked else { return false }
            guard visibleTypes.contains(where: { $0.matches(contact.avatarKind) }) else { return false }
            if heard != .any, now.timeIntervalSince(contact.lastSeen) > TimeInterval(heard.rawValue) { return false }
            return hops.matches(contact.outPathHashes)
        }
    }
}

// MARK: Internet Map

extension MapScreen {
    /// Internet Map nodes in view that aren't already contacts, nearest the centre first.
    fileprivate func internetPins(excluding contacts: [ContactRecord]) -> [MapPin] {
        visibleInternetNodes(excluding: contacts).map { node in
            MapPin(id: Self.internetPrefix + node.publicKeyHex,
                   coordinate: CLLocationCoordinate2D(latitude: node.latitude, longitude: node.longitude),
                   title: node.name, kind: node.type.avatarKind, isInternet: true)
        }
    }

    fileprivate func visibleInternetNodes(excluding contacts: [ContactRecord]) -> [InternetMapNode] {
        // Internet Map nodes have no known path, so a hop filter hides them like flood-routed contacts.
        guard showInternetNodes, hops == .any, visibleZoom >= Self.internetMinZoom, let bounds = visibleBounds,
              bounds.minLatitude <= bounds.maxLatitude, bounds.minLongitude <= bounds.maxLongitude else { return [] }
        let known = Set(contacts.map { $0.keyHex.lowercased() })
        let types = Set(visibleTypes.flatMap(\.advertTypes))
        // Reading the list's size and date also keeps the map observing it while the box query is cached.
        let key = InternetNodeCache.Key(bounds: bounds, types: types, count: internetMap.nodes.count, fetchedAt: internetMap.fetchedAt)
        let inView = internetCache.nodes(for: key) {
            let center = bounds.center
            return internetMap.nodes(latitudes: bounds.minLatitude...bounds.maxLatitude,
                                     longitudes: bounds.minLongitude...bounds.maxLongitude, types: types)
                .sorted {
                    abs($0.latitude - center.latitude) + abs($0.longitude - center.longitude)
                        < abs($1.latitude - center.latitude) + abs($1.longitude - center.longitude)
                }
        }
        return Array(inView.lazy.filter { !known.contains($0.publicKeyHex) }.prefix(200))
    }
}

/// The Internet Map nodes in the visible box, nearest the centre first. Filtering tens of thousands of nodes is
/// redone only when the box, the type filter or the node list changes, not on every render (e.g. each location fix).
@MainActor
final class InternetNodeCache {
    struct Key: Equatable {
        var bounds: GeoBounds
        var types: Set<AdvertType>
        var count: Int
        var fetchedAt: Date?
    }

    private var key: Key?
    private(set) var nodes: [InternetMapNode] = []

    func nodes(for key: Key, compute: () -> [InternetMapNode]) -> [InternetMapNode] {
        if key != self.key {
            self.key = key
            nodes = compute()
        }
        return nodes
    }
}

extension GeoBounds {
    var corners: [CLLocationCoordinate2D] {
        [CLLocationCoordinate2D(latitude: minLatitude, longitude: minLongitude),
         CLLocationCoordinate2D(latitude: maxLatitude, longitude: maxLongitude)]
    }
}
