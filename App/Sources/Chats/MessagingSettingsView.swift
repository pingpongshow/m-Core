import MeshDesign
import MeshServices
import SwiftUI

/// Settings → Messages: link previews, and any live location shares that are running.
struct MessagingSettingsView: View {
    @AppStorage(MessagingSettings.linkPreviewsKey) private var linkPreviews = true
    @Environment(MessagingService.self) private var messaging
    @Environment(LiveLocationService.self) private var liveLocation

    var body: some View {
        Form {
            Section {
                Toggle("Link previews", isOn: $linkPreviews)
            } footer: {
                Text("""
                Shows a card with the page title and picture for links in messages, and shows image links inline. \
                This phone fetches them from the internet when the message appears, never for blocked contacts. \
                Turn off to keep chats completely offline.
                """)
            }

            Section {
                if liveLocation.shares.isEmpty {
                    Text("Not sharing").foregroundStyle(.secondary)
                } else {
                    ForEach(liveLocation.shares.values.sorted { $0.expiresAt < $1.expiresAt }, id: \.conversationID) { share in
                        HStack {
                            VStack(alignment: .leading, spacing: MCSpacing.xxs) {
                                Text(messaging.displayName(for: share.conversationID))
                                Text(timerInterval: Date.now...max(Date.now, share.expiresAt), countsDown: true)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Stop", role: .destructive) { liveLocation.stop(conversationID: share.conversationID) }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            } header: {
                Text("Live location")
            } footer: {
                Text("Start sharing from the + menu in a chat. Updates go out when you move 50 m, at least every 2 minutes.")
            }
        }
        .navigationTitle("Messages")
    }
}
