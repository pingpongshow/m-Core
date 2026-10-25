import MeshDesign
import SwiftUI

struct RootView: View {
    @State private var selection: AppSection = .chats

    var body: some View {
        TabView(selection: $selection) {
            ForEach(AppSection.allCases) { section in
                Tab(section.title, systemImage: section.systemImage, value: section) {
                    NavigationStack {
                        screen(for: section)
                    }
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tint(MCColor.accent)
    }

    @ViewBuilder
    private func screen(for section: AppSection) -> some View {
        switch section {
        case .settings:
            SettingsView()
        default:
            PlaceholderScreen(section: section)
        }
    }
}

/// Stand-in for sections that later phases build.
struct PlaceholderScreen: View {
    let section: AppSection

    var body: some View {
        ContentUnavailableView {
            Label(section.title, systemImage: section.systemImage)
        } description: {
            if let phase = section.plannedPhase {
                Text("Arrives in Phase \(phase).")
            }
        }
        .navigationTitle(section.title)
    }
}

struct SettingsView: View {
    var body: some View {
        List {
            Section("Developer") {
                NavigationLink {
                    DesignGalleryView()
                } label: {
                    Label("Design Gallery", systemImage: "paintpalette")
                }
            }
            Section {
                LabeledContent("Version", value: Bundle.main.versionString)
            }
        }
        .navigationTitle("Settings")
    }
}

private extension Bundle {
    var versionString: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

#Preview {
    RootView()
}
