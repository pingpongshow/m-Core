import Foundation
import UserNotifications

/// Local notifications for incoming messages and node alerts, with a reply action.
@MainActor
public final class UserNotificationNotifier: NSObject, MessageNotifier {
    nonisolated public static let messageCategory = "app.mcore.message"
    nonisolated public static let replyAction = "app.mcore.reply"
    nonisolated static let conversationKey = "conversationID"

    /// Called when the user replies from a notification.
    public var onReply: ((_ conversationID: String, _ text: String) async -> Void)?
    /// Called when the user taps a message notification.
    public var onOpen: ((_ conversationID: String) -> Void)?
    /// While true, nothing is posted (e.g. the simulated radio's canned demo traffic).
    public var isSuppressed: () -> Bool = { false }

    private let center: UNUserNotificationCenter

    public init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        super.init()
        let reply = UNTextInputNotificationAction(
            identifier: Self.replyAction, title: "Reply", options: [], textInputButtonTitle: "Send", textInputPlaceholder: "Message"
        )
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.messageCategory, actions: [reply], intentIdentifiers: []),
        ])
        center.delegate = self
    }

    public func requestAuthorization() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    public func notifyMessage(title: String, body: String, conversationID: String, isMention: Bool) {
        guard !isSuppressed() else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = conversationID
        content.categoryIdentifier = Self.messageCategory
        content.userInfo = [Self.conversationKey: conversationID]
        if isMention { content.interruptionLevel = .timeSensitive }
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    public func notifyNodeHeard(name: String) {
        guard !isSuppressed() else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(name) is on the mesh"
        content.body = "Heard an advert just now."
        content.sound = .default
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    public func setBadge(_ count: Int) {
        center.setBadgeCount(count)
    }
}

extension UserNotificationNotifier: UNUserNotificationCenterDelegate {
    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let conversationID = response.notification.request.content.userInfo[Self.conversationKey] as? String else { return }
        let replyText = (response as? UNTextInputNotificationResponse)?.userText
        if let replyText, !replyText.isEmpty {
            // Returning tells the system the action is done, so the reply must be sent first: in the background the app
            // can be suspended as soon as this returns.
            await handleReply(conversationID: conversationID, text: replyText)
        } else {
            await handleOpen(conversationID: conversationID)
        }
    }

    private func handleReply(conversationID: String, text: String) async {
        await onReply?(conversationID, text)
    }

    private func handleOpen(conversationID: String) {
        onOpen?(conversationID)
    }
}
