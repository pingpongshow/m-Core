import MeshCoreKit
import MeshDesign
import MeshServices
import MeshStore
import SwiftUI

/// Pick a contact, room or channel to message.
struct NewChatSheet: View {
    @Environment(MessagingService.self) private var messaging
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    let onSelect: (String) -> Void

    var body: some View {
        NavigationStack {
            List {
                let store = messaging.store
                let channels = (store?.channels() ?? []).filter(matches)
                if !channels.isEmpty {
                    Section("Channels") {
                        ForEach(channels, id: \.index) { channel in
                            row(title: channel.name, subtitle: channel.kindText, avatar: channel.avatarKind) {
                                select(ConversationID.channel(index: channel.index).description)
                            }
                        }
                    }
                }
                let contacts = (store?.contacts() ?? [])
                    .filter { [.chat, .room].contains($0.advertType) && !$0.isBlocked && matches($0) }
                    .sorted { ($0.isFavourite ? 0 : 1, $0.displayName) < ($1.isFavourite ? 0 : 1, $1.displayName) }
                if !contacts.isEmpty {
                    Section("Contacts") {
                        ForEach(contacts, id: \.keyHex) { contact in
                            row(
                                title: contact.displayName,
                                subtitle: contact.advertType == .room ? "Room server" : contact.hopsText,
                                avatar: contact.avatarKind
                            ) {
                                select(ConversationID.direct(keyHex: contact.keyHex).description)
                            }
                        }
                    }
                }
            }
            .searchable(text: $search)
            .navigationTitle("New Chat")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func matches(_ channel: ChannelRecord) -> Bool {
        search.isEmpty || channel.name.localizedCaseInsensitiveContains(search)
    }

    private func matches(_ contact: ContactRecord) -> Bool {
        search.isEmpty || contact.displayName.localizedCaseInsensitiveContains(search)
    }

    private func row(title: String, subtitle: String, avatar: AvatarKind, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: MCSpacing.m) {
                AvatarView(name: title, kind: avatar, size: 36)
                VStack(alignment: .leading) {
                    Text(title).foregroundStyle(Color.primary)
                    // Color.secondary: in a button, `.secondary` is a shade of the tint.
                    Text(subtitle).font(.caption).foregroundStyle(Color.secondary)
                }
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            }
        }
    }

    private func select(_ conversationID: String) {
        dismiss()
        onSelect(conversationID)
    }
}
