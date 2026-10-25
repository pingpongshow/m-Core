import MeshServices
import SwiftUI

/// Wraps every window's content: its own router (so iPad windows navigate independently), the shared services,
/// appearance, and the one-time launch work.
struct WindowRoot<Content: View>: View {
    let services: AppServices
    /// Main windows take notification taps; single-chat windows can't show other chats.
    var handlesNotifications = true
    @ViewBuilder let content: () -> Content
    @State private var router = AppRouter()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        content()
            .appAppearance()
            .services(services)
            .environment(router)
            // Menu commands switch tabs, which only main windows have.
            .focusedSceneValue(\.router, handlesNotifications ? router : nil)
            .task {
                #if DEBUG
                // Screenshot and UI checks: `-MCStartTab map` opens a tab, `-MCOpenOfflineMaps YES` the map sheet.
                if let tab = UserDefaults.standard.string(forKey: "MCStartTab"), let section = AppSection(rawValue: tab) {
                    router.selection = section
                }
                #endif
                adoptNotificationTaps()
                await services.launchIfNeeded()
            }
            .onChange(of: scenePhase) {
                // Notification taps open in the window the user is looking at.
                if scenePhase == .active { adoptNotificationTaps() }
            }
            .onChange(of: services.messaging.revision) {
                services.notifier.setBadge(services.messaging.store?.totalUnread ?? 0)
            }
    }

    private func adoptNotificationTaps() {
        guard handlesNotifications else { return }
        services.notifier.onOpen = { [router] in router.openConversation($0) }
        // A tap that launched the app arrives before any window exists to take it.
        if let pending = services.pendingConversationOpen {
            services.pendingConversationOpen = nil
            router.openConversation(pending)
        }
    }
}

/// A chat opened in its own window (iPad).
struct ConversationWindow: View {
    static let id = "conversation"
    let conversationID: String?

    var body: some View {
        NavigationStack {
            if let conversationID {
                ConversationView(conversationID: conversationID)
                    .environment(\.isStandaloneConversation, true)
            } else {
                ContentUnavailableView("No conversation", systemImage: "bubble.left.and.bubble.right")
            }
        }
    }
}

extension AppServices {
    /// Asks for notification permission and reconnects to the last radio, once per app launch.
    func launchIfNeeded() async {
        guard !didLaunch else { return }
        didLaunch = true
        // Side by side: the radio reconnects while the notification prompt is still waiting for an answer.
        async let notifications: Void = notifier.requestAuthorization()
        await radio.reconnectToLast()
        await notifications
    }
}

extension EnvironmentValues {
    /// True inside a single-chat window, which has no tabs to switch to.
    @Entry var isStandaloneConversation = false
}

extension FocusedValues {
    /// The router of the focused window, for menu and keyboard commands.
    @Entry var router: AppRouter?
}

/// Menu-bar and hardware-keyboard commands (iPad).
struct AppCommands: Commands {
    @FocusedValue(\.router) private var router

    var body: some Commands {
        CommandMenu("Go") {
            Group {
                ForEach(Array(AppSection.allCases.enumerated()), id: \.element) { index, section in
                    Button(section.title) { router?.selection = section }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                }
                Divider()
                Button("Search Chats") { router?.focusSearch() }
                    .keyboardShortcut("f", modifiers: .command)
                Button("Command Palette…") { router?.isPaletteOpen = true }
                    .keyboardShortcut("k", modifiers: .command)
            }
            .disabled(router == nil)
        }
    }
}
