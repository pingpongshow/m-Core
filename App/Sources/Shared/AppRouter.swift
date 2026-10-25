import Foundation
import Observation

/// App-wide navigation state, so notifications and links can open a screen.
@MainActor
@Observable
final class AppRouter {
    var selection: AppSection = .chats
    /// Conversation IDs pushed in the Chats stack.
    var chatPath: [String] = []
    /// Contact key pushed in the Nodes stack.
    var nodePath: [String] = []
    /// Contact to center on when the map opens.
    var mapFocusKeyHex: String?
    /// A route to draw on the map (a contact's path or a message's hops), consumed by the Map screen.
    var mapRoute: MapRouteRequest?
    /// Screens pushed in the Tools and Settings stacks (used by the command palette).
    var toolsPath: [ToolRoute] = []
    var settingsPath: [SettingsRoute] = []
    var isPaletteOpen = false
    /// Repeaters (key hex, in travel order) to load into Trace path when it opens.
    var tracePrefill: [String]?
    /// Bumped to ask the Chats list to focus its search field (⌘F).
    var searchFocusRequest = 0

    func open(_ route: ToolRoute) {
        selection = .tools
        toolsPath = [route]
    }

    func open(_ route: SettingsRoute) {
        selection = .settings
        settingsPath = [route]
    }

    /// Opens Trace path with a route through these repeaters.
    func trace(through repeaterKeys: [String]) {
        tracePrefill = repeaterKeys
        open(.trace)
    }

    func focusSearch() {
        selection = .chats
        chatPath = []
        searchFocusRequest += 1
    }
    /// A `.pmtiles`/`.mbtiles` file opened from Files or AirDrop, consumed by Offline Maps.
    var pendingMapImport: URL?

    func openConversation(_ conversationID: String) {
        selection = .chats
        chatPath = [conversationID]
    }

    func openNode(_ keyHex: String) {
        selection = .nodes
        nodePath = [keyHex]
    }

    func showOnMap(_ keyHex: String) {
        mapFocusKeyHex = keyHex
        selection = .map
    }

    /// Opens the map with a route drawn through the repeaters whose hash prefixes are known.
    func showRoute(_ route: MapRouteRequest) {
        mapRoute = route
        selection = .map
    }

    /// Opens Offline Maps to import a map file handed to the app.
    func importMapFile(_ url: URL) {
        pendingMapImport = url
        selection = .map
    }
}

/// A path through the mesh to draw on the map.
struct MapRouteRequest: Equatable, Identifiable {
    let id = UUID()
    /// Repeater hash prefixes in travel order (uppercase hex, e.g. "A3"), from our radio outwards.
    var hopHashes: [String]
    /// The contact at the far end, when known (its key hex).
    var endpointKeyHex: String?
    /// Shown above the map while the route is drawn, e.g. "Path to Alice".
    var title: String
}

/// Tools screens reachable by route.
enum ToolRoute: String, Hashable, CaseIterable {
    case trace, discovery, rxLog, coverage, lineOfSight, routeRecorder, stats, commandLine

    var title: String {
        switch self {
        case .trace: "Trace path"
        case .discovery: "Local Mesh Discovery"
        case .rxLog: "RX log"
        case .coverage: "Coverage walk"
        case .lineOfSight: "Line of sight"
        case .routeRecorder: "Route recorder"
        case .stats: "Stats & noise floor"
        case .commandLine: "Command line"
        }
    }

    var systemImage: String {
        switch self {
        case .trace: "point.topleft.down.to.point.bottomright.curvepath"
        case .discovery: "dot.radiowaves.left.and.right"
        case .rxLog: "list.bullet.rectangle"
        case .coverage: "figure.walk"
        case .lineOfSight: "mountain.2"
        case .routeRecorder: "point.bottomleft.forward.to.point.topright.scurvepath"
        case .stats: "waveform.path.ecg"
        case .commandLine: "terminal"
        }
    }
}

/// Settings screens reachable by route.
enum SettingsRoute: String, Hashable, CaseIterable {
    case radio, gpsFeed, radioSettings, channels, messages, internetMap, observer, appearance, help, about

    var title: String {
        switch self {
        case .radio: "Radio"
        case .gpsFeed: "GPS Feed"
        case .radioSettings: "Radio settings"
        case .channels: "Channels"
        case .messages: "Messages"
        case .internetMap: "Internet Map"
        case .observer: "Observer uplink"
        case .appearance: "Appearance"
        case .help: "Help"
        case .about: "About m-Core"
        }
    }

    var systemImage: String {
        switch self {
        case .radio: "antenna.radiowaves.left.and.right"
        case .gpsFeed: "location.fill"
        case .radioSettings: "slider.horizontal.3"
        case .channels: "number"
        case .messages: "bubble.left.and.text.bubble.right"
        case .internetMap: "globe"
        case .observer: "antenna.radiowaves.left.and.right.circle"
        case .appearance: "circle.lefthalf.filled"
        case .help: "questionmark.circle"
        case .about: "info.circle"
        }
    }
}
