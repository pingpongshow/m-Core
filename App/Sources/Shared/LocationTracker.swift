import CoreLocation
import Foundation
import Observation

/// The phone's position while a screen that shows distances or the map is visible.
@MainActor
@Observable
final class LocationTracker {
    private(set) var current: CLLocation?
    private(set) var isDenied = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var session: CLServiceSession?
    @ObservationIgnored private var users = 0

    func start() {
        users += 1
        guard task == nil else { return }
        session = CLServiceSession(authorization: .whenInUse)
        task = Task { [weak self] in
            do {
                for try await update in CLLocationUpdate.liveUpdates() {
                    guard let self else { return }
                    if update.authorizationDenied || update.authorizationDeniedGlobally {
                        self.isDenied = true
                    } else if let location = update.location, location.horizontalAccuracy >= 0 {
                        self.isDenied = false
                        self.current = location
                    }
                }
            } catch {}
        }
    }

    func stop() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        task?.cancel()
        task = nil
        session?.invalidate()
        session = nil
    }
}
