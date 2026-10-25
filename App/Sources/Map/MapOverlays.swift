import CoreLocation
import MeshDesign
import MeshMaps
import MeshTools
import SwiftUI

/// Shown while only the world overview is available.
struct MapOverviewBanner: View {
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Label("Download an area for street detail", systemImage: "arrow.down.circle")
                .font(.footnote.weight(.medium))
                .padding(.horizontal, MCSpacing.m)
                .padding(.vertical, MCSpacing.s)
        }
        .buttonStyle(.plain)
        .mcFloatingSurface(in: Capsule())
    }
}

/// OpenStreetMap credit required by the ODbL.
struct MapAttribution: View {
    var body: some View {
        Link("© OpenStreetMap contributors", destination: URL(string: "https://www.openstreetmap.org/copyright")!) // swiftlint:disable:this force_unwrapping
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, MCSpacing.s)
            .padding(.vertical, 2)
            .background(.thinMaterial, in: Capsule())
    }
}

/// Compact progress shown on the map while an area downloads.
struct DownloadChip: View {
    let download: OfflineMapDownload

    var body: some View {
        HStack(spacing: MCSpacing.s) {
            ProgressView(value: download.fractionCompleted)
                .progressViewStyle(.circular)
                .controlSize(.small)
            Text("\(download.name) \(download.fractionCompleted.formatted(.percent.precision(.fractionLength(0))))")
                .font(.footnote.weight(.medium))
        }
        .padding(.horizontal, MCSpacing.m)
        .padding(.vertical, MCSpacing.s)
        .mcFloatingSurface(in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Downloading \(download.name)")
        .accessibilityValue(download.fractionCompleted.formatted(.percent.precision(.fractionLength(0))))
    }
}

extension MapDot {
    /// Coverage-walk samples: green where the ping got through, red where it didn't.
    static func coverage(_ samples: [CoverageSample]) -> [MapDot] {
        samples.enumerated().map { index, sample in
            MapDot(
                id: "coverage-\(index)-\(sample.time.timeIntervalSince1970)",
                coordinate: CLLocationCoordinate2D(latitude: sample.coordinate.latitude, longitude: sample.coordinate.longitude),
                color: sample.success ? .systemGreen : .systemRed
            )
        }
    }
}
