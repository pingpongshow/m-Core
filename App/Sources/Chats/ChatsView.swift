import MeshDesign
import MeshServices
import MeshStore
import SwiftUI

/// A row in the chat list.
struct ChatSummary: Identifiable, Hashable {
    enum Kind: Hashable {
        case direct
        case room
        case channel
    }

    let id: String
    let title: String
    let kind: Kind
    let avatar: AvatarKind
    let preview: String
    let date: Date?
    let unread: Int
    let mentions: Int
    let isPinned: Bool
    let muteLevel: MuteLevel
    let isFavourite: Bool
}

extension MuteLevel {
    var systemImage: String {
        switch self {
        case .all: "bell"
        case .mentions: "at"
        case .muted: "bell.slash"
        }
    }
}

/// Picker for a chat's notification level, for menus.
struct MuteLevelPicker: View {
    let conversationID: String
    @Environment(MessagingService.self) private var messaging

    var body: some View {
        Picker("Notifications", systemImage: messaging.muteLevel(for: conversationID).systemImage, selection: Binding(
            get: { messaging.muteLevel(for: conversationID) },
            set: { messaging.setMuteLevel($0, conversationID: conversationID) }
        )) {
            ForEach(MuteLevel.allCases, id: \.self) { level in
                Label(level.title, systemImage: level.systemImage).tag(level)
            }
        }
    }
}

enum ChatFilter: String, CaseIterable {
    case all = "All"
    case unread = "Unread"
    case direct = "DMs"
    case channels = "Channels"
    case rooms = "Rooms"

    /// Shown when nothing matches the filter (and there's no search text).
    var emptyTitle: String {
        switch self {
        case .all: "No chats yet"
        case .unread: "No unread chats"
        case .direct: "No direct messages"
        case .channels: "No channels"
        case .rooms: "No rooms"
        }
    }
}

struct ChatsView: View {
    @Environment(MessagingService.self) private var messaging
    @Environment(RadioController.self) private var radio
    @Environment(AppRouter.self) private var router
    @State private var filter: ChatFilter = .all
    @State private var search = ""
    @FocusState private var isSearchFocused: Bool
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @State private var showingNewChat = false
    @State private var showingChannels = false
    /// Set when the list is the sidebar of the iPad split view.
    var selection: Binding<String?>?

    var body: some View {
        let summaries = filtered(Self.summaries(from: messaging))
        AdaptiveList(selection: selection) {
            Section {
                FilterChipBar(options: ChatFilter.allCases, selection: $filter) { $0.rawValue }
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .listRowSeparator(.hidden)
            }
            ForEach(summaries) { summary in
                NavigationLink(value: summary.id) {
                    ChatRow(summary: summary)
                }
                .swipeActions(edge: .leading) {
                    // There's no "mark as unread": the store only clears unread counts.
                    if summary.unread > 0 {
                        Button("Read", systemImage: "envelope.open") {
                            messaging.markRead(summary.id)
                        }
                        .tint(MCColor.accentFill)
                    }
                    Button(summary.isPinned ? "Unpin" : "Pin", systemImage: summary.isPinned ? "pin.slash" : "pin") {
                        messaging.setPinned(!summary.isPinned, conversationID: summary.id)
                    }
                    .tint(MCColor.warning)
                }
                .swipeActions(edge: .trailing) {
                    if summary.kind != .channel {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            messaging.deleteConversation(summary.id)
                        }
                        // The app-wide accent tint would otherwise turn it blue.
                        .tint(MCColor.critical)
                    }
                    let isQuiet = summary.muteLevel != .all
                    Button(isQuiet ? "Unmute" : "Mute", systemImage: isQuiet ? "bell" : "bell.slash") {
                        messaging.setMuteLevel(isQuiet ? .all : .muted, conversationID: summary.id)
                    }
                    .tint(.gray)
                }
                .contextMenu {
                    if summary.unread > 0 {
                        Button("Mark as read", systemImage: "envelope.open") {
                            messaging.markRead(summary.id)
                        }
                    }
                    Button(summary.isPinned ? "Unpin" : "Pin", systemImage: summary.isPinned ? "pin.slash" : "pin") {
                        messaging.setPinned(!summary.isPinned, conversationID: summary.id)
                    }
                    MuteLevelPicker(conversationID: summary.id)
                        .pickerStyle(.menu)
                    if supportsMultipleWindows {
                        Button("Open in New Window", systemImage: "macwindow.badge.plus") {
                            openWindow(id: ConversationWindow.id, value: summary.id)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $search, prompt: "Search conversations")
        .searchFocused($isSearchFocused)
        .onChange(of: router.searchFocusRequest) { isSearchFocused = true }
        .navigationTitle("Chats")
        .navigationDestination(for: String.self) { ConversationView(conversationID: $0) }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { ConnectionButton() }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Channels", systemImage: "number") { showingChannels = true }
                Button("New chat", systemImage: "square.and.pencil") { showingNewChat = true }
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
        .sheet(isPresented: $showingNewChat) {
            NewChatSheet { router.openConversation($0) }
        }
        .sheet(isPresented: $showingChannels) {
            NavigationStack { ChannelsView(showsDoneButton: true) }
        }
        .overlay {
            if messaging.store == nil, radio.isConnected, let error = messaging.lastError {
                ContentUnavailableView("Couldn't open chats", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if messaging.store == nil {
                ContentUnavailableView {
                    Label("No radio", systemImage: "antenna.radiowaves.left.and.right.slash")
                } description: {
                    Text("Connect a radio in Settings → Radio to start chatting.")
                }
            } else if summaries.isEmpty, !search.isEmpty {
                ContentUnavailableView.search(text: search)
            } else if summaries.isEmpty {
                ContentUnavailableView(filter.emptyTitle, systemImage: "bubble.left.and.bubble.right")
            }
        }
    }

    private func filtered(_ summaries: [ChatSummary]) -> [ChatSummary] {
        summaries.filter { summary in
            let matchesFilter = switch filter {
            case .all: true
            case .unread: summary.unread > 0
            case .direct: summary.kind == .direct
            case .channels: summary.kind == .channel
            case .rooms: summary.kind == .room
            }
            return matchesFilter && (search.isEmpty || summary.title.localizedCaseInsensitiveContains(search)
                || summary.preview.localizedCaseInsensitiveContains(search))
        }
    }

    /// Conversations with messages, plus every channel so you can post to an empty one.
    static func summaries(from messaging: MessagingService) -> [ChatSummary] {
        _ = messaging.revision
        guard let store = messaging.store else { return [] }
        var seen = Set<String>()
        var result: [ChatSummary] = []
        let conversations = store.conversations()
        // One fetch each for contacts and channels, rather than one per conversation on every change.
        let contacts = Dictionary(store.contacts().map { ($0.keyHex, $0) }, uniquingKeysWith: { first, _ in first })
        let channels = store.channels()
        let channelsByIndex = Dictionary(channels.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
        // Channels without messages can still have a mute level set.
        let muteLevels = Dictionary(conversations.map { ($0.id, $0.muteLevel) }, uniquingKeysWith: { first, _ in first })

        for conversation in conversations where conversation.lastMessageAt > .distantPast {
            guard let summary = summary(for: conversation, contacts: contacts, channels: channelsByIndex) else { continue }
            seen.insert(conversation.id)
            result.append(summary)
        }
        for channel in channels {
            let id = ConversationID.channel(index: channel.index).description
            guard !seen.contains(id) else { continue }
            result.append(ChatSummary(
                id: id, title: channel.name, kind: .channel, avatar: channel.avatarKind, preview: channel.kindText,
                date: nil, unread: 0, mentions: 0, isPinned: false, muteLevel: muteLevels[id] ?? .all, isFavourite: false
            ))
        }
        return result.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            return (lhs.date ?? .distantPast) > (rhs.date ?? .distantPast)
        }
    }

    private static func summary(
        for conversation: ConversationRecord, contacts: [String: ContactRecord], channels: [Int: ChannelRecord]
    ) -> ChatSummary? {
        let id = conversation.id
        switch ConversationID(id) {
        case .direct(let keyHex):
            let contact = contacts[keyHex.lowercased()]
            let isRoom = contact?.advertType == .room
            // Same fallback as MessagingService.displayName(for:).
            let title = contact?.displayName ?? keyHex.prefix(12).uppercased()
            return ChatSummary(
                id: id, title: title, kind: isRoom ? .room : .direct,
                avatar: contact?.avatarKind ?? .contact, preview: conversation.lastMessagePreview,
                date: conversation.lastMessageAt, unread: conversation.unreadCount, mentions: conversation.mentionCount,
                isPinned: conversation.isPinned, muteLevel: conversation.muteLevel, isFavourite: contact?.isFavourite ?? false
            )
        case .channel(let index):
            guard let channel = channels[index] else { return nil }
            return ChatSummary(
                id: id, title: channel.name, kind: .channel, avatar: channel.avatarKind, preview: conversation.lastMessagePreview,
                date: conversation.lastMessageAt, unread: conversation.unreadCount, mentions: conversation.mentionCount,
                isPinned: conversation.isPinned, muteLevel: conversation.muteLevel, isFavourite: false
            )
        case nil:
            return nil
        }
    }
}

struct ChatRow: View {
    let summary: ChatSummary

    var body: some View {
        HStack(spacing: MCSpacing.m) {
            AvatarView(name: summary.title, kind: summary.avatar)
            VStack(alignment: .leading, spacing: MCSpacing.xxs) {
                HStack(spacing: MCSpacing.xs) {
                    Text(summary.title).font(.headline).lineLimit(1)
                    Spacer(minLength: MCSpacing.xs)
                    if summary.isFavourite || summary.isPinned {
                        Image(systemName: summary.isPinned ? "pin.fill" : "star.fill")
                            .font(.caption)
                            .foregroundStyle(MCColor.warning)
                            .accessibilityLabel(summary.isPinned ? "Pinned" : "Favourite")
                    }
                    if summary.muteLevel != .all {
                        Image(systemName: summary.muteLevel.systemImage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(summary.muteLevel.title)
                    }
                    if let date = summary.date {
                        Text(date.chatListText()).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                HStack(alignment: .top) {
                    Text(MessageText.plainPreview(summary.preview))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer(minLength: MCSpacing.xs)
                    if summary.mentions > 0 { CountBadge(.mention) }
                    if summary.unread > 0 { CountBadge(.unread(summary.unread)) }
                }
            }
            // Separators start under the name for every row, not under a contact's initials.
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        }
        .padding(.vertical, MCSpacing.xxs)
        .accessibilityElement(children: .combine)
    }
}
