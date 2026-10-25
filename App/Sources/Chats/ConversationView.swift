import MeshCoreKit
import MeshDesign
import MeshServices
import MeshStore
import SwiftUI

struct ConversationView: View {
    let conversationID: String
    @Environment(MessagingService.self) private var messaging
    @Environment(LiveLocationService.self) private var liveLocation
    @Environment(PositionRequestService.self) private var positions
    @Environment(AppRouter.self) private var router
    /// In a single-chat window there are no tabs, so actions that open Nodes or the Map are hidden.
    @Environment(\.isStandaloneConversation) private var isStandalone
    @Environment(\.scenePhase) private var scenePhase
    /// Between onAppear and onDisappear. A chat left open under another tab stays alive but isn't visible.
    @State private var isVisible = false
    @AppStorage(MessagingSettings.linkPreviewsKey) private var linkPreviews = true
    @State private var draft = ""
    @State private var replyTarget: MessageRecord?
    @State private var errorText: String?
    @State private var showingRoomLogin = false
    @State private var isSending = false
    /// False while scrolled up from the newest message; shows the jump-to-latest button.
    @State private var isAtBottom = true
    /// Messages that arrived while scrolled up.
    @State private var newWhileAway = 0

    private var conversation: ConversationID? { ConversationID(conversationID) }

    /// Messages from senders who aren't contacts are filed under a short key prefix; the radio needs the full key
    /// to send a direct message.
    private var canReply: Bool {
        if case .direct(let keyHex) = conversation { return keyHex.count == 64 }
        return true
    }
    private static let bottomID = "bottom"

    var body: some View {
        let messages = currentMessages
        let blockedNames = messaging.blockedChannelNames
        // Looked up once per update and handed to every row, instead of a store fetch per row.
        let contact = directContact
        let isRoom = contact?.advertType == .room
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: MCSpacing.s) {
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        if index == 0 || !Calendar.current.isDate(messages[index - 1].receivedAt, inSameDayAs: message.receivedAt) {
                            Text(message.receivedAt.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.top, MCSpacing.m)
                                .accessibilityAddTraits(.isHeader)
                        }
                        row(for: message, contact: contact, isRoom: isRoom, blockedNames: blockedNames)
                            .id(message.id)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding(.horizontal, MCSpacing.l)
                .padding(.bottom, MCSpacing.s)
            }
            .defaultScrollAnchor(.bottom)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                // visibleRect includes the insets (and, for a short chat, the top inset that pins it to the bottom).
                let visibleBottom = geometry.visibleRect.maxY - geometry.contentInsets.bottom
                return visibleBottom >= geometry.contentSize.height - 80
            } action: { _, atBottom in
                isAtBottom = atBottom
                if atBottom { newWhileAway = 0 }
            }
            .overlay(alignment: .bottomTrailing) {
                if !isAtBottom {
                    JumpToLatestButton(unread: newWhileAway) {
                        withAnimation { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                    }
                    .padding(MCSpacing.l)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.snappy, value: isAtBottom)
            .onChange(of: messages.count) { oldCount, newCount in
                if isOnScreen { messaging.markRead(conversationID) }
                guard newCount > oldCount else { return }
                let added = messages.suffix(newCount - oldCount)
                if isAtBottom || added.contains(where: \.isOutgoing) {
                    withAnimation { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                } else {
                    newWhileAway += added.filter { !$0.isOutgoing }.count
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { banners(contact: contact) }
        .safeAreaInset(edge: .bottom) {
            if canReply {
                Composer(
                    draft: $draft,
                    byteLimit: conversation.map(MessagingService.byteLimit(for:)) ?? MessagingService.maxDirectBytes,
                    placeholder: placeholder(isRoom: isRoom),
                    replyTarget: $replyTarget,
                    isSending: isSending,
                    errorText: errorText,
                    onSend: send,
                    onSendLocation: sendLocation,
                    isSharingLiveLocation: liveShare != nil,
                    onStartLiveLocation: { liveLocation.start(conversationID: conversationID, length: $0) },
                    onStopLiveLocation: { liveLocation.stop(conversationID: conversationID) },
                    onRequestPosition: positionContactKey(contact).map { key in { requestPosition(from: key) } }
                )
            } else {
                Label("This sender isn't in your contacts, so you can't reply yet. Their advert will add them when it's heard.",
                      systemImage: "person.crop.circle.badge.questionmark")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
            }
        }
        .navigationTitle(messaging.displayName(for: conversationID))
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(messaging.displayName(for: conversationID)).font(.headline)
                    Text(subtitle(contact: contact)).font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
            if isRoom {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Log in", systemImage: "person.badge.key") { showingRoomLogin = true }
                }
            }
            if case .direct(let keyHex) = conversation, !isRoom, !isStandalone {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Contact", systemImage: "info.circle") { router.openNode(keyHex) }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Notifications", systemImage: messaging.muteLevel(for: conversationID).systemImage) {
                    MuteLevelPicker(conversationID: conversationID)
                        .pickerStyle(.inline)
                }
            }
        }
        .sheet(isPresented: $showingRoomLogin) {
            if case .direct(let keyHex) = conversation {
                RemoteLoginSheet(keyHex: keyHex, title: messaging.displayName(for: conversationID))
            }
        }
        .onAppear {
            isVisible = true
            updateActiveConversation()
            draft = messaging.store?.conversation(id: conversationID).draft ?? ""
        }
        .onDisappear {
            isVisible = false
            updateActiveConversation()
            messaging.saveDraft(draft, conversationID: conversationID)
        }
        .onChange(of: scenePhase) {
            updateActiveConversation()
            if scenePhase == .background { messaging.saveDraft(draft, conversationID: conversationID) }
        }
    }

    /// Visible in the foreground: only then do new messages count as read (and skip notifications).
    private var isOnScreen: Bool { isVisible && scenePhase == .active }

    /// Tells the messaging service whether this chat is being read, and marks it read when it is.
    private func updateActiveConversation() {
        if isOnScreen {
            messaging.activeConversationID = conversationID
            messaging.markRead(conversationID)
        } else if messaging.activeConversationID == conversationID {
            messaging.activeConversationID = nil
        }
    }

    private func row(for message: MessageRecord, contact: ContactRecord?, isRoom: Bool, blockedNames: Set<String>) -> some View {
        let isGroup: Bool = if case .channel = conversation { true } else { isRoom }
        let route = isStandalone ? nil : routeRequest(for: message, contact: contact)
        return MessageRow(
            message: message,
            showsSender: isGroup,
            showsLinkPreview: linkPreviews && !isFromBlockedSender(message, contact: contact, blockedNames: blockedNames),
            onReact: { emoji in react(emoji, to: message) },
            onReply: { replyTarget = message },
            onRetry: { Task { await messaging.retry(message.id) } },
            onShowLocation: nil,
            onShowPath: route.map { route in { router.showRoute(route) } },
            onRetryFlood: MessagingService.canRetryFlood(message) ? { Task { await messaging.retryFlood(message.id) } } : nil
        )
    }

    @ViewBuilder private func banners(contact: ContactRecord?) -> some View {
        let isRequestingPosition = positionContactKey(contact).map { positions.pending.contains($0) } ?? false
        if liveShare != nil || isRequestingPosition {
            VStack(spacing: MCSpacing.xs) {
                if let share = liveShare {
                    LiveLocationBanner(share: share, error: liveLocation.lastError) { liveLocation.stop(conversationID: conversationID) }
                }
                if isRequestingPosition {
                    HStack(spacing: MCSpacing.s) {
                        ProgressView()
                        Text("Asking \(messaging.displayName(for: conversationID)) for a position…").font(.footnote)
                        Spacer()
                    }
                    .padding(.horizontal, MCSpacing.m)
                    .padding(.vertical, MCSpacing.s)
                    .mcFloatingSurface(in: RoundedRectangle(cornerRadius: MCRadius.control, style: .continuous))
                }
            }
            .padding(.horizontal, MCSpacing.m)
            .padding(.top, MCSpacing.xs)
        }
    }

    private var currentMessages: [MessageRecord] {
        _ = messaging.revision
        return messaging.store?.messages(conversationID: conversationID) ?? []
    }

    private var liveShare: LiveLocationService.Share? {
        liveLocation.share(for: conversationID)
    }

    /// The contact at the other end of a direct chat (also a room server).
    private var directContact: ContactRecord? {
        _ = messaging.revision
        guard case .direct(let keyHex) = conversation else { return nil }
        return messaging.store?.contact(keyHex: keyHex)
    }

    /// The contact to ask for a position: direct messages with chat contacts only.
    private func positionContactKey(_ contact: ContactRecord?) -> String? {
        guard let contact, contact.advertType == .chat else { return nil }
        return contact.keyHex
    }

    private func placeholder(isRoom: Bool) -> String {
        switch conversation {
        case .channel(let index):
            messaging.store?.channel(index: index)?.kindText ?? "Channel"
        default:
            isRoom ? "Post to room" : "Direct Message"
        }
    }

    private func subtitle(contact: ContactRecord?) -> String {
        switch conversation {
        case .channel(let index):
            return messaging.store?.channel(index: index)?.kindText ?? "Channel"
        case .direct:
            guard let contact else { return "Unknown contact" }
            if contact.advertType == .room { return "Room server" }
            return contact.outPathHashes == nil ? "Flood" : "Direct · \(contact.hopsText)"
        case nil:
            return ""
        }
    }
}

// MARK: Routes and actions

extension ConversationView {
    /// Link previews are never fetched for messages from blocked contacts or channel senders.
    private func isFromBlockedSender(_ message: MessageRecord, contact: ContactRecord?, blockedNames: Set<String>) -> Bool {
        guard !message.isOutgoing, let store = messaging.store else { return false }
        switch conversation {
        case .direct(let keyHex):
            if contact?.isBlocked == true { return true }
            if let author = message.senderKeyHex, author != keyHex, store.contact(prefixHex: author)?.isBlocked == true { return true }
            return false
        case .channel:
            return message.senderName.map { blockedNames.contains($0) } ?? false
        case nil:
            return false
        }
    }

    /// The route to draw for "Show path on map", with hops ordered from our radio outwards; nil when it isn't known.
    private func routeRequest(for message: MessageRecord, contact: ContactRecord?) -> MapRouteRequest? {
        guard message.kind == .mesh, let store = messaging.store else { return nil }
        // Incoming routes are stored in travel order (sender first); a hop count of 0 means heard directly.
        let heard: [String]? = message.routeHashes.map { Array($0.reversed()) } ?? (message.hops == 0 ? [] : nil)
        let hashes: [String]?
        let endpoint: ContactRecord?
        switch conversation {
        case .direct:
            endpoint = contact
            if message.isOutgoing {
                hashes = message.routeHashes ?? contact.flatMap(MessagingService.pathHashes(of:))
            } else {
                // Arrived along a direct path: the contact's path, seen from our side.
                hashes = heard ?? (message.hops == nil ? contact.flatMap(MessagingService.pathHashes(of:)) : nil)
            }
        case .channel:
            guard !message.isOutgoing else { return nil }
            endpoint = message.senderName.flatMap { store.contact(named: $0) }
            hashes = heard
        case nil:
            return nil
        }
        guard let hashes, !(hashes.isEmpty && endpoint == nil) else { return nil }
        let name = endpoint?.displayName ?? message.senderName ?? messaging.displayName(for: conversationID)
        return MapRouteRequest(
            hopHashes: hashes, endpointKeyHex: endpoint?.keyHex,
            title: message.isOutgoing ? "Path to \(name)" : "Path from \(name)"
        )
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isSending = true
        let target = replyTarget
        Task {
            defer { isSending = false }
            do {
                if let target {
                    try await messaging.reply(text, to: target.id)
                } else {
                    try await messaging.send(text, to: conversationID)
                }
                // Keep anything typed while the message was going out.
                if draft.trimmingCharacters(in: .whitespacesAndNewlines) == text { draft = "" }
                if replyTarget?.id == target?.id { replyTarget = nil }
                errorText = nil
                messaging.saveDraft(draft, conversationID: conversationID)
            } catch MessagingError.messageTooLong(let maxBytes) {
                errorText = "Too long: messages can be up to \(maxBytes) bytes."
            } catch {
                errorText = "Couldn't send: \(errorMessage(error))"
            }
        }
    }

    private func sendLocation() {
        Task {
            guard let location = await PhoneLocation.current() else {
                errorText = "Couldn't get your location."
                return
            }
            let text = MessageFormat.locationText(
                latitude: location.coordinate.latitude, longitude: location.coordinate.longitude, label: "My location"
            )
            do {
                try await messaging.send(text, to: conversationID)
                errorText = nil
            } catch {
                errorText = "Couldn't send: \(errorMessage(error))"
            }
        }
    }

    private func requestPosition(from keyHex: String) {
        Task {
            do {
                try await positions.requestPosition(from: keyHex)
                errorText = nil
            } catch {
                errorText = "Couldn't request a position: \(errorMessage(error))"
            }
        }
    }

    private func react(_ emoji: String, to message: MessageRecord) {
        Task {
            do {
                try await messaging.react(emoji, to: message.id)
            } catch {
                errorText = "Couldn't react: \(errorMessage(error))"
            }
        }
    }
}
