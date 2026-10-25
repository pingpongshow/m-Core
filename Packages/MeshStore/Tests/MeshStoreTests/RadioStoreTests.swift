import Foundation
import SwiftData
import Testing
@testable import MeshStore

@MainActor
struct RadioStoreTests {
    private func makeStore() throws -> RadioStore {
        try RadioStore(radioKeyHex: "abcdef", inMemory: true)
    }

    @Test func upsertsAndFindsContacts() throws {
        let store = try makeStore()
        store.upsertContact(keyHex: "A0A1A2A3A4A5") { $0.name = "Alice" }
        store.upsertContact(keyHex: "a0a1a2a3a4a5") { $0.nickname = "Al" }
        #expect(store.contacts().count == 1)
        let alice = try #require(store.contact(prefixHex: "a0a1a2"))
        #expect(alice.displayName == "Al")
        #expect(store.contact(keyHex: "A0A1A2A3A4A5")?.name == "Alice")
        #expect(store.contact(named: "Alice") != nil)
    }

    @Test func findsContactsByPrefixAndNameInTheStore() throws {
        let store = try makeStore()
        store.upsertContact(keyHex: "b0b1b2b3b4b5") { $0.name = "Bob" }
        store.upsertContact(keyHex: "a0a1a2a3a4a5") { $0.name = "Alice" }
        store.save()
        // Unsaved changes are found too.
        store.upsertContact(keyHex: "a0ffffffffff") { $0.name = "Aaron" }
        #expect(store.contact(prefixHex: "B0B1")?.name == "Bob")
        #expect(store.contact(prefixHex: "a0a1a2")?.name == "Alice")
        #expect(store.contact(prefixHex: "a0ff")?.name == "Aaron")
        // Several matches: the first by name, as before.
        #expect(store.contact(prefixHex: "a0")?.name == "Aaron")
        #expect(store.contact(prefixHex: "c0") == nil)
        #expect(store.contact(named: "Bob")?.keyHex == "b0b1b2b3b4b5")
        #expect(store.contact(named: "Nobody") == nil)
    }

    @Test func markReadOnlyTouchesItsConversation() throws {
        let store = try makeStore()
        for (id, text) in [("dm:aa", "one"), ("dm:aa", "two"), ("dm:bb", "other")] {
            store.append(
                MessageRecord(conversationID: id, isOutgoing: false, text: text, senderTimestamp: 1, status: .received, reactionHash: text),
                preview: text
            )
        }
        store.markRead(conversationID: "dm:aa")
        #expect(store.messages(conversationID: "dm:aa").allSatisfy { $0.isRead })
        #expect(store.messages(conversationID: "dm:bb").allSatisfy { !$0.isRead })
        #expect(store.conversation(id: "dm:bb").unreadCount == 1)
    }

    @Test func appendingUpdatesConversation() throws {
        let store = try makeStore()
        let incoming = MessageRecord(
            conversationID: "dm:aa", isOutgoing: false, text: "hi", senderTimestamp: 1, status: .received, reactionHash: "x"
        )
        store.append(incoming, preview: "hi", mentionsMe: true)
        let outgoing = MessageRecord(
            conversationID: "dm:aa", isOutgoing: true, text: "yo", senderTimestamp: 2, status: .sending, reactionHash: "y"
        )
        store.append(outgoing, preview: "yo")

        let conversation = store.conversation(id: "dm:aa")
        #expect(conversation.unreadCount == 1)
        #expect(conversation.mentionCount == 1)
        #expect(conversation.lastMessagePreview == "yo")
        #expect(store.totalUnread == 1)
        #expect(store.messages(conversationID: "dm:aa").map(\.text) == ["hi", "yo"])
        #expect(store.messages(conversationID: "dm:aa", limit: 1).map(\.text) == ["yo"])
        #expect(store.hasIncoming(conversationID: "dm:aa", senderTimestamp: 1, text: "hi"))
        #expect(!store.hasIncoming(conversationID: "dm:aa", senderTimestamp: 2, text: "yo"))

        store.markRead(conversationID: "dm:aa")
        #expect(store.totalUnread == 0)
        #expect(store.messages(conversationID: "dm:aa").allSatisfy { $0.isRead })
    }

    @Test func findsMessagesByAckTagAndReactionHash() throws {
        let store = try makeStore()
        let message = MessageRecord(
            conversationID: "ch:0", isOutgoing: true, text: "hello", senderTimestamp: 5, status: .sent, reactionHash: "abcd1234"
        )
        message.ackTag = 77
        store.append(message, preview: "hello")
        #expect(store.outgoingMessage(ackTag: 77)?.id == message.id)
        #expect(store.message(conversationID: "ch:0", reactionHash: "abcd1234")?.id == message.id)
        #expect(store.message(conversationID: "ch:1", reactionHash: "abcd1234") == nil)
    }

    @Test func replacesChannels() throws {
        let store = try makeStore()
        store.replaceChannels([
            ChannelSlot(index: 0, name: "Public", secret: Data([1])), ChannelSlot(index: 1, name: "#test", secret: Data([2]))
        ])
        store.replaceChannels([
            ChannelSlot(index: 0, name: "Public", secret: Data([1])), ChannelSlot(index: 2, name: "Team", secret: Data([3]))
        ])
        #expect(store.channels().map(\.name) == ["Public", "Team"])
        #expect(store.channel(index: 2)?.secret == Data([3]))
    }

    @Test func deletesConversation() throws {
        let store = try makeStore()
        let message = MessageRecord(
            conversationID: "dm:bb", isOutgoing: false, text: "x", senderTimestamp: 1, status: .received, reactionHash: "h"
        )
        store.append(message, preview: "x")
        store.deleteConversation(id: "dm:bb")
        #expect(store.messages(conversationID: "dm:bb").isEmpty)
        #expect(store.conversations().isEmpty)
    }

    @Test func historyQueries() throws {
        let store = try makeStore()
        for index in 0..<3 {
            let date = Date(timeIntervalSince1970: TimeInterval(index))
            store.addPosition(keyHex: "aa", latitudeE6: index, longitudeE6: index, at: date, source: "advert")
            store.addTelemetry(keyHex: "aa", at: date, channel: 1, kind: "voltage", value: Double(index))
        }
        #expect(store.positions(keyHex: "aa").map(\.latitudeE6) == [0, 1, 2])
        #expect(store.positions(keyHex: "aa", limit: 2).map(\.latitudeE6) == [1, 2])
        #expect(store.telemetry(keyHex: "aa").count == 3)
    }

    @Test func metadataIsSingleton() throws {
        let store = try makeStore()
        store.metadata.contactsLastModified = 42
        #expect(store.metadata.contactsLastModified == 42)
    }

    @Test func muteLevelsFilterNotificationsAndBadge() throws {
        let store = try makeStore()
        for (id, level) in [("dm:aa", MuteLevel.all), ("dm:bb", .mentions), ("dm:cc", .muted)] {
            let message = MessageRecord(
                conversationID: id, isOutgoing: false, text: "hi", senderTimestamp: 1, status: .received, reactionHash: id
            )
            store.append(message, preview: "hi", mentionsMe: id == "dm:bb")
            store.conversation(id: id).muteLevel = level
        }
        // All counts its unread, mentions-only counts its mention, muted counts nothing.
        #expect(store.totalUnread == 2)
        #expect(MuteLevel.all.notifies(isMention: false))
        #expect(!MuteLevel.mentions.notifies(isMention: false))
        #expect(MuteLevel.mentions.notifies(isMention: true))
        #expect(!MuteLevel.muted.notifies(isMention: true))
    }

    @Test func routeHashesAndKindRoundTrip() throws {
        let store = try makeStore()
        let message = MessageRecord(
            conversationID: "dm:aa", isOutgoing: false, text: "x", senderTimestamp: 1, status: .received, reactionHash: "r"
        )
        #expect(message.routeHashes == nil)
        #expect(message.kind == .mesh && !message.isLocal)
        message.routeHashes = ["10", "a3"]
        message.kind = .positionReport
        store.append(message, preview: "x")
        let stored = try #require(store.messages(conversationID: "dm:aa").first)
        #expect(stored.routeHashes == ["10", "A3"])
        #expect(stored.isLocal)
        stored.routeHashes = []
        #expect(stored.routeHashes == [])
    }

    /// A store written before mute levels, route hashes and message kinds existed opens with defaults,
    /// and a chat muted with the old on/off switch stays muted.
    @Test func opensStoresFromBeforeMuteLevels() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "meshstore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "radio.store")

        do {
            let schema = Schema([SchemaV1.ConversationRecord.self, SchemaV1.MessageRecord.self])
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
            let context = ModelContext(container)
            let muted = SchemaV1.ConversationRecord(id: "ch:1")
            muted.isMuted = true
            context.insert(muted)
            context.insert(SchemaV1.ConversationRecord(id: "ch:2"))
            context.insert(SchemaV1.MessageRecord(conversationID: "ch:1", text: "old"))
            try context.save()
        }

        let store = try RadioStore(radioKeyHex: "abcdef", url: url)
        #expect(store.conversation(id: "ch:1").muteLevel == .muted)
        #expect(store.conversation(id: "ch:2").muteLevel == .all)
        let message = try #require(store.messages(conversationID: "ch:1").first)
        #expect(message.text == "old")
        #expect(message.kind == .mesh)
        #expect(message.routeHashes == nil)

        store.conversation(id: "ch:1").muteLevel = .mentions
        #expect(store.conversation(id: "ch:1").muteLevel == .mentions)
        store.conversation(id: "ch:1").muteLevel = .all
        #expect(store.conversation(id: "ch:1").muteLevel == .all)
    }
}

/// The conversation and message models as they were before mute levels.
private enum SchemaV1 {
    @Model
    final class ConversationRecord {
        @Attribute(.unique) var id: String
        var lastMessageAt: Date
        var lastMessagePreview: String
        var unreadCount: Int
        var mentionCount: Int
        var isPinned: Bool
        var isMuted: Bool
        var draft: String

        init(id: String) {
            self.id = id
            lastMessageAt = .distantPast
            lastMessagePreview = ""
            unreadCount = 0
            mentionCount = 0
            isPinned = false
            isMuted = false
            draft = ""
        }
    }

    @Model
    final class MessageRecord {
        @Attribute(.unique) var id: UUID
        var conversationID: String
        var isOutgoing: Bool
        var text: String
        var senderName: String?
        var senderKeyHex: String?
        var senderTimestamp: Int
        var receivedAt: Date
        var statusRaw: Int
        var ackTag: Int?
        var attempt: Int
        var hops: Int?
        var snr: Double?
        var isRead: Bool
        var textTypeRaw: Int
        var reactions: [MessageReaction]
        var reactionHash: String
        var roundTripMs: Int?

        init(conversationID: String, text: String) {
            id = UUID()
            self.conversationID = conversationID
            isOutgoing = false
            self.text = text
            senderTimestamp = 1
            receivedAt = Date()
            statusRaw = MessageStatus.received.rawValue
            attempt = 0
            isRead = true
            textTypeRaw = 0
            reactions = []
            reactionHash = "h"
        }
    }
}
