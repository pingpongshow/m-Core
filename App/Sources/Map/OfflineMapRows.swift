import MeshDesign
import MeshMaps
import SwiftUI

/// A running download in Offline Maps: its step or progress, with pause and cancel.
struct DownloadProgressRow: View {
    let download: OfflineMapDownload
    let onPause: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MCSpacing.s) {
            HStack {
                Text(download.name).font(.body.weight(.medium))
                Spacer()
                Button("Pause", action: onPause).buttonStyle(.borderless)
                Button("Cancel", role: .destructive, action: onCancel).buttonStyle(.borderless)
            }
            switch download.phase {
            case .locatingBuild:
                Self.working("Finding the latest map build…")
            case .planning:
                Self.working("Working out which tiles to fetch…")
            case .downloading:
                let done = download.bytesDone.formatted(.byteCount(style: .file))
                let total = download.bytesTotal.formatted(.byteCount(style: .file))
                ProgressView(value: download.fractionCompleted)
                Text("\(done) of \(total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            case .finishing:
                Self.working("Saving…")
            }
        }
    }

    /// A small spinner beside the step, in line with the progress text (a labelled ProgressView centres the
    /// spinner above its label).
    private static func working(_ text: LocalizedStringKey) -> some View {
        HStack(spacing: MCSpacing.s) {
            ProgressView().controlSize(.small)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// A paused or interrupted download, with its progress so far and a resume button.
struct PausedDownloadRow: View {
    let paused: PausedOfflineMapDownload
    let canResume: Bool
    let onResume: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MCSpacing.s) {
            HStack {
                VStack(alignment: .leading, spacing: MCSpacing.xxs) {
                    Text(paused.name).font(.body.weight(.medium))
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Resume", systemImage: "play.fill", action: onResume)
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .buttonStyle(.borderless)
                    .disabled(!canResume)
            }
            if paused.bytesTotal > 0 {
                ProgressView(value: paused.fractionCompleted)
            }
            if let lastError = paused.lastError {
                Label(lastError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(MCColor.warning)
            }
        }
    }

    private var status: String {
        var parts = [paused.replacesAreaID == nil ? paused.detail.title : "Refresh"]
        if paused.bytesTotal > 0 {
            let done = paused.bytesDone.formatted(.byteCount(style: .file))
            let total = paused.bytesTotal.formatted(.byteCount(style: .file))
            parts.append("\(done) of \(total)")
        } else {
            parts.append("Not started")
        }
        parts.append(paused.updatedAt.formatted(date: .abbreviated, time: .shortened))
        return parts.joined(separator: " · ")
    }
}
