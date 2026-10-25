import Foundation
import UserNotifications

/// Tells the user about GPS Feed problems they can't see while the app is in the background.
@MainActor
public protocol GPSFeedAlerting: AnyObject {
    /// The radio dropped (not a disconnect the user asked for) while the phone was feeding it positions.
    func radioConnectionLost(radioName: String?)
    /// The radio is connected again after a lost-connection alert.
    func radioReconnected()
}

/// Posts GPS Feed alerts as local notifications. Authorization is requested at launch by the app's message notifier.
@MainActor
public final class GPSFeedNotifier: GPSFeedAlerting {
    nonisolated static let connectionLostID = "app.mcore.gpsfeed.connectionLost"

    private let center: UNUserNotificationCenter

    public init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    public func radioConnectionLost(radioName: String?) {
        let content = UNMutableNotificationContent()
        content.title = radioName.map { "\($0) disconnected" } ?? "Radio disconnected"
        content.body = "m-Core lost the radio; its position won't update until it reconnects."
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        // A fixed identifier replaces an earlier alert instead of stacking them.
        center.add(UNNotificationRequest(identifier: Self.connectionLostID, content: content, trigger: nil))
    }

    /// Removes the alert from Notification Centre once the radio is back.
    public func radioReconnected() {
        center.removeDeliveredNotifications(withIdentifiers: [Self.connectionLostID])
    }
}
