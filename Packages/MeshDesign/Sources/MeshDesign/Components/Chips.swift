import SwiftUI

/// Capsule showing a message or contact path.
public struct PathChip: View {
    private let route: MessageRoute

    public init(_ route: MessageRoute) {
        self.route = route
    }

    public var body: some View {
        // HStack rather than Label: inside a List, Label pads its icon to the row's icon column.
        HStack(spacing: MCSpacing.xs) {
            Image(systemName: iconName)
            Text(route.text).font(route == .flood ? .caption : MCFont.hash)
        }
        .font(.caption)
        .padding(.horizontal, MCSpacing.s)
        .padding(.vertical, MCSpacing.xs)
        .background(Capsule().fill(MCColor.chipBackground))
        .accessibilityLabel("Path \(route.text)")
    }

    private var iconName: String {
        route == .flood ? "dot.radiowaves.left.and.right" : "point.topleft.down.to.point.bottomright.curvepath"
    }
}

/// Emoji reaction under a bubble. Outlined when the reaction is yours.
public struct ReactionChip: View {
    private let emoji: String
    private let count: Int
    private let isMine: Bool

    public init(emoji: String, count: Int = 1, isMine: Bool = false) {
        self.emoji = emoji
        self.count = count
        self.isMine = isMine
    }

    public var body: some View {
        HStack(spacing: MCSpacing.xs) {
            Text(emoji)
            if count > 1 {
                Text("\(count)").foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
        .padding(.horizontal, MCSpacing.s)
        .padding(.vertical, MCSpacing.xxs + 1)
        .background(Capsule().fill(MCColor.chipBackground))
        .overlay(Capsule().strokeBorder(isMine ? MCColor.accent : .clear, lineWidth: 1.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(emoji) \(count)\(isMine ? ", including you" : "")")
    }
}

/// Unread count or mention marker on list rows.
public struct CountBadge: View {
    public enum Style: Equatable, Sendable {
        case unread(Int)
        case mention
    }

    private let style: Style

    public init(_ style: Style) {
        self.style = style
    }

    public var body: some View {
        Text(label)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, MCSpacing.xs + 2)
            .frame(minWidth: 20, minHeight: 20)
            .background(Capsule().fill(MCColor.accent))
            .accessibilityLabel(accessibilityText)
    }

    private var label: String {
        switch style {
        case .unread(let count): count > 99 ? "99+" : "\(count)"
        case .mention: "@"
        }
    }

    private var accessibilityText: String {
        switch style {
        case .unread(let count): "\(count) unread"
        case .mention: "Mentioned"
        }
    }
}

/// Horizontal filter chips, e.g. All · Unread · DMs · Channels · Rooms.
public struct FilterChipBar<Option: Hashable>: View {
    private let options: [Option]
    @Binding private var selection: Option
    private let title: (Option) -> String

    public init(options: [Option], selection: Binding<Option>, title: @escaping (Option) -> String) {
        self.options = options
        self._selection = selection
        self.title = title
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: MCSpacing.s) {
                ForEach(options, id: \.self) { option in
                    let isSelected = option == selection
                    Button {
                        selection = option
                    } label: {
                        Text(title(option))
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, MCSpacing.m)
                            .padding(.vertical, MCSpacing.xs + 2)
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                            .background(Capsule().fill(isSelected ? MCColor.accent : MCColor.chipBackground))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
    }
}
