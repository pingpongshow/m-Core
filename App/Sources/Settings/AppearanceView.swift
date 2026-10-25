import SwiftUI
import UIKit

/// App-wide look: light/dark override and a high-contrast option.
enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "Match system"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum AppearanceKeys {
    static let theme = "appearance.theme"
    static let highContrast = "appearance.highContrast"
}

struct AppearanceView: View {
    @AppStorage(AppearanceKeys.theme) private var theme = AppTheme.system
    @AppStorage(AppearanceKeys.highContrast) private var highContrast = false

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: $theme) {
                    ForEach(AppTheme.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Theme")
            }
            Section {
                Toggle("High contrast", isOn: $highContrast)
            } footer: {
                Text("""
                    Stronger colours for status, accents and message bubbles. m-Core also follows Increase Contrast \
                    in iOS Settings → Accessibility.
                    """)
            }
        }
        .navigationTitle("Appearance")
    }
}

extension View {
    /// Applies the Appearance settings to the whole window.
    func appAppearance() -> some View {
        modifier(AppearanceModifier())
    }
}

private struct AppearanceModifier: ViewModifier {
    @AppStorage(AppearanceKeys.theme) private var theme = AppTheme.system
    @AppStorage(AppearanceKeys.highContrast) private var highContrast = false

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(theme.colorScheme)
            .onAppear(perform: applyContrast)
            .onChange(of: highContrast) { applyContrast() }
    }

    /// SwiftUI can't set the contrast trait, so override it on every window scene.
    private func applyContrast() {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            if highContrast {
                scene.traitOverrides.accessibilityContrast = .high
            } else {
                scene.traitOverrides.remove(UITraitAccessibilityContrast.self)
            }
        }
    }
}
