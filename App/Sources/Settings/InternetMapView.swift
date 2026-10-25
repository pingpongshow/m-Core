import MeshCoreKit
import MeshDesign
import MeshServices
import SwiftUI

/// The MeshCore Internet Map: download the public node list for the map, and list your own radio.
struct InternetMapView: View {
    @Environment(InternetMapService.self) private var internetMap
    @Environment(RadioController.self) private var radio
    @AppStorage("map.showInternetNodes") private var showOnMap = false
    @State private var confirmUpload = false
    @State private var isUploading = false
    @State private var uploadResult: String?

    var body: some View {
        Form {
            Section {
                Toggle("Show on the map", isOn: $showOnMap)
                LabeledContent("Nodes saved", value: internetMap.nodes.count.formatted())
                if let fetchedAt = internetMap.fetchedAt {
                    LabeledContent("Updated", value: fetchedAt.formatted(.relative(presentation: .named)))
                }
                Button {
                    Task { await internetMap.refresh() }
                } label: {
                    if internetMap.isLoading {
                        HStack { ProgressView(); Text("Downloading…") }
                    } else {
                        Label(internetMap.nodes.isEmpty ? "Download node list" : "Update node list", systemImage: "arrow.down.circle")
                    }
                }
                .disabled(internetMap.isLoading)
                if let error = internetMap.lastError {
                    Text(error).font(.footnote).foregroundStyle(MCColor.critical)
                }
            } footer: {
                Text("""
                    map.meshcore.io lists repeaters, rooms and companions people have shared. The list is about 18 MB \
                    and is kept on this device, so it works offline. Tap a node on the map to add it as a contact \
                    before you're in range.
                    """)
            }
            Section {
                Button("Add my radio to the map", systemImage: "mappin.and.ellipse") { confirmUpload = true }
                    .disabled(!radio.isConnected || isUploading)
                    .confirmationDialog("Add your radio to the public map?", isPresented: $confirmUpload, titleVisibility: .visible) {
                        Button("Add to map") { upload() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Anyone can see \(radio.selfInfo?.name ?? "your radio") and its advertised position on map.meshcore.io.")
                    }
                if isUploading { ProgressView("Uploading…") }
                if let uploadResult { Text(uploadResult).font(.footnote).foregroundStyle(.secondary) }
            } footer: {
                Text("""
                    Shares your radio's name, public key, advertised position and radio settings publicly. Your radio \
                    signs the request; its private key never leaves it. Entries expire if not refreshed for 20 days.
                    """)
            }
        }
        .navigationTitle("Internet Map")
    }

    private func upload() {
        isUploading = true
        uploadResult = nil
        Task {
            defer { isUploading = false }
            do {
                let message = try await internetMap.uploadSelf()
                uploadResult = message ?? "Sent. It can take a few minutes to appear."
            } catch let error as InternetMapError {
                uploadResult = error.description
            } catch {
                uploadResult = "Upload failed: \(errorMessage(error))"
            }
        }
    }
}
