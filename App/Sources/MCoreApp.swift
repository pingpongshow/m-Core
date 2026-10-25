import MeshCoreKit
import MeshMaps
import MeshServices
import MeshTools
import SwiftUI

/// Every service the app uses, created once and shared through the environment.
@MainActor
final class AppServices {
    /// Set once the launch work (notification permission, reconnect) has run.
    var didLaunch = false
    /// A notification tap that arrived before a window took over `notifier.onOpen` (the tap that launched the app).
    var pendingConversationOpen: String?
    let radio: RadioController
    let gpsFeed: GPSFeedService
    let messaging: MessagingService
    let contacts: ContactsService
    let telemetry: TelemetryService
    let remote: RemoteNodeService
    let radioSettings: RadioSettingsService
    let stats: RadioStatsService
    let traces: TraceService
    let discovery: MeshDiscoveryService
    let notifier: UserNotificationNotifier
    let offlineMaps: OfflineMapStore
    let location: LocationTracker
    let rxLog: RxLogService
    let observer: ObserverService
    let coverage: CoverageService
    let presetCatalog = PresetCatalog()
    let internetMap: InternetMapService
    let routes: RouteRecorderService
    let pairing: AccessoryPairing
    lazy var positions = PositionRequestService(messaging: messaging) { [telemetry] in try await telemetry.request(from: $0) }
    /// Live location shares use the phone's fix while it's recent; the tracker runs only while a share does.
    lazy var liveLocation = LiveLocationService(
        messaging: messaging,
        location: { [location] in
            location.current.flatMap { fix in
                fix.timestamp.timeIntervalSinceNow > -300
                    ? GeoCoordinate(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude) : nil
            }
        },
        setTracking: { [location] in $0 ? location.start() : location.stop() }
    )

    init() {
        radio = RadioController(restoreIdentifier: "app.mcore.central")
        // Handlers run in creation order on connect: the GPS feed first, so message sync never delays it.
        gpsFeed = GPSFeedService(radio: radio, locationProvider: CoreLocationProvider())
        notifier = UserNotificationNotifier()
        messaging = MessagingService(radio: radio, notifier: notifier)
        contacts = ContactsService(radio: radio, messaging: messaging)
        telemetry = TelemetryService(radio: radio, messaging: messaging)
        remote = RemoteNodeService(radio: radio, messaging: messaging)
        radioSettings = RadioSettingsService(radio: radio, messaging: messaging)
        stats = RadioStatsService(radio: radio)
        traces = TraceService(radio: radio)
        discovery = MeshDiscoveryService(radio: radio)
        offlineMaps = OfflineMapStore()
        let location = LocationTracker()
        self.location = location
        rxLog = RxLogService(radio: radio)
        internetMap = InternetMapService(radio: radio)
        observer = ObserverService(radio: radio, secrets: KeychainSecretStore(), clientVersion: "m-Core/\(Bundle.main.versionString)")
        coverage = CoverageService(radio: radio, traces: traces) {
            location.current.map { GeoCoordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) }
        }
        // The route recorder has its own location provider so it can run alongside the GPS Feed.
        routes = RouteRecorderService(locationProvider: CoreLocationProvider())
        pairing = AccessoryPairing(radio: radio)
        gpsFeed.alerts = GPSFeedNotifier()
        let messaging = messaging
        let notifier = notifier
        notifier.onReply = { [weak notifier] conversationID, text in
            do {
                _ = try await messaging.send(text, to: conversationID)
            } catch {
                // Say so rather than drop the reply; the notification's own Reply action can try again.
                notifier?.notifyMessage(
                    title: "Reply not sent", body: "\(errorMessage(error)) “\(text)”", conversationID: conversationID, isMention: false
                )
            }
        }
        notifier.onOpen = { [weak self] in self?.pendingConversationOpen = $0 }
    }
}

@main
struct MCoreApp: App {
    private let services = AppServices()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WindowRoot(services: services) { RootView() }
        }
        .commands { AppCommands() }
        .onChange(of: scenePhase, initial: true) {
            services.observer.setAppActive(scenePhase != .background)
        }

        // iPad: a chat in its own window ("Open in New Window").
        WindowGroup("Conversation", id: ConversationWindow.id, for: String.self) { $conversationID in
            WindowRoot(services: services, handlesNotifications: false) { ConversationWindow(conversationID: conversationID) }
        }
    }
}

extension View {
    /// Puts every app service into the environment.
    func services(_ services: AppServices) -> some View {
        environment(services.radio)
            .environment(services.gpsFeed)
            .environment(services.messaging)
            .environment(services.contacts)
            .environment(services.telemetry)
            .environment(services.remote)
            .environment(services.radioSettings)
            .environment(services.stats)
            .environment(services.traces)
            .environment(services.discovery)
            .environment(services.offlineMaps)
            .environment(services.location)
            .environment(services.rxLog)
            .environment(services.observer)
            .environment(services.coverage)
            .environment(services.presetCatalog)
            .environment(services.internetMap)
            .environment(services.routes)
            .environment(services.pairing)
            .environment(services.positions)
            .environment(services.liveLocation)
    }
}
