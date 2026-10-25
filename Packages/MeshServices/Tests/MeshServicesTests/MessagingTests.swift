import Foundation
import MeshCoreKit
import MeshStore
import Testing
@testable import MeshServices

struct MessageFormatTests {
    @Test func mentions() {
        #expect(MessageFormat.mention("Sim") == "@[Sim]")
        #expect(MessageFormat.mentions(in: "@[Sim] and @[Bob] hi") == ["Sim", "Bob"])
        #expect(MessageFormat.mentions("hey @[sim]", name: "Sim"))
        #expect(!MessageFormat.mentions("hey Sim", name: "Sim"))
    }

    @Test func replies() {
        let text = MessageFormat.replyText(to: "Alice", quoting: "Want to go hiking tomorrow?", reply: "Yes!")
        #expect(text == "@[Alice]\n>Want to go..\nYes!")
        #expect(MessageFormat.parseReply(text) == MessageFormat.Reply(name: "Alice", quote: "Want to go..", body: "Yes!"))
        #expect(MessageFormat.replyText(to: "Bob", quoting: "@[Sim] short", reply: "ok") == "@[Bob]\n>short\nok")
        #expect(MessageFormat.parseReply("just text") == nil)
    }

    @Test func reactionHashMatchesReferenceVector() {
        // SHA-256("hello" ‖ 1_800_000_000 LE) → first 5 bytes → Crockford base32.
        #expect(MessageFormat.reactionHash(text: "hello", timestamp: 1_800_000_000) == "xw0yamwh")
    }

    @Test func reactionsRoundTrip() {
        let channel = MessageFormat.channelReactionText(
            emoji: "👍", targetSender: "Bob", targetText: "hello", targetTimestamp: 1_800_000_000
        )
        #expect(channel == "@[Bob]👍\nxw0yamwh")
        #expect(MessageFormat.parseReaction(channel) == MessageFormat.Reaction(emoji: "👍", targetSender: "Bob", hash: "xw0yamwh"))
        // Emoji-first order from other apps.
        #expect(MessageFormat.parseReaction("❤️@[Bob]\nXW0YAMWH")?.emoji == "❤️")

        let direct = MessageFormat.directReactionText(emoji: "🎉", targetText: "hello", targetTimestamp: 1_800_000_000)
        #expect(MessageFormat.parseReaction(direct) == MessageFormat.Reaction(emoji: "🎉", targetSender: nil, hash: "xw0yamwh"))

        #expect(MessageFormat.parseReaction("hello\nworld123") == nil)
        #expect(MessageFormat.parseReaction("two words\nxw0yamwh") == nil)
    }

    @Test func hashtagSecretMatchesDocs() {
        #expect(MessageFormat.hashtagSecret("#test").hexString == "9cd8fcf22a47333b591d96a2b848b73f")
        #expect(MessageFormat.hashtagSecret("Test") == MessageFormat.hashtagSecret("#test"))
    }

    @Test func locations() {
        let found = MessageFormat.location(in: "Meet me at the trailhead: 37.8651, -119.5383")
        #expect(found?.latitude == 37.8651)
        #expect(found?.longitude == -119.5383)
        #expect(MessageFormat.location(in: "call me at 5.5, 6") == nil)
        #expect(MessageFormat.locationText(latitude: 37.77493, longitude: -122.41942, label: "Here") == "Here: 37.77493, -122.41942")
    }

    @Test func displayTextShowsMentionsPlainly() {
        #expect(MessageFormat.displayText("@[Sim] can you help @[Bob]?") == "@Sim can you help @Bob?")
    }

    @Test func conversationIDs() {
        #expect(ConversationID("dm:AABB") == .direct(keyHex: "AABB"))
        #expect(ConversationID.direct(keyHex: "AABB").description == "dm:aabb")
        #expect(ConversationID("ch:3") == .channel(index: 3))
        #expect(ConversationID("nope") == nil)
    }
}

@MainActor
final class RecordingNotifier: MessageNotifier {
    struct PostedMessage {
        let title: String
        let body: String
        let conversationID: String
        let isMention: Bool
    }

    private(set) var messages: [PostedMessage] = []
    private(set) var nodesHeard: [String] = []

    func notifyMessage(title: String, body: String, conversationID: String, isMention: Bool) {
        messages.append(PostedMessage(title: title, body: body, conversationID: conversationID, isMention: isMention))
    }

    func notifyNodeHeard(name: String) {
        nodesHeard.append(name)
    }
}

@MainActor
struct MessagingServiceTests {
    struct Harness {
        let mock: MockRadio
        let radio: RadioController
        let messaging: MessagingService
        let notifier: RecordingNotifier
    }

    private func connect(_ state: MockRadio.State = MockRadio.demoState) async throws -> Harness {
        let mock = MockRadio(state: state)
        let radio = RadioController(defaults: UserDefaults(suiteName: "msg.\(UUID().uuidString)")!, simulatedRadio: mock)
        let notifier = RecordingNotifier()
        let messaging = MessagingService(
            radio: radio, notifier: notifier,
            defaults: UserDefaults(suiteName: "msg.\(UUID().uuidString)")!,
            ackWait: { _ in 0.05 },
            storeFactory: { try RadioStore(radioKeyHex: $0, inMemory: true) }
        )
        await radio.connect(to: .simulator)
        try await waitUntil { messaging.store != nil && !messaging.isSyncing && messaging.revision > 0 }
        return Harness(mock: mock, radio: radio, messaging: messaging, notifier: notifier)
    }

    private func dm(_ seed: UInt8) -> String {
        ConversationID.direct(keyHex: MockRadio.demoKey(seed).hex).description
    }

    @Test func syncsContactsChannelsAndQueuedMessages() async throws {
        let harness = try await connect()
        let store = try #require(harness.messaging.store)

        #expect(store.contacts().count == 9)
        #expect(store.channels().map(\.name) == ["Public", "#test", "Bay Area"])
        #expect(store.metadata.contactsLastModified > 0)

        let alice = store.messages(conversationID: dm(0x0A))
        #expect(alice.map(\.text) == ["Yeah! Want to go hiking? 🥾"])
        #expect(alice.first?.hops == 2)
        #expect(alice.first?.snr == 3.25)

        let bayArea = store.messages(conversationID: "ch:2")
        #expect(bayArea.first?.senderName == "Carol Diaz")
        #expect(bayArea.first?.text == "@[Sim] can you cover the cleanup this Saturday?")
        #expect(store.conversation(id: "ch:2").mentionCount == 1)
        #expect(store.totalUnread == 4)
        #expect(harness.notifier.messages.count == 4)
        #expect(harness.notifier.messages.contains { $0.isMention && $0.title == "Carol Diaz in Bay Area" })
        #expect(harness.messaging.displayName(for: dm(0x0A)) == "Alice Chen")
        await harness.radio.disconnect()
    }

    @Test func directMessageIsDeliveredWhenAcked() async throws {
        let harness = try await connect()
        let message = try await harness.messaging.send("See you at 9", to: dm(0x14))
        try await waitUntil { message.status == .delivered }
        #expect(message.roundTripMs == 850)
        #expect(harness.mock.current.sentDirectMessages.map(\.text) == ["See you at 9"])
        await harness.radio.disconnect()
    }

    @Test func unackedMessageRetriesThenFloodsThenFails() async throws {
        var state = MockRadio.demoState
        state.autoAck = false
        let harness = try await connect(state)
        let message = try await harness.messaging.send("anyone?", to: dm(0x14))
        try await waitUntil(timeout: .seconds(5)) { message.status == .failed }
        let attempts = harness.mock.current.sentDirectMessages.map(\.attempt)
        #expect(attempts == [0, 1, 2])
        #expect(harness.mock.current.pathResets == [MockRadio.demoKey(0x14)])

        harness.mock.update { $0.autoAck = true }
        await harness.messaging.retry(message.id)
        try await waitUntil { message.status == .delivered }
        await harness.radio.disconnect()
    }

    @Test func channelMessagesAndReactions() async throws {
        let harness = try await connect()
        let store = try #require(harness.messaging.store)
        let sent = try await harness.messaging.send("Hello all", to: "ch:0")
        #expect(sent.status == .sent)
        #expect(sent.senderName == "Sim")
        #expect(harness.mock.current.sentChannelMessages.last?.text == "Hello all")

        // React to Carol's welcome message.
        let welcome = try #require(store.messages(conversationID: "ch:0").first { $0.senderName == "Carol Diaz" })
        try await harness.messaging.react("🎉", to: welcome.id)
        let reactionWire = try #require(harness.mock.current.sentChannelMessages.last?.text)
        #expect(reactionWire.hasPrefix("@[Carol Diaz]🎉\n"))
        #expect(welcome.reactions == [MessageReaction(emoji: "🎉", sender: "Sim", isMine: true)])

        // Someone reacts to our message.
        let incoming = MessageFormat.channelReactionText(
            emoji: "👍", targetSender: "Sim", targetText: "Hello all", targetTimestamp: UInt32(sent.senderTimestamp)
        )
        harness.mock.receive(.channelMessage(ChannelMessage(
            channelIndex: 0, routing: .flood(hops: 1), senderTimestamp: 1, text: "Bob: \(incoming)"
        )))
        try await waitUntil { sent.reactions.count == 1 }
        #expect(sent.reactions.first?.sender == "Bob")
        #expect(store.messages(conversationID: "ch:0").count == 2) // reaction isn't stored as a message
        await harness.radio.disconnect()
    }

    @Test func directReactionAndReply() async throws {
        let harness = try await connect()
        let store = try #require(harness.messaging.store)
        let hiking = try #require(store.messages(conversationID: dm(0x0A)).first)

        try await harness.messaging.react("👍", to: hiking.id)
        #expect(harness.mock.current.sentDirectMessages.last?.text == "👍\n\(hiking.reactionHash)")

        try await harness.messaging.reply("Absolutely", to: hiking.id)
        #expect(harness.mock.current.sentDirectMessages.last?.text == "@[Alice Chen]\n>Yeah! Want..\nAbsolutely")
        await harness.radio.disconnect()
    }

    @Test func activeConversationIsReadAndSilent() async throws {
        let harness = try await connect()
        let conversation = dm(0x14)
        harness.messaging.activeConversationID = conversation
        let before = harness.notifier.messages.count
        harness.mock.receive(.contactMessage(ContactMessage(
            senderPrefix: MockRadio.demoKey(0x14).prefix, routing: .direct, senderTimestamp: 42, text: "I'm here"
        )))
        let store = try #require(harness.messaging.store)
        try await waitUntil { store.messages(conversationID: conversation).count == 1 }
        #expect(store.messages(conversationID: conversation).first?.isRead == true)
        #expect(harness.notifier.messages.count == before)

        // Duplicates from the radio are ignored.
        harness.mock.receive(.contactMessage(ContactMessage(
            senderPrefix: MockRadio.demoKey(0x14).prefix, routing: .direct, senderTimestamp: 42, text: "I'm here"
        )))
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.messages(conversationID: conversation).count == 1)
        await harness.radio.disconnect()
    }

    @Test func mutedAndBlocked() async throws {
        let harness = try await connect()
        let store = try #require(harness.messaging.store)
        harness.messaging.setMuteLevel(.muted, conversationID: "ch:1")
        let before = harness.notifier.messages.count
        harness.mock.receive(.channelMessage(ChannelMessage(
            channelIndex: 1, routing: .flood(hops: 0), senderTimestamp: 7, text: "Zed: quiet"
        )))
        try await waitUntil { store.messages(conversationID: "ch:1").count == 1 }
        #expect(harness.notifier.messages.count == before)

        harness.messaging.setBlocked(true, channelSender: "Zed")
        harness.mock.receive(.channelMessage(ChannelMessage(
            channelIndex: 1, routing: .flood(hops: 0), senderTimestamp: 8, text: "Zed: spam"
        )))
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.messages(conversationID: "ch:1").count == 1)

        store.contact(keyHex: MockRadio.demoKey(0x32).hex)?.isBlocked = true
        harness.mock.receive(.contactMessage(ContactMessage(
            senderPrefix: MockRadio.demoKey(0x32).prefix, routing: .direct, senderTimestamp: 9, text: "blocked"
        )))
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.messages(conversationID: dm(0x32)).isEmpty)
        await harness.radio.disconnect()
    }

    @Test func roomPostsShowTheirAuthor() async throws {
        let harness = try await connect()
        let store = try #require(harness.messaging.store)
        let room = MockRadio.demoKey(0x44)
        let author = MockRadio.demoKey(0x14)
        harness.mock.receive(.contactMessage(ContactMessage(
            senderPrefix: room.prefix, routing: .direct, textType: .signedPlain, senderTimestamp: 11,
            signerPrefix: Array(author.bytes.prefix(4)), text: "Room hello"
        )))
        let conversation = ConversationID.direct(keyHex: room.hex).description
        try await waitUntil { !store.messages(conversationID: conversation).isEmpty }
        #expect(store.messages(conversationID: conversation).first?.senderName == "Bob Martinez")
        await harness.radio.disconnect()
    }

    @Test func roomLogin() async throws {
        let harness = try await connect()
        let room = MockRadio.demoKey(0x44).hex
        let result = try await harness.messaging.login(to: room, password: "password")
        #expect(result.isAdmin)
        await #expect(throws: MessagingError.loginFailed) {
            _ = try await harness.messaging.login(to: room, password: "wrong")
        }
        await harness.radio.disconnect()
    }

    @Test func channelManagement() async throws {
        let harness = try await connect()
        let store = try #require(harness.messaging.store)
        try await harness.messaging.addChannel(name: "#Hiking")
        let hiking = try #require(store.channels().first { $0.name == "#hiking" })
        #expect(hiking.index == 3)
        #expect(hiking.secret == MessageFormat.hashtagSecret("#hiking"))

        try await harness.messaging.addChannel(name: "Family")
        #expect(store.channels().first { $0.name == "Family" }?.secret.count == 16)

        try await harness.messaging.removeChannel(index: 3)
        #expect(!store.channels().contains { $0.name == "#hiking" })
        #expect(harness.mock.current.channels.count == 4)
        await harness.radio.disconnect()
    }

    @Test func advertPushesUpdateContacts() async throws {
        let harness = try await connect()
        let store = try #require(harness.messaging.store)
        let newcomer = Contact(
            publicKey: MockRadio.demoKey(0x77), type: .chat, name: "Newcomer", latitudeE6: 37_700_000, longitudeE6: -122_400_000
        )
        harness.mock.push(.newAdvert(newcomer))
        try await waitUntil { store.contact(keyHex: newcomer.publicKey.hex) != nil }
        #expect(store.contact(keyHex: newcomer.publicKey.hex)?.lastHeard != nil)
        #expect(store.positions(keyHex: newcomer.publicKey.hex).count == 1)

        store.contact(keyHex: MockRadio.demoKey(0x14).hex)?.alertWhenHeard = true
        harness.mock.push(.advert(MockRadio.demoKey(0x14)))
        try await waitUntil { harness.notifier.nodesHeard == ["Bob Martinez"] }

        harness.mock.push(.contactDeleted(MockRadio.demoKey(0x3C)))
        try await waitUntil { store.contact(keyHex: MockRadio.demoKey(0x3C).hex)?.isOnRadio == false }
        await harness.radio.disconnect()
    }

    @Test func tooLongMessagesAreRejected() async throws {
        let harness = try await connect()
        await #expect(throws: MessagingError.messageTooLong(maxBytes: MessagingService.maxChannelBytes)) {
            _ = try await harness.messaging.send(String(repeating: "x", count: 200), to: "ch:0")
        }
        await harness.radio.disconnect()
    }
}
