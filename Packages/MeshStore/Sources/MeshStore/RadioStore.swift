import Foundation
import SwiftData

/// Persistence for one radio: contacts, channels, messages and history, in its own SwiftData store.
@MainActor
public final class RadioStore {
    public static let schema = Schema([
        ContactRecord.self, ChannelRecord.self, MessageRecord.self, ConversationRecord.self,
        PositionSample.self, TelemetrySample.self, StoreMetadata.self,
    ])

    public let radioKeyHex: String
    public let container: ModelContainer
    public var context: ModelContext { container.mainContext }

    /// - Parameter inMemory: For tests and previews.
    public convenience init(radioKeyHex: String, inMemory: Bool = false) throws {
        try self.init(radioKeyHex: radioKeyHex, url: inMemory ? nil : try Self.storeURL(radioKeyHex: radioKeyHex))
    }

    /// Opens the store at `url`, or in memory when nil.
    init(radioKeyHex: String, url: URL?) throws {
        self.radioKeyHex = radioKeyHex
        let configuration = if let url {
            ModelConfiguration(schema: Self.schema, url: url)
        } else {
            ModelConfiguration(schema: Self.schema, isStoredInMemoryOnly: true)
        }
        container = try ModelContainer(for: Self.schema, configurations: configuration)
    }

    public static func storeURL(radioKeyHex: String) throws -> URL {
        let directory = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "Radios", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "radio-\(radioKeyHex.lowercased()).store")
    }

    public func save() {
        try? context.save()
    }

    // MARK: Metadata

    public var metadata: StoreMetadata {
        if let existing = try? context.fetch(FetchDescriptor<StoreMetadata>()).first { return existing }
        let created = StoreMetadata()
        context.insert(created)
        return created
    }

    // MARK: Contacts

    public func contacts() -> [ContactRecord] {
        (try? context.fetch(FetchDescriptor<ContactRecord>(sortBy: [SortDescriptor(\.name)]))) ?? []
    }

    public func contact(keyHex: String) -> ContactRecord? {
        let key = keyHex.lowercased()
        var descriptor = FetchDescriptor<ContactRecord>(predicate: #Predicate { $0.keyHex == key })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Finds the contact whose key starts with `prefixHex` (6-byte message prefix or 4-byte signer prefix).
    /// Queried in the store rather than by loading every contact: views call this for each message, hop and log row.
    public func contact(prefixHex: String) -> ContactRecord? {
        let prefix = prefixHex.lowercased()
        var descriptor = FetchDescriptor<ContactRecord>(
            predicate: #Predicate { $0.keyHex.starts(with: prefix) },
            sortBy: [SortDescriptor(\.name)]
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    public func contact(named name: String) -> ContactRecord? {
        var descriptor = FetchDescriptor<ContactRecord>(predicate: #Predicate { $0.name == name }, sortBy: [SortDescriptor(\.name)])
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    @discardableResult
    public func upsertContact(keyHex: String, configure: (ContactRecord) -> Void) -> ContactRecord {
        let record = contact(keyHex: keyHex) ?? {
            let created = ContactRecord(keyHex: keyHex.lowercased(), name: "", typeRaw: 0)
            context.insert(created)
            return created
        }()
        configure(record)
        return record
    }

    public func delete(_ record: ContactRecord) {
        context.delete(record)
    }

    // MARK: Channels

    public func channels() -> [ChannelRecord] {
        (try? context.fetch(FetchDescriptor<ChannelRecord>(sortBy: [SortDescriptor(\.index)]))) ?? []
    }

    public func channel(index: Int) -> ChannelRecord? {
        var descriptor = FetchDescriptor<ChannelRecord>(predicate: #Predicate { $0.index == index })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Replaces the stored channels with what the radio reported.
    public func replaceChannels(_ slots: [ChannelSlot]) {
        for existing in channels() where !slots.contains(where: { $0.index == existing.index }) {
            context.delete(existing)
        }
        for slot in slots {
            if let existing = channel(index: slot.index) {
                existing.name = slot.name
                existing.secret = slot.secret
            } else {
                context.insert(ChannelRecord(index: slot.index, name: slot.name, secret: slot.secret))
            }
        }
    }

    // MARK: Conversations & messages

    /// The conversation's record, created if it doesn't exist yet.
    public func conversation(id: String) -> ConversationRecord {
        if let existing = existingConversation(id: id) { return existing }
        let created = ConversationRecord(id: id)
        context.insert(created)
        return created
    }

    public func existingConversation(id: String) -> ConversationRecord? {
        var descriptor = FetchDescriptor<ConversationRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    public func conversations() -> [ConversationRecord] {
        (try? context.fetch(FetchDescriptor<ConversationRecord>(sortBy: [SortDescriptor(\.lastMessageAt, order: .reverse)]))) ?? []
    }

    /// Messages oldest first; with `limit`, the newest `limit` messages (still oldest first).
    public func messages(conversationID: String, limit: Int? = nil) -> [MessageRecord] {
        var descriptor = FetchDescriptor<MessageRecord>(
            predicate: #Predicate { $0.conversationID == conversationID },
            sortBy: [SortDescriptor(\.receivedAt, order: limit == nil ? .forward : .reverse)]
        )
        guard let limit else { return (try? context.fetch(descriptor)) ?? [] }
        descriptor.fetchLimit = limit
        return ((try? context.fetch(descriptor)) ?? []).reversed()
    }

    public func message(id: UUID) -> MessageRecord? {
        var descriptor = FetchDescriptor<MessageRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    public func outgoingMessage(ackTag: Int) -> MessageRecord? {
        var descriptor = FetchDescriptor<MessageRecord>(predicate: #Predicate { $0.ackTag == ackTag && $0.isOutgoing })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Finds the message a reaction targets.
    public func message(conversationID: String, reactionHash: String) -> MessageRecord? {
        var descriptor = FetchDescriptor<MessageRecord>(
            predicate: #Predicate { $0.conversationID == conversationID && $0.reactionHash == reactionHash }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// True if an identical incoming message is already stored (radios can deliver duplicates).
    public func hasIncoming(conversationID: String, senderTimestamp: Int, text: String) -> Bool {
        var descriptor = FetchDescriptor<MessageRecord>(predicate: #Predicate {
            $0.conversationID == conversationID && $0.senderTimestamp == senderTimestamp && $0.text == text && !$0.isOutgoing
        })
        descriptor.fetchLimit = 1
        return ((try? context.fetchCount(descriptor)) ?? 0) > 0
    }

    /// Adds a message and updates its conversation's preview and unread count.
    public func append(_ message: MessageRecord, preview: String, mentionsMe: Bool = false) {
        context.insert(message)
        let conversation = conversation(id: message.conversationID)
        conversation.lastMessageAt = message.receivedAt
        conversation.lastMessagePreview = preview
        if !message.isOutgoing && !message.isRead {
            conversation.unreadCount += 1
            if mentionsMe { conversation.mentionCount += 1 }
        }
    }

    public func markRead(conversationID: String) {
        let unread = FetchDescriptor<MessageRecord>(predicate: #Predicate { $0.conversationID == conversationID && !$0.isRead })
        for message in (try? context.fetch(unread)) ?? [] {
            message.isRead = true
        }
        let conversation = conversation(id: conversationID)
        conversation.unreadCount = 0
        conversation.mentionCount = 0
    }

    /// Unread count for the app badge: muted chats don't count, mentions-only chats count their mentions.
    public var totalUnread: Int {
        conversations().reduce(0) { total, conversation in
            switch conversation.muteLevel {
            case .all: total + conversation.unreadCount
            case .mentions: total + conversation.mentionCount
            case .muted: total
            }
        }
    }

    public func deleteConversation(id: String) {
        for message in messages(conversationID: id) { context.delete(message) }
        context.delete(conversation(id: id))
    }

    // MARK: History

    public func addPosition(keyHex: String, latitudeE6: Int, longitudeE6: Int, at date: Date, source: String) {
        context.insert(PositionSample(keyHex: keyHex, latitudeE6: latitudeE6, longitudeE6: longitudeE6, recordedAt: date, source: source))
    }

    public func positions(keyHex: String, limit: Int = 500) -> [PositionSample] {
        var descriptor = FetchDescriptor<PositionSample>(
            predicate: #Predicate { $0.keyHex == keyHex },
            sortBy: [SortDescriptor(\.recordedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return ((try? context.fetch(descriptor)) ?? []).reversed()
    }

    public func addTelemetry(keyHex: String, at date: Date, channel: Int, kind: String, value: Double) {
        context.insert(TelemetrySample(keyHex: keyHex, recordedAt: date, channel: channel, kind: kind, value: value))
    }

    public func telemetry(keyHex: String, limit: Int = 2_000) -> [TelemetrySample] {
        var descriptor = FetchDescriptor<TelemetrySample>(
            predicate: #Predicate { $0.keyHex == keyHex },
            sortBy: [SortDescriptor(\.recordedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return ((try? context.fetch(descriptor)) ?? []).reversed()
    }
}

/// A channel slot as the radio reports it.
public struct ChannelSlot: Equatable, Sendable {
    public var index: Int
    public var name: String
    public var secret: Data

    public init(index: Int, name: String, secret: Data) {
        self.index = index
        self.name = name
        self.secret = secret
    }
}
