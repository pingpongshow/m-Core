import MeshDesign
import MeshServices
import SwiftUI

/// The round antenna button: green when connected; opens a popover with connection and GPS Feed state.
struct ConnectionButton: View {
    @Environment(RadioController.self) private var radio
    @Environment(GPSFeedService.self) private var gpsFeed
    @Environment(AppRouter.self) private var router
    /// Draws its own round surface, for use over the map rather than in a toolbar (which supplies one).
    var isFloating = false
    @State private var showingPopover = false

    var body: some View {
        if isFloating {
            button
                .buttonStyle(.plain)
                .mcFloatingSurface(in: Circle())
        } else {
            button
        }
    }

    private var button: some View {
        Button {
            showingPopover = true
        } label: {
            Image(systemName: radio.isConnected ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                .foregroundStyle(tint)
                .font(isFloating ? .title3.weight(.medium) : nil)
                .frame(width: isFloating ? MCSize.control : nil, height: isFloating ? MCSize.control : nil)
                .contentShape(Circle())
        }
        .accessibilityLabel("Radio: \(radio.status.text)")
        .popover(isPresented: $showingPopover) {
            ConnectionPopover(dismiss: { showingPopover = false })
                .presentationCompactAdaptation(.popover)
        }
    }

    private var tint: Color {
        switch radio.status {
        case .connected: MCColor.positive
        case .connecting: MCColor.warning
        case .disconnected: .secondary
        }
    }
}

struct ConnectionPopover: View {
    @Environment(RadioController.self) private var radio
    @Environment(GPSFeedService.self) private var gpsFeed
    @Environment(AppRouter.self) private var router
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MCSpacing.m) {
            StatusPill(connection: radio.status)
            TimelineView(.periodic(from: .now, by: 5)) { context in
                StatusPill(gps: gpsFeed.displayStatus(now: context.date))
            }
            if gpsFeed.status == .pausedLowPower {
                Label("GPS Feed paused in Low Power Mode", systemImage: "battery.25percent")
                    .font(.footnote)
                    .foregroundStyle(MCColor.warning)
            }
            if let battery = radio.battery {
                Label("Radio battery \(radio.batteryChemistry.describe(millivolts: Int(battery.millivolts)))",
                      systemImage: batterySymbol(radio.batteryPercent))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let info = radio.connectionInfo {
                Text([info.device.model ?? "Radio", info.device.firmwareVersion].compactMap { $0 }.joined(separator: " · "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Button("Radio settings") {
                    router.open(.radio)
                    dismiss()
                }
                Spacer()
                if radio.isActive {
                    Button("Disconnect", role: .destructive) {
                        Task { await radio.disconnect() }
                    }
                } else if radio.lastTarget != nil {
                    Button("Reconnect") {
                        Task { await radio.reconnectToLast() }
                    }
                }
            }
            .font(.subheadline)
        }
        .padding()
        .frame(minWidth: 260)
    }

    private func batterySymbol(_ percent: Int?) -> String {
        switch percent ?? 75 {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }
}
