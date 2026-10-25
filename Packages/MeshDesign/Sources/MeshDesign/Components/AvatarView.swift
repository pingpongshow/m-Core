import SwiftUI

/// What an avatar represents; decides its symbol and colour.
public enum AvatarKind: Sendable, Equatable, CaseIterable {
    case contact
    case repeater
    case room
    case sensor
    case publicChannel
    case privateChannel
    case hashtagChannel
}

/// Pure helpers behind `AvatarView`, kept separate so they can be unit tested.
public enum AvatarStyle {
    /// Up to two initials: first letter of the first and last words, or an emoji if the name has no letters.
    public static func initials(for name: String) -> String {
        let words = name.split { $0.isWhitespace || $0 == "-" || $0 == "_" || $0 == "." }
        let letters = words.compactMap { word in word.first { $0.isLetter || $0.isNumber } }
        switch letters.count {
        case 0:
            if let emoji = name.first(where: \.isEmoji) { return String(emoji) }
            return "?"
        case 1:
            return String(letters[0]).uppercased()
        default:
            return (String(letters[0]) + String(letters[letters.count - 1])).uppercased()
        }
    }

    /// Stable palette index for a name (FNV-1a; Swift's `hashValue` changes between launches).
    public static func paletteIndex(for name: String, paletteCount: Int) -> Int {
        precondition(paletteCount > 0)
        var hash: UInt32 = 2_166_136_261
        for byte in name.lowercased().utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return Int(hash % UInt32(paletteCount))
    }

    public static func contactColor(for name: String) -> Color {
        MCColor.avatarPalette[paletteIndex(for: name, paletteCount: MCColor.avatarPalette.count)]
    }
}

/// Round avatar: initials for contacts, a symbol for repeaters, rooms, sensors and channels.
public struct AvatarView: View {
    private let name: String
    private let kind: AvatarKind
    private let size: CGFloat

    public init(name: String, kind: AvatarKind = .contact, size: CGFloat = MCSize.avatarRow) {
        self.name = name
        self.kind = kind
        self.size = size
    }

    public var body: some View {
        ZStack {
            Circle().fill(background)
            content.foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var content: some View {
        if let symbol {
            Image(systemName: symbol).font(.system(size: size * 0.42, weight: .semibold))
        } else {
            Text(AvatarStyle.initials(for: name))
                .font(.system(size: size * 0.4, weight: .semibold))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
        }
    }

    private var symbol: String? {
        switch kind {
        case .contact: nil
        case .repeater: "antenna.radiowaves.left.and.right"
        case .room: "person.3.fill"
        case .sensor: "thermometer.medium"
        case .publicChannel: "globe"
        case .privateChannel: "lock.fill"
        case .hashtagChannel: "number"
        }
    }

    private var background: Color {
        switch kind {
        case .contact: AvatarStyle.contactColor(for: name)
        case .repeater: MCColor.repeater
        case .room: MCColor.room
        case .sensor: MCColor.sensor
        case .publicChannel, .privateChannel, .hashtagChannel: MCColor.channel
        }
    }
}

private extension Character {
    var isEmoji: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        return scalar.properties.isEmojiPresentation || (unicodeScalars.count > 1 && scalar.properties.isEmoji)
    }
}
