import MeshDesign
import MeshMaps
import MeshServices
import SwiftUI

struct RootView: View {
    @Environment(AppRouter.self) private var router
    @Environment(MessagingService.self) private var messaging
    @State private var pendingLink: MeshLink?

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.selection) {
            Tab(AppSection.chats.title, systemImage: AppSection.chats.systemImage, value: .chats) {
                ListDetailTab(path: $router.chatPath) { ChatsView(selection: $0) } detail: {
                    ConversationView(conversationID: $0)
                } empty: {
                    ContentUnavailableView("No chat selected", systemImage: "bubble.left.and.bubble.right",
                                           description: Text("Choose a chat from the list."))
                }
            }
            .badge(unreadCount)
            Tab(AppSection.nodes.title, systemImage: AppSection.nodes.systemImage, value: .nodes) {
                ListDetailTab(path: $router.nodePath) { NodesView(selection: $0) } detail: {
                    NodeDetailView(keyHex: $0)
                } empty: {
                    ContentUnavailableView("No node selected", systemImage: "dot.radiowaves.left.and.right",
                                           description: Text("Choose a contact, repeater, room or sensor."))
                }
            }
            Tab(AppSection.map.title, systemImage: AppSection.map.systemImage, value: .map) {
                NavigationStack { MapScreen() }
            }
            Tab(AppSection.tools.title, systemImage: AppSection.tools.systemImage, value: .tools) {
                NavigationStack(path: $router.toolsPath) {
                    ToolsView().navigationDestination(for: ToolRoute.self) { $0.destination }
                }
            }
            Tab(AppSection.settings.title, systemImage: AppSection.settings.systemImage, value: .settings) {
                NavigationStack(path: $router.settingsPath) {
                    SettingsView().navigationDestination(for: SettingsRoute.self) { $0.destination }
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tint(MCColor.accent)
        // Dropping a meshcore:// contact or channel link anywhere offers to import it.
        .dropDestination(for: URL.self) { urls, _ in
            guard let link = urls.lazy.compactMap(MeshLink.init(url:)).first else { return false }
            pendingLink = link
            return true
        }
        .onOpenURL { url in
            if url.isFileURL {
                router.importMapFile(url)
            } else {
                pendingLink = MeshLink(url: url)
            }
        }
        .sheet(isPresented: $router.isPaletteOpen) { CommandPalette() }
        .sheet(item: $pendingLink) { link in
            LinkImportSheet(link: link)
        }
    }

    private var unreadCount: Int {
        _ = messaging.revision
        return messaging.store?.totalUnread ?? 0
    }
}

/// Handles `meshcore://` links opened from QR codes or messages.
struct LinkImportSheet: View {
    let link: MeshLink

    var body: some View {
        switch link {
        case let .channel(name, secretHex):
            AddChannelSheet(prefilledName: name, prefilledSecretHex: secretHex)
        case .contact:
            ContactImportSheet(link: link)
        }
    }
}

extension MeshLink: Identifiable {
    var id: String { url.absoluteString }
}

struct SettingsView: View {
    @Environment(RadioController.self) private var radio
    @Environment(ObserverService.self) private var observer
    @Environment(GPSFeedService.self) private var gpsFeed

    var body: some View {
        List {
            Section {
                NavigationLink {
                    RadioView()
                } label: {
                    LabeledContent {
                        StatusPill(connection: radio.status)
                    } label: {
                        Label("Radio", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }
                NavigationLink {
                    GPSFeedView()
                } label: {
                    LabeledContent {
                        // Refreshed so "synced 12 s ago" doesn't go stale while Settings is open.
                        TimelineView(.periodic(from: .now, by: 5)) { context in
                            StatusPill(gps: gpsFeed.displayStatus(now: context.date))
                        }
                    } label: {
                        Label("GPS Feed", systemImage: "location.fill")
                    }
                }
            }
            Section {
                NavigationLink {
                    RadioSettingsView()
                } label: {
                    Label("Radio settings", systemImage: "slider.horizontal.3")
                }
                NavigationLink {
                    ChannelsView()
                } label: {
                    Label("Channels", systemImage: "number")
                }
                NavigationLink {
                    MessagingSettingsView()
                } label: {
                    Label("Messages", systemImage: "bubble.left.and.text.bubble.right")
                }
            }
            Section {
                OfflineMapsSettingsLink()
                NavigationLink {
                    InternetMapView()
                } label: {
                    Label("Internet Map", systemImage: "globe")
                }
                NavigationLink {
                    ObserverSettingsView()
                } label: {
                    LabeledContent {
                        Text(observer.settings.isEnabled ? "On" : "Off")
                    } label: {
                        Label("Observer uplink", systemImage: "antenna.radiowaves.left.and.right.circle")
                    }
                }
            }
            Section {
                NavigationLink {
                    AppearanceView()
                } label: {
                    Label("Appearance", systemImage: "circle.lefthalf.filled")
                }
                NavigationLink {
                    HelpView()
                } label: {
                    Label("Help", systemImage: "questionmark.circle")
                }
                NavigationLink {
                    AboutView()
                } label: {
                    Label("About m-Core", systemImage: "info.circle")
                }
            }
            #if DEBUG
            Section("Developer") {
                NavigationLink {
                    DesignGalleryView()
                } label: {
                    Label("Design Gallery", systemImage: "paintpalette")
                }
            }
            #endif
            Section {
                LabeledContent("Version", value: Bundle.main.versionString)
            }
        }
        .navigationTitle("Settings")
    }
}

#Preview {
    let services = AppServices()
    RootView()
        .services(services)
        .environment(AppRouter())
}

/// Settings row that opens the offline map manager.
private struct OfflineMapsSettingsLink: View {
    @Environment(OfflineMapStore.self) private var offlineMaps
    @Environment(AppRouter.self) private var router
    @Environment(\.colorScheme) private var colorScheme
    @State private var style = MapStyleProvider()
    @State private var isPresented = false

    var body: some View {
        Button {
            style.update(areas: offlineMaps.mapSourceURLs, dark: colorScheme == .dark)
            isPresented = true
        } label: {
            // Styled like the navigation rows around it: accent icon, plain title, grey value.
            LabeledContent {
                Text(offlineMaps.areas.isEmpty ? "None" : offlineMaps.totalBytes.formatted(.byteCount(style: .file)))
                    .foregroundStyle(Color.secondary)
            } label: {
                Label {
                    Text("Offline maps").foregroundStyle(Color.primary)
                } icon: {
                    Image(systemName: "map")
                }
            }
        }
        .sheet(isPresented: $isPresented) {
            OfflineMapsView(styleURL: style.styleURL) { _ in
                isPresented = false
                router.selection = .map
            }
        }
    }
}
