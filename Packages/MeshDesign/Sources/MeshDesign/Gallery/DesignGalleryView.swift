import SwiftUI

/// Every design-system component on one screen, for checking light and dark appearance.
public struct DesignGalleryView: View {
    private enum SampleFilter: String, CaseIterable {
        case all = "All"
        case unread = "Unread"
        case dms = "DMs"
        case channels = "Channels"
        case rooms = "Rooms"
    }

    @State private var filter: SampleFilter = .all
    private let sampleTime = Date(timeIntervalSince1970: 1_793_000_000)

    public init() {}

    public var body: some View {
        List {
            colorsSection
            avatarsSection
            messagesSection
            chipsSection
            statusSection
            controlsSection
        }
        .navigationTitle("Design Gallery")
    }

    private var colorsSection: some View {
        Section("Colours") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 64))], spacing: MCSpacing.m) {
                swatch("Accent", MCColor.accent)
                swatch("Incoming", MCColor.bubbleIncoming)
                swatch("Positive", MCColor.positive)
                swatch("Warning", MCColor.warning)
                swatch("Critical", MCColor.critical)
                swatch("Contact", MCColor.contact)
                swatch("Repeater", MCColor.repeater)
                swatch("Room", MCColor.room)
                swatch("Sensor", MCColor.sensor)
                swatch("Channel", MCColor.channel)
            }
            .padding(.vertical, MCSpacing.xs)
        }
    }

    private var avatarsSection: some View {
        Section("Avatars") {
            HStack(spacing: MCSpacing.m) {
                AvatarView(name: "Hannah Lee")
                AvatarView(name: "Bob Martinez")
                AvatarView(name: "Dad")
                AvatarView(name: "🔥")
                AvatarView(name: "Charlie Node", kind: .repeater)
                AvatarView(name: "Diana's Room", kind: .room)
            }
            HStack(spacing: MCSpacing.m) {
                AvatarView(name: "Public", kind: .publicChannel)
                AvatarView(name: "Bay Area", kind: .privateChannel)
                AvatarView(name: "#test", kind: .hashtagChannel)
                AvatarView(name: "Weather", kind: .sensor)
                AvatarView(name: "Alice Chen", size: 64)
            }
        }
    }

    private var messagesSection: some View {
        Section("Message metadata") {
            VStack(alignment: .leading, spacing: MCSpacing.s) {
                bubble("Yeah! Want to go hiking? 🥾", outgoing: false)
                MessageMetadataLine(
                    time: sampleTime,
                    repeats: 2,
                    route: .direct(hops: MessageRoute.hopHashes([[0x10, 0xA3], [0x20, 0xB7]]))
                )
                bubble("Sorry, my clock was way off 😅", outgoing: false)
                MessageMetadataLine(time: sampleTime, repeats: 2, route: .direct(hops: ["10", "20"]), clockSkewed: true)
                bubble("Welcome to all the new members!", outgoing: false)
                MessageMetadataLine(time: sampleTime, repeats: 1, route: .flood)
            }
            VStack(alignment: .trailing, spacing: MCSpacing.s) {
                bubble("Hey Alice, are you free this weekend?", outgoing: true)
                DeliveryStatusLine(.delivered(repeats: 1))
                bubble("Perfect! I know a great trail.", outgoing: true)
                DeliveryStatusLine(.sent)
                bubble("Are you there?", outgoing: true)
                DeliveryStatusLine(.failed)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var chipsSection: some View {
        Section("Chips & badges") {
            HStack(spacing: MCSpacing.s) {
                PathChip(.direct(hops: ["10A3", "20B7"]))
                PathChip(.flood)
                PathChip(.direct(hops: []))
            }
            HStack(spacing: MCSpacing.s) {
                ReactionChip(emoji: "👍", count: 2, isMine: true)
                ReactionChip(emoji: "❤️")
                ReactionChip(emoji: "🎉", count: 12)
                Spacer()
                CountBadge(.mention)
                CountBadge(.unread(3))
                CountBadge(.unread(120))
            }
            FilterChipBar(options: SampleFilter.allCases, selection: $filter) { $0.rawValue }
        }
    }

    private var statusSection: some View {
        Section("Status") {
            VStack(alignment: .leading, spacing: MCSpacing.s) {
                StatusPill(gps: .radioGPS(lastPositionAge: 12))
                StatusPill(gps: .phone(accuracyMeters: 8, lastSyncAge: 12))
                StatusPill(gps: .waitingForPhoneLocation)
                StatusPill(gps: .locationAccessNeeded)
                StatusPill(gps: .off)
                StatusPill(connection: .connected(name: "Heltec V3"))
                StatusPill(connection: .connecting(name: nil))
                StatusPill(connection: .disconnected)
            }
            HStack(spacing: MCSpacing.l) {
                ForEach(SignalLevel.allCases, id: \.self) { level in
                    VStack(spacing: MCSpacing.xs) {
                        SignalBars(level: level)
                        Text(level.label).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var controlsSection: some View {
        Section("Floating controls") {
            ZStack(alignment: .topLeading) {
                LinearGradient(
                    colors: [MCColor.repeater.opacity(0.35), MCColor.room.opacity(0.25)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                HStack {
                    FloatingIconButton(
                        systemImage: "antenna.radiowaves.left.and.right",
                        accessibilityLabel: "Connection",
                        tint: MCColor.positive
                    ) {}
                    Spacer()
                    FloatingIconButton(systemImage: "square.and.pencil", accessibilityLabel: "New message") {}
                }
                .padding(MCSpacing.m)
                FloatingMapControls(MapControl.standard(onCompass: {}, onLocate: {}, onFullscreen: {}))
                    .padding(MCSpacing.m)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
            .frame(height: 240)
            .clipShape(RoundedRectangle(cornerRadius: MCRadius.card, style: .continuous))
            .listRowInsets(EdgeInsets())
        }
    }

    private func swatch(_ name: String, _ color: Color) -> some View {
        VStack(spacing: MCSpacing.xs) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(color)
                .frame(height: 40)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.quaternary))
            Text(name).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func bubble(_ text: String, outgoing: Bool) -> some View {
        Text(text)
            .padding(.horizontal, MCSpacing.m)
            .padding(.vertical, MCSpacing.s)
            .foregroundStyle(outgoing ? MCColor.bubbleOutgoingText : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: MCRadius.bubble, style: .continuous)
                    .fill(outgoing ? MCColor.bubbleOutgoing : MCColor.bubbleIncoming)
            )
    }
}

#Preview("Light") {
    NavigationStack { DesignGalleryView() }
}

#Preview("Dark") {
    NavigationStack { DesignGalleryView() }
        .preferredColorScheme(.dark)
}
