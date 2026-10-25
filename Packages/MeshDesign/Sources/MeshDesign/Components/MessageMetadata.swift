import Foundation
import SwiftUI

/// How a message travelled: flooded, or directly along a path of repeater hashes.
public enum MessageRoute: Equatable, Sendable {
    case flood
    case direct(hops: [String])

    public var text: String {
        switch self {
        case .flood: "Flood"
        case .direct(let hops) where hops.isEmpty: "Direct"
        case .direct(let hops): hops.joined(separator: ", ")
        }
    }

    /// Formats raw path hashes (1 or 2 bytes each) as uppercase hex, e.g. `[[0x10, 0xA3]]` → `["10A3"]`.
    public static func hopHashes(_ hashes: [[UInt8]]) -> [String] {
        hashes.map { bytes in bytes.map { String(format: "%02X", $0) }.joined() }
    }
}

/// Delivery state of an outgoing message.
public enum DeliveryStatus: Equatable, Sendable {
    case sending
    case sent
    case repeated(count: Int)
    case delivered(repeats: Int)
    case failed

    public var text: String {
        switch self {
        case .sending: "Sending…"
        case .sent: "Sent"
        case .repeated(let count): Self.repeatText(count)
        case .delivered(let repeats) where repeats > 0: "\(Self.repeatText(repeats)) · Delivered"
        case .delivered: "Delivered"
        case .failed: "Failed"
        }
    }

    private static func repeatText(_ count: Int) -> String {
        count == 1 ? "1 repeat" : "\(count) repeats"
    }
}

/// The small line under an incoming bubble: time · repeats · path.
public struct MessageMetadataLine: View {
    private let time: Date
    private let repeats: Int
    private let route: MessageRoute?
    private let clockSkewed: Bool

    public init(time: Date, repeats: Int = 0, route: MessageRoute? = nil, clockSkewed: Bool = false) {
        self.time = time
        self.repeats = repeats
        self.route = route
        self.clockSkewed = clockSkewed
    }

    public var body: some View {
        HStack(spacing: MCSpacing.xs) {
            if clockSkewed {
                Image(systemName: "clock.badge.exclamationmark")
                    .accessibilityLabel("Sender clock is off")
            }
            Text(time, format: .dateTime.hour().minute())
            if repeats > 0 {
                Image(systemName: "arrow.2.squarepath").accessibilityHidden(true)
                Text("\(repeats)").accessibilityLabel(repeats == 1 ? "1 repeat" : "\(repeats) repeats")
            }
            if let route {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath").accessibilityHidden(true)
                Text(route.text).font(MCFont.hash).accessibilityLabel("Path \(route.text)")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}

/// The status line under an outgoing bubble, e.g. "1 repeat · Delivered".
public struct DeliveryStatusLine: View {
    private let status: DeliveryStatus

    public init(_ status: DeliveryStatus) {
        self.status = status
    }

    public var body: some View {
        Text(status.text)
            .font(.caption2)
            .foregroundStyle(status == .failed ? MCColor.critical : .secondary)
    }
}
