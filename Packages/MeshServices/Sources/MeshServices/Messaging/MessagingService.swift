import Foundation
import MeshCoreKit
import MeshStore
import MeshTools
import Observation

public enum MessagingError: Error, Equatable, Sendable {
    case notConnected
    case unknownConversation
    case messageTooLong(maxBytes: Int)
    case noFreeChannelSlot
    case loginFailed
    case loginTimedOut
}

/// Contacts, channels and messages for the connected radio: syncs on connect, drains queued messages,
/// sends with ACK tracking and retries, and applies reactions.
@MainActor
@Observable
public final class MessagingService: RadioEventHandler {
    /// Store for the connected (or last connected) radio.
    public private(set) var store: RadioStore?
    /// Bumped on every change so views re-read the store.
    public internal(set) var revision = 0
    public private(set) var isSyncing = false
    public internal(set) var lastError: String?
    /// Channel slots the radio offers.
    public private(set) var maxChannels = 8
    /// Conversation on screen; its incoming messages are marked read and don't notify.
    public var activeConversationID: String?
    /// Receives command-line replies from repeaters and rooms (sender prefix hex, text); they aren't chat messages.
    @ObservationIgnored public var onCommandReply: ((String, String) -> Void)?

    @ObservationIgnored private let radio: RadioController
    @ObservationIgnored weak var notifier: (any MessageNotifier)?
    @ObservationIgnored private let storeFactory: (String) throws -> RadioStore
    @ObservationIgnored let now: () -> Date
    @ObservationIgnored private let ackWait: (Double) -> Double
    @ObservationIgnored var session: MeshSession?
    @ObservationIgnored var selfName = ""
    /// First byte of the radio's key: the destination hash of direct messages to us.
    @ObservationIgnored var selfHash: UInt8?
    /// Text packets heard in the RX log recently, so incoming messages can be given the path they took.
    @ObservationIgnored var recentPackets: [HeardPacket] = []
    @ObservationIgnored private var ackTimeouts: [UUID: Task<Void, Never>] = [:]
    /// ACK tags of earlier attempts, by message: each attempt has its own tag, and a late ACK for one still means delivered.
    @ObservationIgnored private var earlierAckTags: [Int: UUID] = [:]
    @ObservationIgnored let loginWaiter = PushWaiter<LoginResult>()
    @ObservationIgnored let blockedNamesKey = "messaging.blockedChannelNames"
    @ObservationIgnored let defaults: UserDefaults

    /// Maximum text bytes per message (frame limit minus headers, with room for the sender name).
    public static let maxDirectBytes = 150
    public static let maxChannelBytes = 130
    /// Attempts for a direct message before it's marked failed; the last one floods.
    public static let maxAttempts = 3

    public init(
        radio: RadioController,
        notifier: (any MessageNotifier)? = nil,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = { Date() },
        ackWait: @escaping (Double) -> Double = { max($0 * 1.5, 3) + 2 },
        storeFactory: @escaping (String) throws -> RadioStore = { try RadioStore(radioKeyHex: $0) }
    ) {
        self.radio = radio
        self.notifier = notifier
        self.defaults = defaults
        self.now = now
        self.ackWait = ackWait
        self.storeFactory = storeFactory
        radio.addHandler(self)
    }

    public func setNotifier(_ notifier: any MessageNotifier) {
        self.notifier = notifier
    }

    func changed() {
        store?.save()
        revision += 1
    }

    // MARK: RadioEventHandler

    public func radioDidConnect(_ info: ConnectionInfo, session: MeshSession) async {
        self.session = session
        // Problems from an earlier connection (or another radio) no longer apply.
        lastError = nil
        selfName = info.selfInfo.name
        selfHash = info.selfInfo.publicKey.bytes.first
        recentPackets.removeAll()
        maxChannels = max(1, info.device.maxChannels ?? 8)
        let key = info.selfInfo.publicKey.hex
        if store?.radioKeyHex != key || radio.target == .simulator {
            do {
                // The simulated radio replays the same demo each connect, so it never keeps history.
                store = radio.target == .simulator ? try RadioStore(radioKeyHex: key, inMemory: true) : try storeFactory(key)
            } catch {
                lastError = "Couldn't open the message store: \(error.readable)"
                return
            }
        }
        isSyncing = true
        await syncContacts()
        await syncChannels()
        await drainMessages()
        isSyncing = false
        changed()
    }

    public func radioDidDisconnect() {
        session = nil
        isSyncing = false
        loginWaiter.cancelAll()
    }

    public func radioDidReceive(_ push: Push, session: MeshSession) async {
        // Pushes can arrive before `radioDidConnect` has opened this radio's store (the controller fans them out
        // separately); applying one then would write another radio's contacts or ACKs into the previous radio's store.
        guard let store, self.session === session else { return }
        if case .rxLog(let entry) = push {
            remember(entry)
            return
        }
        switch push {
        case .messagesWaiting:
            await drainMessages()
        case .newAdvert(let contact):
            let record = upsert(contact, in: store)
            record.lastHeard = now()
            alertIfWatched(record)
        case .advert(let key), .pathUpdated(let key):
            if let contact = try? await session.request(.getContactByKey(key), { response -> Contact? in
                if case .contact(let contact) = response { return contact }
                return nil
            }) {
                let record = upsert(contact, in: store)
                if case .advert = push {
                    record.lastHeard = now()
                    alertIfWatched(record)
                }
            }
        case .contactDeleted(let key):
            store.contact(keyHex: key.hex)?.isOnRadio = false
        case .contactsFull:
            lastError = "The radio's contact list is full. Remove contacts or enable overwriting the oldest."
        case .sendConfirmed(let confirmation):
            let tag = Int(confirmation.ackCode)
            if let message = store.outgoingMessage(ackTag: tag) ?? earlierAckTags[tag].flatMap({ store.message(id: $0) }) {
                earlierAckTags = earlierAckTags.filter { $0.value != message.id }
                message.status = .delivered
                message.roundTripMs = Int(confirmation.roundTripMs)
                ackTimeouts.removeValue(forKey: message.id)?.cancel()
            }
        case .loginSuccess(let result):
            resolveLogin(prefix: result.senderPrefix, with: .success(result))
        case .loginFailed(let prefix):
            resolveLogin(prefix: prefix, with: .failure(MessagingError.loginFailed))
        default:
            return
        }
        changed()
    }

    // MARK: Sync

    public func syncContacts() async {
        guard let session, let store else { return }
        do {
            let list = try await session.getContacts(since: UInt32(clamping: store.metadata.contactsLastModified))
            for contact in list.contacts {
                upsert(contact, in: store)
            }
            store.metadata.contactsLastModified = Int(list.lastModified)
            changed()
        } catch {
            lastError = "Couldn't sync contacts: \(error.readable)"
        }
    }

    public func syncChannels() async {
        guard let session, let store else { return }
        var slots: [ChannelSlot] = []
        for index in 0..<maxChannels {
            do {
                let channel = try await session.getChannel(index: UInt8(index))
                if !channel.name.isEmpty {
                    slots.append(ChannelSlot(index: index, name: channel.name, secret: Data(channel.secret)))
                }
            } catch MeshError.device(.notFound, _) {
                break
            } catch {
                lastError = "Couldn't read channels: \(error.readable)"
                return
            }
        }
        store.replaceChannels(slots)
        changed()
    }

    /// Pops every queued message from the radio.
    public func drainMessages() async {
        guard let session else { return }
        for _ in 0..<200 {
            guard let response = try? await session.syncNextMessage() else { break }
            switch response {
            case .contactMessage(let message): receive(message)
            case .channelMessage(let message): receive(message)
            default: continue
            }
        }
        changed()
    }

    @discardableResult
    func upsert(_ contact: Contact, in store: RadioStore) -> ContactRecord {
        store.upsertContact(keyHex: contact.publicKey.hex) { record in
            record.name = contact.name
            record.typeRaw = Int(contact.type.rawValue)
            record.flags = Int(contact.flags)
            record.outPathLength = Int(contact.outPath?.encodedLength ?? 0xFF)
            record.outPath = Data(contact.outPath?.bytes ?? [])
            record.lastAdvert = Int(contact.lastAdvert)
            record.lastModified = Int(contact.lastModified)
            record.isOnRadio = true
            if contact.hasLocation, contact.latitudeE6 != Int32(record.latitudeE6) || contact.longitudeE6 != Int32(record.longitudeE6) {
                store.addPosition(
                    keyHex: record.keyHex, latitudeE6: Int(contact.latitudeE6), longitudeE6: Int(contact.longitudeE6),
                    at: now(), source: "advert"
                )
            }
            record.latitudeE6 = Int(contact.latitudeE6)
            record.longitudeE6 = Int(contact.longitudeE6)
        }
    }

    private func alertIfWatched(_ record: ContactRecord) {
        if record.alertWhenHeard { notifier?.notifyNodeHeard(name: record.displayName) }
    }
}

// MARK: Sending

extension MessagingService {
    /// Sends text to a conversation and returns the stored message.
    @discardableResult
    public func send(_ text: String, to conversationID: String) async throws -> MessageRecord {
        guard let store else { throw MessagingError.notConnected }
        guard let conversation = ConversationID(conversationID) else { throw MessagingError.unknownConversation }
        let limit = Self.byteLimit(for: conversation)
        guard text.utf8.count <= limit else { throw MessagingError.messageTooLong(maxBytes: limit) }

        let timestamp = UInt32(clamping: Int64(now().timeIntervalSince1970))
        let record = MessageRecord(
            conversationID: conversationID, isOutgoing: true, text: text, senderTimestamp: Int(timestamp),
            receivedAt: now(), status: .sending, reactionHash: MessageFormat.reactionHash(text: text, timestamp: timestamp)
        )
        if case .channel = conversation { record.senderName = selfName }
        store.append(record, preview: "You: \(MessageFormat.displayText(MessageFormat.parseReply(text)?.body ?? text))")
        changed()
        await transmit(record)
        return record
    }

    public static func byteLimit(for conversation: ConversationID) -> Int {
        switch conversation {
        case .direct: maxDirectBytes
        case .channel: maxChannelBytes
        }
    }

    /// Forgets the contact's direct path and resends the message as a flood (the last of the normal attempts).
    public func retryFlood(_ messageID: UUID) async {
        guard let record = store?.message(id: messageID), Self.canRetryFlood(record) else { return }
        ackTimeouts.removeValue(forKey: messageID)?.cancel()
        record.attempt = Self.maxAttempts - 1
        record.status = .sending
        changed()
        await transmit(record)
    }

    /// Resends a failed message as a new attempt.
    public func retry(_ messageID: UUID) async {
        guard let record = store?.message(id: messageID), record.isOutgoing, record.status == .failed else { return }
        record.attempt = 0
        record.status = .sending
        changed()
        await transmit(record)
    }

    private func transmit(_ record: MessageRecord) async {
        guard let session, let conversation = ConversationID(record.conversationID) else {
            record.status = .failed
            changed()
            return
        }
        do {
            switch conversation {
            case .direct(let keyHex):
                guard let key = PublicKey(hex: keyHex) else { throw MessagingError.unknownConversation }
                let contact = store?.contact(keyHex: keyHex)
                if record.attempt == Self.maxAttempts - 1 {
                    // Last try: forget the direct path so the radio floods.
                    try? await session.perform(.resetPath(key))
                    contact?.outPathLength = 0xFF
                    contact?.outPath = Data()
                }
                record.routeHashes = contact.flatMap(Self.pathHashes(of:))
                let info = try await session.sendTextMessage(
                    to: key.prefix, text: record.text, timestamp: UInt32(record.senderTimestamp), attempt: UInt8(record.attempt)
                )
                rememberEarlierAckTag(of: record)
                record.ackTag = Int(info.tag)
                record.status = .sent
                scheduleAckTimeout(for: record.id, after: Double(info.estimatedTimeoutMs) / 1000)
            case .channel(let index):
                try await session.perform(
                    .sendChannelTextMessage(channelIndex: UInt8(index), text: record.text, timestamp: UInt32(record.senderTimestamp))
                )
                record.status = .sent
            }
        } catch {
            record.status = .failed
            lastError = "Couldn't send: \(error.readable)"
        }
        changed()
    }

    private func rememberEarlierAckTag(of record: MessageRecord) {
        guard let tag = record.ackTag else { return }
        if earlierAckTags.count >= 256 { earlierAckTags.removeAll() }
        earlierAckTags[tag] = record.id
    }

    private func scheduleAckTimeout(for messageID: UUID, after seconds: Double) {
        ackTimeouts[messageID]?.cancel()
        let wait = ackWait(seconds)
        ackTimeouts[messageID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            await self?.ackTimedOut(messageID)
        }
    }

    private func ackTimedOut(_ messageID: UUID) async {
        ackTimeouts[messageID] = nil
        guard let record = store?.message(id: messageID), record.status == .sent else { return }
        if record.attempt + 1 < Self.maxAttempts {
            record.attempt += 1
            await transmit(record)
        } else {
            record.status = .failed
            changed()
        }
    }

    /// Reacts to a message with an emoji, in the format other MeshCore apps understand.
    public func react(_ emoji: String, to messageID: UUID) async throws {
        guard let session, let store, let target = store.message(id: messageID),
              let conversation = ConversationID(target.conversationID) else { throw MessagingError.notConnected }
        let timestamp = UInt32(clamping: Int64(now().timeIntervalSince1970))
        switch conversation {
        case .direct(let keyHex):
            guard let key = PublicKey(hex: keyHex) else { throw MessagingError.unknownConversation }
            let text = MessageFormat.directReactionText(
                emoji: emoji, targetText: target.text, targetTimestamp: UInt32(target.senderTimestamp)
            )
            _ = try await session.sendTextMessage(to: key.prefix, text: text, timestamp: timestamp)
        case .channel(let index):
            let text = MessageFormat.channelReactionText(
                emoji: emoji, targetSender: target.senderName ?? selfName,
                targetText: target.text, targetTimestamp: UInt32(target.senderTimestamp)
            )
            try await session.perform(.sendChannelTextMessage(channelIndex: UInt8(index), text: text, timestamp: timestamp))
        }
        target.reactions.append(MessageReaction(emoji: emoji, sender: selfName, isMine: true))
        changed()
    }
}
