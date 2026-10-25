import Foundation
import SwiftData

/// A contact known to the radio, plus local-only details (nickname, block, alerts).
@Model
public final class ContactRecord {
    @Attribute(.unique) public var keyHex: String
    public var name: String
    public var typeRaw: Int
    public var flags: Int
    /// 255 = unknown path (flood).
    public var outPathLength: Int
    public var outPath: Data
    public var lastAdvert: Int
    public var latitudeE6: Int
    public var longitudeE6: Int
    public var lastModified: Int
    public var nickname: String?
    public var isBlocked: Bool
    public var alertWhenHeard: Bool
    public var lastHeard: Date?
    public var lastSNR: Double?
    /// False once the radio removed it (e.g. overwritten when full).
    public var isOnRadio: Bool

    public init(keyHex: String, name: String, typeRaw: Int) {
        self.keyHex = keyHex
        self.name = name
        self.typeRaw = typeRaw
        flags = 0
        outPathLength = 255
        outPath = Data()
        lastAdvert = 0
        latitudeE6 = 0
        longitudeE6 = 0
        lastModified = 0
        isBlocked = false
        alertWhenHeard = false
        isOnRadio = true
    }

    public var displayName: String { nickname?.isEmpty == false ? nickname! : name }
    public var isFavourite: Bool { flags & 0x01 != 0 }
    public var hasLocation: Bool { latitudeE6 != 0 || longitudeE6 != 0 }
    public var keyPrefixHex: String { String(keyHex.prefix(12)) }
}

/// A channel slot on the radio.
@Model
public final class ChannelRecord {
    @Attribute(.unique) public var index: Int
    public var name: String
    public var secret: Data

    public init(index: Int, name: String, secret: Data) {
        self.index = index
        self.name = name
        self.secret = secret
    }

    public var isPublic: Bool { index == 0 }
    public var isHashtag: Bool { name.hasPrefix("#") }
}

/// Delivery state of a message.
public enum MessageStatus: Int, Codable, Sendable {
    case sending = 0
    case sent = 1
    case delivered = 2
    case failed = 3
    case received = 4
}

/// One emoji reaction on a message.
public struct MessageReaction: Codable, Hashable, Sendable {
    public var emoji: String
    public var sender: String
    public var isMine: Bool

    public init(emoji: String, sender: String, isMine: Bool) {
        self.emoji = emoji
        self.sender = sender
        self.isMine = isMine
    }
}

@Model
public final class MessageRecord {
    @Attribute(.unique) public var id: UUID
    public var conversationID: String
    public var isOutgoing: Bool
    public var text: String
    /// Channel and room messages: the author's name.
    public var senderName: String?
    /// Direct messages: the contact key. Room posts: the author's key prefix.
    public var senderKeyHex: String?
    public var senderTimestamp: Int
    public var receivedAt: Date
    public var statusRaw: Int
    public var ackTag: Int?
    public var attempt: Int
    /// nil = direct route; otherwise flood hop count.
    public var hops: Int?
    public var snr: Double?
    public var isRead: Bool
    public var textTypeRaw: Int
    public var reactions: [MessageReaction]
    /// Identifier other apps use to target reactions at this message.
    public var reactionHash: String
    /// Round trip reported by the ACK, in milliseconds.
    public var roundTripMs: Int?
    /// Repeater hashes the message travelled through, in travel order, as comma-separated uppercase hex
    /// ("10,A3"). Outgoing direct messages: the path used to send. Incoming: the path heard in the RX log.
    /// nil = unknown; empty = direct neighbour.
    public var routeHex: String?
    /// Mesh message or a local-only entry (see `MessageKind`); 0 for stores made before this existed.
    public var kindRaw: Int = 0

    public init(
        conversationID: String,
        isOutgoing: Bool,
        text: String,
        senderTimestamp: Int,
        receivedAt: Date = Date(),
        status: MessageStatus,
        reactionHash: String
    ) {
        id = UUID()
        self.conversationID = conversationID
        self.isOutgoing = isOutgoing
        self.text = text
        self.senderTimestamp = senderTimestamp
        self.receivedAt = receivedAt
        statusRaw = status.rawValue
        attempt = 0
        isRead = isOutgoing
        textTypeRaw = 0
        reactions = []
        self.reactionHash = reactionHash
    }

    public var status: MessageStatus {
        get { MessageStatus(rawValue: statusRaw) ?? .received }
        set { statusRaw = newValue.rawValue }
    }

    public var sentDate: Date { Date(timeIntervalSince1970: TimeInterval(senderTimestamp)) }

    public var kind: MessageKind {
        get { MessageKind(rawValue: kindRaw) ?? .mesh }
        set { kindRaw = newValue.rawValue }
    }

    /// True for entries the app added itself (position replies, notices); they were never sent over the mesh.
    public var isLocal: Bool { kind != .mesh }

    /// Hop hashes in travel order; nil when the route isn't known.
    public var routeHashes: [String]? {
        get { routeHex.map { $0.isEmpty ? [] : $0.split(separator: ",").map(String.init) } }
        set { routeHex = newValue?.map { $0.uppercased() }.joined(separator: ",") }
    }
}

/// What a stored message is.
public enum MessageKind: Int, Codable, Sendable {
    /// Sent or received over the mesh.
    case mesh = 0
    /// A contact's position from a telemetry reply, shown like an incoming location pin.
    case positionReport = 1
    /// A local note in the conversation, e.g. "Alice didn't share a position".
    case notice = 2
}

/// How much a conversation notifies.
public enum MuteLevel: Int, Codable, CaseIterable, Sendable {
    case all = 0
    case mentions = 1
    case muted = 2

    public var title: String {
        switch self {
        case .all: "All messages"
        case .mentions: "Mentions only"
        case .muted: "Muted"
        }
    }

    /// Whether an incoming message at this level posts a notification.
    public func notifies(isMention: Bool) -> Bool {
        switch self {
        case .all: true
        case .mentions: isMention
        case .muted: false
        }
    }
}

/// Per-conversation state for the chat list.
@Model
public final class ConversationRecord {
    @Attribute(.unique) public var id: String
    public var lastMessageAt: Date
    public var lastMessagePreview: String
    public var unreadCount: Int
    public var mentionCount: Int
    public var isPinned: Bool
    /// Notification level (`MuteLevel`). Stores made before mute levels existed open with 0 (all messages).
    public var muteLevelRaw: Int = 0
    /// The on/off mute of older versions, kept so chats muted there stay muted.
    @Attribute(originalName: "isMuted") var legacyMuted: Bool = false
    public var draft: String

    public init(id: String) {
        self.id = id
        lastMessageAt = .distantPast
        lastMessagePreview = ""
        unreadCount = 0
        mentionCount = 0
        isPinned = false
        draft = ""
    }

    public var muteLevel: MuteLevel {
        get {
            if muteLevelRaw == 0 && legacyMuted { return .muted }
            return MuteLevel(rawValue: muteLevelRaw) ?? .all
        }
        set {
            muteLevelRaw = newValue.rawValue
            legacyMuted = false
        }
    }
}

/// Where and when a node was seen, from adverts and telemetry.
@Model
public final class PositionSample {
    public var keyHex: String
    public var latitudeE6: Int
    public var longitudeE6: Int
    public var recordedAt: Date
    public var source: String

    public init(keyHex: String, latitudeE6: Int, longitudeE6: Int, recordedAt: Date, source: String) {
        self.keyHex = keyHex
        self.latitudeE6 = latitudeE6
        self.longitudeE6 = longitudeE6
        self.recordedAt = recordedAt
        self.source = source
    }
}

/// One telemetry reading from a node (decoded CayenneLPP channel/value).
@Model
public final class TelemetrySample {
    public var keyHex: String
    public var recordedAt: Date
    public var channel: Int
    public var kind: String
    public var value: Double

    public init(keyHex: String, recordedAt: Date, channel: Int, kind: String, value: Double) {
        self.keyHex = keyHex
        self.recordedAt = recordedAt
        self.channel = channel
        self.kind = kind
        self.value = value
    }
}

/// Single row of per-radio bookkeeping.
@Model
public final class StoreMetadata {
    @Attribute(.unique) public var key: String
    public var contactsLastModified: Int

    public init() {
        key = "metadata"
        contactsLastModified = 0
    }
}
