import CryptoKit
import Foundation
import MeshCoreKit
import MeshStore
import MeshTools

// MARK: Receiving

extension MessagingService {
    func receive(_ message: ContactMessage) {
        guard let store else { return }
        if message.textType == .cliData {
            onCommandReply?(message.senderPrefix.hex, message.text)
            return
        }
        let contact = store.contact(prefixHex: message.senderPrefix.hex)
        guard contact?.isBlocked != true else { return }
        let keyHex = contact?.keyHex ?? message.senderPrefix.hex
        let conversationID = ConversationID.direct(keyHex: keyHex).description

        if let reaction = MessageFormat.parseReaction(message.text), reaction.targetSender == nil {
            applyReaction(reaction, from: contact?.displayName ?? "Them", conversationID: conversationID)
            return
        }
        guard !store.hasIncoming(conversationID: conversationID, senderTimestamp: Int(message.senderTimestamp), text: message.text) else {
            return
        }

        let record = MessageRecord(
            conversationID: conversationID, isOutgoing: false, text: message.text,
            senderTimestamp: Int(message.senderTimestamp), receivedAt: arrivalDate(senderTimestamp: message.senderTimestamp),
            status: .received, reactionHash: MessageFormat.reactionHash(text: message.text, timestamp: message.senderTimestamp)
        )
        record.textTypeRaw = Int(message.textType.rawValue)
        record.snr = message.snr
        record.hops = hops(message.routing)
        record.routeHashes = heardRoute(for: message.routing) { packet in
            guard packet.payloadType == .textMessage, let hashes = packet.addressHashes else { return false }
            return hashes.destination == selfHash && hashes.source == message.senderPrefix.bytes.first
        }
        record.senderKeyHex = keyHex
        // Room servers relay posts signed by their authors.
        if let signer = message.signerPrefix, contact?.typeRaw == Int(AdvertType.room.rawValue) {
            let signerHex = Data(signer).hexString
            record.senderKeyHex = signerHex
            record.senderName = store.contact(prefixHex: signerHex)?.displayName ?? signerHex.uppercased()
        }
        deliver(record, title: contact?.displayName ?? "Unknown sender", store: store)
        contact?.lastHeard = now()
        contact?.lastSNR = message.snr ?? contact?.lastSNR
    }

    func receive(_ message: ChannelMessage) {
        guard let store else { return }
        let senderName = message.senderName
        if let senderName, blockedChannelNames.contains(senderName) { return }
        let conversationID = ConversationID.channel(index: Int(message.channelIndex)).description

        if let reaction = MessageFormat.parseReaction(message.body), reaction.targetSender != nil {
            applyReaction(reaction, from: senderName ?? "Someone", conversationID: conversationID)
            return
        }
        guard !store.hasIncoming(conversationID: conversationID, senderTimestamp: Int(message.senderTimestamp), text: message.body) else {
            return
        }

        let record = MessageRecord(
            conversationID: conversationID, isOutgoing: false, text: message.body,
            senderTimestamp: Int(message.senderTimestamp), receivedAt: arrivalDate(senderTimestamp: message.senderTimestamp),
            status: .received, reactionHash: MessageFormat.reactionHash(text: message.body, timestamp: message.senderTimestamp)
        )
        record.senderName = senderName
        record.snr = message.snr
        record.hops = hops(message.routing)
        let channelHash = store.channel(index: Int(message.channelIndex)).map { Self.channelHash(secret: $0.secret) }
        record.routeHashes = heardRoute(for: message.routing) { packet in
            packet.payloadType == .groupText && packet.channelHash == channelHash
        }
        let channelName = store.channel(index: Int(message.channelIndex))?.name ?? "Channel \(message.channelIndex)"
        deliver(record, title: senderName.map { "\($0) in \(channelName)" } ?? channelName, store: store)
    }

    private func deliver(_ record: MessageRecord, title: String, store: RadioStore) {
        let isActive = activeConversationID == record.conversationID
        record.isRead = isActive
        let mentionsMe = MessageFormat.mentions(record.text, name: selfName)
        let body = MessageFormat.displayText(MessageFormat.parseReply(record.text)?.body ?? record.text)
        let preview = record.senderName.map { "\($0): \(body)" } ?? body
        store.append(record, preview: preview, mentionsMe: mentionsMe)
        let level = store.conversation(id: record.conversationID).muteLevel
        if !isActive && level.notifies(isMention: mentionsMe) {
            notifier?.notifyMessage(title: title, body: body, conversationID: record.conversationID, isMention: mentionsMe)
        }
    }

    private func applyReaction(_ reaction: MessageFormat.Reaction, from sender: String, conversationID: String) {
        guard let target = store?.message(conversationID: conversationID, reactionHash: reaction.hash) else { return }
        let entry = MessageReaction(emoji: reaction.emoji, sender: sender, isMine: false)
        if !target.reactions.contains(entry) {
            target.reactions.append(entry)
        }
    }

    /// Sort date for an incoming message: the sender's time when it looks right (queued messages arrive late),
    /// otherwise the time it arrived.
    private func arrivalDate(senderTimestamp: UInt32) -> Date {
        let sent = Date(timeIntervalSince1970: TimeInterval(senderTimestamp))
        let current = now()
        let isPlausible = sent <= current.addingTimeInterval(60) && sent >= current.addingTimeInterval(-7 * 86_400)
        return isPlausible ? min(sent, current) : current
    }

    private func hops(_ routing: MessageRouting) -> Int? {
        if case .flood(let hops) = routing { return hops }
        return nil
    }
}

// MARK: Routes from the RX log

/// A text packet from the RX log, kept briefly to find the path of the message it carried.
struct HeardPacket {
    let date: Date
    let packet: MeshPacket
}

extension MessagingService {
    /// How long an RX log packet can precede the message it carried (the radio logs it, then queues the message).
    static let heardPacketWindow: TimeInterval = 30

    func remember(_ entry: RxLogEntry) {
        guard let packet = MeshPacket.decode(entry.raw), packet.routeType.isFlood,
              packet.payloadType == .textMessage || packet.payloadType == .groupText else { return }
        let cutoff = now().addingTimeInterval(-Self.heardPacketWindow)
        recentPackets.removeAll { $0.date < cutoff }
        recentPackets.append(HeardPacket(date: now(), packet: packet))
        if recentPackets.count > 32 { recentPackets.removeFirst(recentPackets.count - 32) }
    }

    /// The repeaters a flooded message came through (travel order), matched against recent RX log packets by type,
    /// address or channel hash and hop count. The match is used up, so a repeat of the same packet can't claim it twice.
    func heardRoute(for routing: MessageRouting, matching matches: (MeshPacket) -> Bool) -> [String]? {
        guard case .flood(let hops) = routing else { return nil }
        let cutoff = now().addingTimeInterval(-Self.heardPacketWindow)
        guard let index = recentPackets.lastIndex(where: {
            $0.date >= cutoff && $0.packet.hopCount == hops && matches($0.packet)
        }) else { return nil }
        let packet = recentPackets.remove(at: index).packet
        return packet.path.hashes.map { Data($0).hexString.uppercased() }
    }

    /// A channel's 1-byte hash as it appears in group packets: the first byte of SHA-256 of its secret.
    static func channelHash(secret: Data) -> UInt8 {
        Array(SHA256.hash(data: secret))[0]
    }
}
