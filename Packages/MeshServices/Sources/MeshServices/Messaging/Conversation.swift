import Foundation

/// Identifies a chat: a direct conversation with a contact (or room), or a channel slot.
public enum ConversationID: Hashable, Sendable, CustomStringConvertible {
    case direct(keyHex: String)
    case channel(index: Int)

    public init?(_ string: String) {
        if string.hasPrefix("dm:") {
            self = .direct(keyHex: String(string.dropFirst(3)))
        } else if string.hasPrefix("ch:"), let index = Int(string.dropFirst(3)) {
            self = .channel(index: index)
        } else {
            return nil
        }
    }

    public var description: String {
        switch self {
        case .direct(let keyHex): "dm:\(keyHex.lowercased())"
        case .channel(let index): "ch:\(index)"
        }
    }
}

/// Posts local notifications for incoming messages and node alerts; mocked in tests.
@MainActor
public protocol MessageNotifier: AnyObject {
    func notifyMessage(title: String, body: String, conversationID: String, isMention: Bool)
    func notifyNodeHeard(name: String)
}
