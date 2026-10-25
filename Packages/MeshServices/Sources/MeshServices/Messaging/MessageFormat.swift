import CryptoKit
import Foundation

/// Text conventions layered on MeshCore messages, matching what MeshCore One and the official app send,
/// so mentions, replies and reactions render for their users too.
public enum MessageFormat {
    // MARK: Mentions

    public static func mention(_ name: String) -> String {
        "@[\(name)]"
    }

    /// Names mentioned as `@[name]`.
    public static func mentions(in text: String) -> [String] {
        var names: [String] = []
        var remainder = text[...]
        while let open = remainder.range(of: "@["), let close = remainder[open.upperBound...].firstIndex(of: "]") {
            names.append(String(remainder[open.upperBound..<close]))
            remainder = remainder[remainder.index(after: close)...]
        }
        return names
    }

    /// Text for previews and notifications: `@[name]` shown as `@name`.
    public static func displayText(_ text: String) -> String {
        var result = text
        for name in mentions(in: text) {
            result = result.replacingOccurrences(of: mention(name), with: "@\(name)")
        }
        return result
    }

    public static func mentions(_ text: String, name: String) -> Bool {
        mentions(in: text).contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    // MARK: Replies

    /// `@[name]\n>first ten chars..\nreply`
    public static func replyText(to name: String, quoting original: String, reply: String) -> String {
        let source = stripLeadingMention(original)
        let preview = String(source.prefix(10)) + (source.count > 10 ? ".." : "")
        return "\(mention(name))\n>\(preview)\n\(reply)"
    }

    public struct Reply: Equatable, Sendable {
        public var name: String
        public var quote: String
        public var body: String
    }

    public static func parseReply(_ text: String) -> Reply? {
        let lines = text.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
        guard lines.count == 3, lines[1].hasPrefix(">"),
              let name = mentions(in: String(lines[0])).first,
              String(lines[0]) == mention(name) else { return nil }
        return Reply(name: name, quote: String(lines[1].dropFirst()), body: String(lines[2]))
    }

    private static func stripLeadingMention(_ text: String) -> String {
        guard text.hasPrefix("@["), let close = text.firstIndex(of: "]") else { return text }
        return String(text[text.index(after: close)...]).trimmingCharacters(in: .whitespaces)
    }

    // MARK: Reactions

    /// 8-character Crockford base32 of the first 5 bytes of SHA-256(text ‖ timestamp LE).
    public static func reactionHash(text: String, timestamp: UInt32) -> String {
        var data = Data(text.utf8)
        withUnsafeBytes(of: timestamp.littleEndian) { data.append(contentsOf: $0) }
        return crockfordBase32(Array(SHA256.hash(data: data).prefix(5)))
    }

    /// Channel reaction: `@[sender]emoji\nhash`.
    public static func channelReactionText(emoji: String, targetSender: String, targetText: String, targetTimestamp: UInt32) -> String {
        "\(mention(targetSender))\(emoji)\n\(reactionHash(text: targetText, timestamp: targetTimestamp))"
    }

    /// Direct-message reaction: `emoji\nhash`.
    public static func directReactionText(emoji: String, targetText: String, targetTimestamp: UInt32) -> String {
        "\(emoji)\n\(reactionHash(text: targetText, timestamp: targetTimestamp))"
    }

    public struct Reaction: Equatable, Sendable {
        public var emoji: String
        /// Channel reactions name the author of the target message.
        public var targetSender: String?
        public var hash: String
    }

    /// Parses either reaction form; nil if `text` is an ordinary message.
    public static func parseReaction(_ text: String) -> Reaction? {
        guard let newline = text.lastIndex(of: "\n") else { return nil }
        let rawHash = String(text[text.index(after: newline)...])
        guard rawHash.count == 8, let hash = normalizedCrockford(rawHash) else { return nil }
        let head = String(text[..<newline])

        guard let open = head.range(of: "@[") else {
            return isSingleEmoji(head) ? Reaction(emoji: head, targetSender: nil, hash: hash) : nil
        }
        let before = String(head[..<open.lowerBound])
        let after = head[open.upperBound...]
        let emoji: String
        let sender: String
        if before.isEmpty {
            guard let close = after.firstIndex(of: "]") else { return nil }
            sender = String(after[..<close])
            emoji = String(after[after.index(after: close)...])
        } else {
            guard after.hasSuffix("]") else { return nil }
            emoji = before
            sender = String(after.dropLast())
        }
        guard isSingleEmoji(emoji), !sender.isEmpty else { return nil }
        return Reaction(emoji: emoji, targetSender: sender, hash: hash)
    }

    static func isSingleEmoji(_ text: String) -> Bool {
        guard text.count == 1, let character = text.first, let scalar = character.unicodeScalars.first else { return false }
        return scalar.properties.isEmojiPresentation || (character.unicodeScalars.count > 1 && scalar.properties.isEmoji)
    }

    // MARK: Locations

    /// Plain "lat, lon" text, which other MeshCore apps render as a map preview.
    public static func locationText(latitude: Double, longitude: Double, label: String? = nil) -> String {
        let coordinates = String(format: "%.5f, %.5f", latitude, longitude)
        return label.map { "\($0): \(coordinates)" } ?? coordinates
    }

    /// First "lat, lon" pair found in `text`.
    public static func location(in text: String) -> (latitude: Double, longitude: Double)? {
        guard let match = text.firstMatch(of: /(-?\d{1,2}\.\d{3,}),\s*(-?\d{1,3}\.\d{3,})/),
              let latitude = Double(match.1), let longitude = Double(match.2),
              (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        return (latitude, longitude)
    }

    // MARK: Channels

    /// Shared secret for a `#hashtag` channel: first 16 bytes of SHA-256 of the name including "#".
    public static func hashtagSecret(_ name: String) -> Data {
        let tag = name.hasPrefix("#") ? name : "#\(name)"
        return Data(SHA256.hash(data: Data(tag.lowercased().utf8)).prefix(16))
    }

    // MARK: Crockford base32

    private static let alphabet = Array("0123456789abcdefghjkmnpqrstvwxyz")

    static func crockfordBase32(_ bytes: [UInt8]) -> String {
        precondition(bytes.count == 5)
        let bits = bytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return String(stride(from: 35, through: 0, by: -5).map { alphabet[Int((bits >> UInt64($0)) & 0x1F)] })
    }

    /// Lowercases and maps the Crockford look-alikes (O→0, I/L→1); nil if not valid base32.
    static func normalizedCrockford(_ text: String) -> String? {
        var result = ""
        for character in text.lowercased() {
            switch character {
            case "o": result.append("0")
            case "i", "l": result.append("1")
            case _ where alphabet.contains(character): result.append(character)
            default: return nil
            }
        }
        return result
    }
}
