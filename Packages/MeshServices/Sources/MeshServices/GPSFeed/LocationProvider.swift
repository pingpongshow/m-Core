import Foundation
#if os(iOS)
import CoreLocation
#endif

public enum LocationEvent: Equatable, Sendable {
    case fix(LocationFix)
    case denied
    case unavailable
}

/// Source of phone location updates; mocked in tests.
@MainActor
public protocol LocationProvider: AnyObject {
    /// Starts updates tuned for `preset`. Calling again restarts with the new preset.
    func start(preset: GPSFeedSettings.Preset) -> AsyncStream<LocationEvent>
    func stop()
}

#if os(iOS)
/// CoreLocation live updates, kept running in the background by a background activity session
/// (the blue status-bar pill) while the GPS Feed is active.
@MainActor
public final class CoreLocationProvider: LocationProvider {
    private var serviceSession: CLServiceSession?
    private var backgroundSession: CLBackgroundActivitySession?
    private var task: Task<Void, Never>?
    private var continuation: AsyncStream<LocationEvent>.Continuation?

    public init() {}

    public func start(preset: GPSFeedSettings.Preset) -> AsyncStream<LocationEvent> {
        stop()
        let (stream, continuation) = AsyncStream<LocationEvent>.makeStream(bufferingPolicy: .bufferingNewest(8))
        self.continuation = continuation
        serviceSession = CLServiceSession(authorization: .whenInUse)
        backgroundSession = CLBackgroundActivitySession()
        let configuration: CLLocationUpdate.LiveConfiguration = switch preset {
        case .walking: .fitness
        case .driving: .automotiveNavigation
        case .stationary, .custom: .default
        }
        task = Task {
            do {
                for try await update in CLLocationUpdate.liveUpdates(configuration) {
                    if update.authorizationDenied || update.authorizationDeniedGlobally {
                        continuation.yield(.denied)
                    } else if let location = update.location {
                        continuation.yield(.fix(LocationFix(
                            coordinate: Coordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude),
                            horizontalAccuracy: location.horizontalAccuracy,
                            timestamp: location.timestamp,
                            altitude: location.verticalAccuracy > 0 ? location.altitude : nil
                        )))
                    } else if update.locationUnavailable {
                        continuation.yield(.unavailable)
                    }
                }
            } catch {
                continuation.yield(.unavailable)
            }
            continuation.finish()
        }
        return stream
    }

    public func stop() {
        task?.cancel()
        task = nil
        continuation?.finish()
        continuation = nil
        backgroundSession?.invalidate()
        backgroundSession = nil
        serviceSession?.invalidate()
        serviceSession = nil
    }
}
#endif
