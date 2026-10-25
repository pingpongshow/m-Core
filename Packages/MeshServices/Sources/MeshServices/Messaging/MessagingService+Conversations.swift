import Foundation
import MeshCoreKit
import MeshStore

// MARK: Conversations

extension MessagingService {
    /// Dismisses `lastError` once the user has seen it.
    public func clearError() {
        lastError = nil
    }

    public func markRead(_ conversationID: String) {
        store?.markRead(conversationID: conversationID)
        changed()
    }

    public func deleteConversation(_ conversationID: String) {
        store?.deleteConversation(id: conversationID)
        changed()
    }

    public func muteLevel(for conversationID: String) -> MuteLevel {
        store?.existingConversation(id: conversationID)?.muteLevel ?? .all
    }

    public func setMuteLevel(_ level: MuteLevel, conversationID: String) {
        store?.conversation(id: conversationID).muteLevel = level
        changed()
    }

    public func setPinned(_ pinned: Bool, conversationID: String) {
        store?.conversation(id: conversationID).isPinned = pinned
        changed()
    }

    public func saveDraft(_ draft: String, conversationID: String) {
        store?.conversation(id: conversationID).draft = draft
        store?.save()
    }

    /// Adds an entry that only exists on this phone (a position reply or a notice); nothing is sent.
    @discardableResult
    public func addLocalMessage(_ text: String, kind: MessageKind, senderName: String? = nil, to conversationID: String) -> MessageRecord? {
        guard let store else { return nil }
        let date = now()
        let record = MessageRecord(
            conversationID: conversationID, isOutgoing: false, text: text,
            senderTimestamp: Int(date.timeIntervalSince1970), receivedAt: date, status: .received, reactionHash: ""
        )
        record.kind = kind
        record.senderName = senderName
        record.isRead = true
        store.append(record, preview: text)
        changed()
        return record
    }

    /// Title for a conversation: contact name, room name or channel name.
    public func displayName(for conversationID: String) -> String {
        switch ConversationID(conversationID) {
        case .direct(let keyHex): store?.contact(keyHex: keyHex)?.displayName ?? keyHex.prefix(12).uppercased()
        case .channel(let index): store?.channel(index: index)?.name ?? "Channel \(index)"
        case nil: conversationID
        }
    }
}

// MARK: Replies, retries and routes

extension MessagingService {
    /// Replies quoting a message.
    @discardableResult
    public func reply(_ text: String, to messageID: UUID) async throws -> MessageRecord {
        guard let target = store?.message(id: messageID) else { throw MessagingError.unknownConversation }
        let name = target.isOutgoing ? selfName : (target.senderName ?? displayName(for: target.conversationID))
        return try await send(MessageFormat.replyText(to: name, quoting: target.text, reply: text), to: target.conversationID)
    }

    /// Whether "Retry flood" applies: an outgoing direct message that failed or hasn't been acknowledged yet.
    public static func canRetryFlood(_ record: MessageRecord) -> Bool {
        guard record.isOutgoing, !record.isLocal, case .direct = ConversationID(record.conversationID) else { return false }
        return record.status == .failed || record.status == .sent
    }

    /// Repeater hashes of a contact's out path (uppercase hex, from our radio outwards); nil when it floods.
    public static func pathHashes(of contact: ContactRecord) -> [String]? {
        guard contact.outPathLength != 0xFF else { return nil }
        guard let path = MeshPath(encodedLength: UInt8(clamping: contact.outPathLength), bytes: [UInt8](contact.outPath)) else {
            return nil
        }
        return path.hashes.map { Data($0).hexString.uppercased() }
    }
}

// MARK: Blocking

extension MessagingService {
    public var blockedChannelNames: Set<String> {
        Set(defaults.stringArray(forKey: blockedNamesKey) ?? [])
    }

    public func setBlocked(_ blocked: Bool, channelSender name: String) {
        var names = blockedChannelNames
        if blocked { names.insert(name) } else { names.remove(name) }
        defaults.set(Array(names), forKey: blockedNamesKey)
        revision += 1
    }
}

// MARK: Channels

extension MessagingService {
    /// Adds a channel in the first free slot. A name starting with "#" makes a hashtag channel (key derived from the name).
    public func addChannel(name: String, secret: Data? = nil) async throws {
        guard let session, let store else { throw MessagingError.notConnected }
        let used = Set(store.channels().map(\.index))
        guard let index = (1..<maxChannels).first(where: { !used.contains($0) }) else { throw MessagingError.noFreeChannelSlot }
        let isHashtag = name.hasPrefix("#")
        let channelName = isHashtag ? name.lowercased() : name
        let key = secret ?? (isHashtag ? MessageFormat.hashtagSecret(name) : Self.randomSecret())
        try await session.perform(.setChannel(ChannelInfo(index: UInt8(index), name: channelName, secret: [UInt8](key))))
        await syncChannels()
    }

    public func removeChannel(index: Int) async throws {
        guard let session else { throw MessagingError.notConnected }
        try await session.perform(.setChannel(ChannelInfo(index: UInt8(index), name: "", secret: [UInt8](repeating: 0, count: 16))))
        deleteConversation(ConversationID.channel(index: index).description)
        await syncChannels()
    }

    static func randomSecret() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}
