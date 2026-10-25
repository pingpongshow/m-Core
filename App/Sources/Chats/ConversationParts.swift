import MeshDesign
import MeshServices
import SwiftUI

/// Shown at the top of a conversation while live location is being shared to it.
struct LiveLocationBanner: View {
    let share: LiveLocationService.Share
    /// Why the last update didn't go out, if it failed.
    var error: String?
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: MCSpacing.s) {
            Image(systemName: "location.fill.viewfinder")
                .foregroundStyle(MCColor.accent)
                .symbolEffect(.pulse)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text("Sharing live location").font(.footnote.weight(.semibold))
                HStack(spacing: MCSpacing.xxs) {
                    Text(timerInterval: Date.now...max(Date.now, share.expiresAt), countsDown: true)
                        .monospacedDigit()
                    Text("left")
                    if share.updatesSent > 0 {
                        Text("· \(share.updatesSent) sent")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let error {
                    Text(error).font(.caption).foregroundStyle(MCColor.warning)
                }
            }
            Spacer()
            Button("Stop", role: .destructive, action: onStop)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, MCSpacing.m)
        .padding(.vertical, MCSpacing.s)
        .mcFloatingSurface(in: RoundedRectangle(cornerRadius: MCRadius.control, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Floating button that scrolls to the newest message, with the number that arrived while scrolled up.
struct JumpToLatestButton: View {
    let unread: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.down")
                .font(.body.weight(.semibold))
                .frame(width: MCSize.control, height: MCSize.control)
        }
        .mcFloatingSurface(in: Circle())
        .overlay(alignment: .topTrailing) {
            if unread > 0 {
                CountBadge(.unread(unread)).offset(x: 6, y: -6)
            }
        }
        .accessibilityLabel(unread > 0 ? "Jump to latest, \(unread) new" : "Jump to latest")
    }
}
