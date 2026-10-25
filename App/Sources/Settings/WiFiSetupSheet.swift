import MeshCoreKit
import MeshDesign
import MeshServices
import SwiftUI
import UniformTypeIdentifiers

struct WiFiSetupSheet: View {
    @Environment(RadioSettingsService.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var ssid = ""
    @State private var password = ""
    @State private var enabled = true
    @State private var status: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Network name", text: $ssid).autocorrectionDisabled().textInputAutocapitalization(.never)
                SecureField("Password", text: $password)
                Toggle("Wi‑Fi on", isOn: $enabled)
                if let status { Text(status).font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle("Radio Wi‑Fi")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            do {
                                try await settings.setWiFi(ssid: ssid, password: password, enabled: enabled)
                                status = "Saved. Reboot the radio to connect."
                            } catch {
                                status = "Failed: \(errorMessage(error))"
                            }
                        }
                    }
                    .disabled(ssid.isEmpty)
                }
            }
        }
    }
}
