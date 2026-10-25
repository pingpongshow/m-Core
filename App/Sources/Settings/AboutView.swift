import SwiftUI

struct AboutView: View {
    var body: some View {
        List {
            Section {
                LabeledContent("Version", value: Bundle.main.versionString)
            } footer: {
                Text("""
                    m-Core is open source under the MIT licence. It's an independent implementation and contains no \
                    code from other MeshCore or Meshtastic apps.
                    """)
            }
            Section("Map data") {
                Text("© OpenStreetMap contributors (ODbL)")
                Text("Basemap tiles from Protomaps")
                Text("Map labels: Noto Sans, SIL Open Font License 1.1")
            }
            Section("Online services") {
                Text("Terrain for line of sight: Open-Meteo (Copernicus DEM)")
                Text("Internet Map: map.meshcore.io")
                Text("Suggested radio settings: api.meshcore.nz, checked once a day from Mesh Discovery")
                Text("Place search: Apple Maps")
                Text("Map source list: m-Core's GitHub repository, checked at most once a day when you download maps")
            }
            Section("m-Core") {
                Link("Source code", destination: URL(string: "https://github.com/pingpongshow/m-Core")!)
            }
            Section("MeshCore") {
                Link("MeshCore project", destination: URL(string: "https://github.com/meshcore-dev/MeshCore")!)
                Link("Web flasher", destination: URL(string: "https://flasher.meshcore.co.uk")!)
            }
        }
        .navigationTitle("About")
    }
}

extension Bundle {
    var versionString: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
