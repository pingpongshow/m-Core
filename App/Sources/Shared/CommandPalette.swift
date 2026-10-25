import MeshServices
import SwiftUI

/// ⌘K: jump to any chat, node, tool or setting, or run a common action, by typing.
struct CommandPalette: View {
    @Environment(AppRouter.self) private var router
    @Environment(MessagingService.self) private var messaging
    @Environment(RadioController.self) private var radio
    @Environment(ContactsService.self) private var contacts
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private struct Item: Identifiable {
        let id: String
        let title: String
        let subtitle: String?
        let systemImage: String
        let run: () -> Void
    }

    var body: some View {
        let sections = filteredSections
        NavigationStack {
            List {
                ForEach(sections, id: \.title) { section in
                    Section(section.title) {
                        ForEach(section.items) { item in
                            Button {
                                dismiss()
                                item.run()
                            } label: {
                                Label {
                                    VStack(alignment: .leading) {
                                        Text(item.title).foregroundStyle(.primary)
                                        if let subtitle = item.subtitle {
                                            Text(subtitle).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                } icon: {
                                    Image(systemName: item.systemImage)
                                }
                            }
                        }
                    }
                }
            }
            .overlay {
                if sections.isEmpty { ContentUnavailableView.search(text: query) }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Chats, nodes, tools, settings")
            .navigationTitle("Go to")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var filteredSections: [(title: String, items: [Item])] {
        let all: [(String, [Item])] = [
            ("Actions", actions),
            ("Chats", chats),
            ("Nodes", nodes),
            ("Tools", ToolRoute.allCases.map { route in
                Item(id: "tool.\(route)", title: route.title, subtitle: nil, systemImage: route.systemImage) { router.open(route) }
            }),
            ("Settings", SettingsRoute.allCases.map { route in
                Item(id: "settings.\(route)", title: route.title, subtitle: nil, systemImage: route.systemImage) { router.open(route) }
            }),
            ("Tabs", AppSection.allCases.map { section in
                Item(id: "tab.\(section)", title: section.title, subtitle: nil, systemImage: section.systemImage) {
                    router.selection = section
                }
            }),
        ]
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return all.compactMap { title, items in
            // With no query, only the five most recent chats and nodes are listed.
            let matches = trimmed.isEmpty
                ? Array(items.prefix(title == "Chats" || title == "Nodes" ? 5 : items.count))
                : items.filter {
                    $0.title.localizedCaseInsensitiveContains(trimmed)
                        || ($0.subtitle?.localizedCaseInsensitiveContains(trimmed) ?? false)
                }
            return matches.isEmpty ? nil : (title, matches)
        }
    }

    private var actions: [Item] {
        var items = [
            Item(id: "search", title: "Search chats", subtitle: "⌘F", systemImage: "magnifyingglass") { router.focusSearch() },
        ]
        if radio.isConnected {
            items.append(Item(id: "advert", title: "Send advert", subtitle: "Let nearby nodes know you're here",
                              systemImage: "megaphone") { Task { try? await contacts.sendAdvert(flood: false) } })
            items.append(Item(id: "disconnect", title: "Disconnect radio", subtitle: radio.selfInfo?.name,
                              systemImage: "antenna.radiowaves.left.and.right.slash") { Task { await radio.disconnect() } })
        } else if radio.lastTarget != nil {
            items.append(Item(id: "reconnect", title: "Reconnect radio", subtitle: nil,
                              systemImage: "antenna.radiowaves.left.and.right") { Task { await radio.reconnectToLast() } })
        }
        return items
    }

    private var chats: [Item] {
        _ = messaging.revision
        return (messaging.store?.conversations() ?? [])
            .sorted { $0.lastMessageAt > $1.lastMessageAt }
            .map { conversation in
                Item(id: "chat.\(conversation.id)", title: messaging.displayName(for: conversation.id),
                     subtitle: conversation.lastMessagePreview.isEmpty ? nil : conversation.lastMessagePreview,
                     systemImage: conversation.id.hasPrefix("ch:") ? "number" : "bubble.left") {
                    router.openConversation(conversation.id)
                }
            }
    }

    private var nodes: [Item] {
        (messaging.store?.contacts() ?? [])
            .sorted { $0.lastSeen > $1.lastSeen }
            .map { contact in
                Item(id: "node.\(contact.keyHex)", title: contact.displayName, subtitle: contact.advertType.label,
                     systemImage: "dot.radiowaves.left.and.right") { router.openNode(contact.keyHex) }
            }
    }
}

extension ToolRoute {
    @MainActor @ViewBuilder var destination: some View {
        switch self {
        case .trace: TraceView()
        case .discovery: DiscoveryView()
        case .rxLog: RxLogView()
        case .coverage: CoverageView()
        case .lineOfSight: LineOfSightView()
        case .routeRecorder: RouteRecorderView()
        case .stats: RadioStatsView()
        case .commandLine: LocalCommandLine()
        }
    }
}

/// The connected radio's own command line.
private struct LocalCommandLine: View {
    @Environment(RadioController.self) private var radio

    var body: some View {
        CommandLineView(keyHex: nil, title: radio.selfInfo?.name ?? "Radio")
    }
}

extension SettingsRoute {
    @MainActor @ViewBuilder var destination: some View {
        switch self {
        case .radio: RadioView()
        case .gpsFeed: GPSFeedView()
        case .radioSettings: RadioSettingsView()
        case .channels: ChannelsView()
        case .messages: MessagingSettingsView()
        case .internetMap: InternetMapView()
        case .observer: ObserverSettingsView()
        case .appearance: AppearanceView()
        case .help: HelpView()
        case .about: AboutView()
        }
    }
}
