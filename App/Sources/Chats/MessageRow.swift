import MapKit
import MeshDesign
import MeshServices
import MeshStore
import SwiftUI

struct MessageRow: View {
    let message: MessageRecord
    let showsSender: Bool
    /// Show a preview card (or the image) for the first link; off when previews are disabled or the sender is blocked.
    var showsLinkPreview = false
    let onReact: (String) -> Void
    let onReply: () -> Void
    let onRetry: () -> Void
    let onShowLocation: ((Double, Double) -> Void)?
    /// "Show path on map", when the message's route is known.
    var onShowPath: (() -> Void)?
    /// "Retry flood", for outgoing direct messages that failed or aren't acknowledged yet.
    var onRetryFlood: (() -> Void)?

    static let quickReactions = ["👍", "❤️", "😂", "🎉", "😮", "🙏"]

    var body: some View {
        switch message.kind {
        case .notice: notice
        case .mesh, .positionReport: meshMessage
        }
    }

    /// A local note, centred between the bubbles.
    private var notice: some View {
        Label(message.text, systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, MCSpacing.xs)
    }

    private var meshMessage: some View {
        VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: MCSpacing.xs) {
            if message.kind == .positionReport, let sender = message.senderName {
                Label("Position from \(sender)", systemImage: "location.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            } else if showsSender, !message.isOutgoing, let sender = message.senderName {
                Text(sender).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            bubble
            if !message.reactions.isEmpty {
                HStack(spacing: MCSpacing.xs) {
                    ForEach(groupedReactions, id: \.emoji) { group in
                        ReactionChip(emoji: group.emoji, count: group.count, isMine: group.isMine)
                    }
                }
            }
            if message.isOutgoing {
                DeliveryStatusLine(deliveryStatus)
            } else if message.isLocal {
                MessageMetadataLine(time: message.receivedAt)
            } else {
                MessageMetadataLine(time: message.sentDate, repeats: 0, route: route, clockSkewed: isClockSkewed)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.isOutgoing ? .trailing : .leading)
        .contextMenu { contextActions }
    }

    @ViewBuilder private var contextActions: some View {
        if !message.isLocal {
            ControlGroup {
                ForEach(Self.quickReactions, id: \.self) { emoji in
                    Button(emoji) { onReact(emoji) }
                }
            }
            // One row of emoji; the default compact style fits three and stacks the rest.
            .controlGroupStyle(.palette)
            Button("Reply", systemImage: "arrowshape.turn.up.left") { onReply() }
        }
        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text }
        if let location = MessageFormat.location(in: message.text) {
            Button("Open in Maps", systemImage: "map") { openInMaps(location.latitude, location.longitude) }
        }
        if let onShowPath {
            Button("Show path on map", systemImage: "point.topleft.down.to.point.bottomright.curvepath", action: onShowPath)
        }
        if message.isOutgoing, message.status == .failed {
            Button("Retry", systemImage: "arrow.clockwise") { onRetry() }
        }
        if let onRetryFlood {
            Button("Retry flood", systemImage: "dot.radiowaves.left.and.right", action: onRetryFlood)
        }
    }

    /// The context menu's main actions, for VoiceOver users.
    @ViewBuilder private var accessibilityActions: some View {
        if !message.isLocal {
            Button("Reply") { onReply() }
            ForEach(Self.quickReactions, id: \.self) { emoji in
                Button("React \(emoji)") { onReact(emoji) }
            }
        }
        Button("Copy") { UIPasteboard.general.string = message.text }
        if message.isOutgoing, message.status == .failed {
            Button("Retry") { onRetry() }
        }
    }

    private var bubble: some View {
        let reply = MessageFormat.parseReply(message.text)
        let previewURL = showsLinkPreview ? LinkPreviewCache.firstWebURL(in: reply?.body ?? message.text) : nil
        return VStack(alignment: .leading, spacing: MCSpacing.xs) {
            if let reply {
                VStack(alignment: .leading, spacing: 0) {
                    Text(reply.name).font(.caption.weight(.semibold))
                    Text(reply.quote).font(.caption)
                }
                .padding(.leading, MCSpacing.s)
                .overlay(alignment: .leading) {
                    Rectangle().frame(width: 3).foregroundStyle(message.isOutgoing ? Color.white.opacity(0.6) : MCColor.accent)
                }
                .opacity(0.85)
            }
            Text(MessageText.attributed(reply?.body ?? message.text, outgoing: message.isOutgoing))
                .textSelection(.enabled)
                // Links take the tint; the accent would vanish on an outgoing (accent) bubble.
                .tint(message.isOutgoing ? MCColor.bubbleOutgoingText : MCColor.accent)
                .accessibilityActions { accessibilityActions }
            if let location = MessageFormat.location(in: message.text) {
                LocationPreview(latitude: location.latitude, longitude: location.longitude)
                    .onTapGesture {
                        onShowLocation?(location.latitude, location.longitude) ?? openInMaps(location.latitude, location.longitude)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Map of the shared location")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Opens in Maps")
            }
            if let previewURL {
                MessageLinkPreview(url: previewURL)
            }
        }
        .padding(.horizontal, MCSpacing.m)
        .padding(.vertical, MCSpacing.s)
        .foregroundStyle(message.isOutgoing ? MCColor.bubbleOutgoingText : Color.primary)
        .background(
            RoundedRectangle(cornerRadius: MCRadius.bubble, style: .continuous)
                .fill(message.isOutgoing ? MCColor.bubbleOutgoing : MCColor.bubbleIncoming)
        )
        .frame(maxWidth: 520, alignment: message.isOutgoing ? .trailing : .leading)
        // Loaded from the bubble: the preview view is empty until there's something to show, and an empty view
        // never runs its own task.
        .task(id: previewURL) {
            if let previewURL { await LinkPreviewCache.shared.load(previewURL) }
        }
    }

    private var deliveryStatus: DeliveryStatus {
        switch message.status {
        case .sending: .sending
        case .sent: message.attempt > 0 ? .repeated(count: message.attempt) : .sent
        case .delivered: .delivered(repeats: 0)
        case .failed: .failed
        case .received: .sent
        }
    }

    private var route: MessageRoute? {
        if let hashes = message.routeHashes { return .direct(hops: hashes) }
        if let hops = message.hops { return hops == 0 ? .direct(hops: []) : .flood }
        return .direct(hops: [])
    }

    /// The sender's clock differs from the arrival time by more than an hour.
    private var isClockSkewed: Bool {
        abs(message.sentDate.timeIntervalSince(message.receivedAt)) > 3_600
    }

    private struct ReactionGroup {
        let emoji: String
        let count: Int
        let isMine: Bool
    }

    private var groupedReactions: [ReactionGroup] {
        let groups = Dictionary(grouping: message.reactions, by: \.emoji)
        return groups.map { emoji, reactions in
            ReactionGroup(emoji: emoji, count: reactions.count, isMine: reactions.contains(where: \.isMine))
        }
        .sorted { $0.count > $1.count }
    }

    private func openInMaps(_ latitude: Double, _ longitude: Double) {
        AppleMaps.open(latitude: latitude, longitude: longitude, label: message.senderName ?? "Location")
    }
}

/// Small static map snapshot for messages that contain coordinates.
struct LocationPreview: View {
    let latitude: Double
    let longitude: Double

    var body: some View {
        let center = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let region = MKCoordinateRegion(center: center, latitudinalMeters: 1_500, longitudinalMeters: 1_500)
        Map(initialPosition: .region(region), interactionModes: []) {
            Marker("", coordinate: center)
        }
        .frame(width: 220, height: 120)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .allowsHitTesting(false)
        // The map takes no touches; this layer does, so a tap gesture on the preview fires.
        .overlay { Color.clear.contentShape(Rectangle()) }
    }
}

/// Message text with inline Markdown (bold, italic, code, links), highlighted @mentions and tappable links.
enum MessageText {
    /// Made once: building a detector per message row is slow. NSDataDetector is immutable and thread-safe.
    static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func attributed(_ text: String, outgoing: Bool) -> AttributedString {
        var result = markdown(text) ?? AttributedString(text)
        for name in Set(MessageFormat.mentions(in: text)) {
            let token = MessageFormat.mention(name)
            var searchStart = result.startIndex
            while let range = result[searchStart...].range(of: token) {
                var replacement = AttributedString("@\(name)")
                replacement.font = .body.weight(.semibold)
                replacement.foregroundColor = outgoing ? .white : MCColor.accent
                result.replaceSubrange(range, with: replacement)
                searchStart = result.index(range.lowerBound, offsetByCharacters: name.count + 1)
            }
        }
        if let detector = linkDetector {
            let plain = String(result.characters)
            for match in detector.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
                guard let url = match.url, let range = Range(match.range, in: plain),
                      let attributedRange = Range(range, in: result),
                      result[attributedRange].runs.allSatisfy({ $0.link == nil }) else { continue }
                result[attributedRange].link = url
                result[attributedRange].underlineStyle = .single
            }
        }
        return result
    }

    /// One-line chat-list preview: Markdown markers removed (`**bold**` → `bold`), text kept as typed otherwise.
    static func plainPreview(_ text: String) -> String {
        markdown(text).map { String($0.characters) } ?? text
    }

    /// Inline Markdown, or nil if it doesn't parse. Mention tokens and bare links are escaped first,
    /// so `@[name]` and underscores or asterisks in URLs keep their characters.
    static func markdown(_ text: String) -> AttributedString? {
        var source = text
        if let detector = linkDetector {
            let matches = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches.reversed() {
                guard let range = Range(match.range, in: source), !isMarkdownLinkTarget(range, in: source) else { continue }
                source.replaceSubrange(range, with: escaped(String(source[range])))
            }
        }
        for name in Set(MessageFormat.mentions(in: text)) {
            let token = MessageFormat.mention(name)
            source = source.replacingOccurrences(of: token, with: escaped(token))
        }
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .throwError
        )
        return try? AttributedString(markdown: source, options: options)
    }

    /// Backslash-escapes ASCII punctuation, which CommonMark then shows literally.
    private static func escaped(_ text: String) -> String {
        var result = ""
        for character in text {
            if character.isASCII, character.isPunctuation || character.isSymbol { result.append("\\") }
            result.append(character)
        }
        return result
    }

    /// True when the link is the target of `[text](url)` or an autolink `<url>`, which Markdown handles itself.
    private static func isMarkdownLinkTarget(_ range: Range<String.Index>, in text: String) -> Bool {
        let before = text[..<range.lowerBound]
        return before.hasSuffix("](") || before.hasSuffix("<")
    }
}
