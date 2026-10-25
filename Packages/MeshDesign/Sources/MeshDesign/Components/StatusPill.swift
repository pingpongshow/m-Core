import Foundation
import SwiftUI

public enum StatusTone: Sendable {
    case positive
    case neutral
    case warning
    case critical

    public var color: Color {
        switch self {
        case .positive: MCColor.positive
        case .neutral: .secondary
        case .warning: MCColor.warning
        case .critical: MCColor.critical
        }
    }
}

/// Short, deterministic "time ago" text for status lines.
public enum RelativeAge {
    public static func text(seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 5 { return "just now" }
        if total < 60 { return "\(total) s ago" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) h ago" }
        return "\(hours / 24) d ago"
    }
}

/// State of the GPS Feed for the connected radio (PLAN.md §4.1):
/// a radio with GPS uses its own; a radio without GPS is fed the phone's position.
public enum GPSFeedStatus: Equatable, Sendable {
    case off
    case radioGPS(lastPositionAge: TimeInterval?)
    case phone(accuracyMeters: Double, lastSyncAge: TimeInterval?)
    case waitingForPhoneLocation
    case locationAccessNeeded

    public var text: String {
        switch self {
        case .off:
            "GPS Feed off"
        case .radioGPS(let age?):
            "Radio GPS · \(RelativeAge.text(seconds: age))"
        case .radioGPS(nil):
            "Radio GPS"
        case .phone(let accuracy, let age):
            "Phone · ±\(Int(accuracy.rounded())) m" + (age.map { " · synced \(RelativeAge.text(seconds: $0))" } ?? "")
        case .waitingForPhoneLocation:
            "Waiting for location"
        case .locationAccessNeeded:
            "Location access needed"
        }
    }

    public var systemImage: String {
        switch self {
        case .off: "location.slash"
        case .radioGPS: "antenna.radiowaves.left.and.right"
        case .phone: "location.fill"
        case .waitingForPhoneLocation: "location"
        case .locationAccessNeeded: "exclamationmark.triangle.fill"
        }
    }

    public var tone: StatusTone {
        switch self {
        case .off: .neutral
        case .radioGPS, .phone: .positive
        case .waitingForPhoneLocation: .warning
        case .locationAccessNeeded: .critical
        }
    }
}

/// Radio connection state shown in the shell and connection popover.
public enum ConnectionStatus: Equatable, Sendable {
    case disconnected
    case connecting(name: String?)
    case connected(name: String)

    public var text: String {
        switch self {
        case .disconnected: "Not connected"
        case .connecting(let name?): "Connecting to \(name)…"
        case .connecting(nil): "Connecting…"
        case .connected(let name): name
        }
    }

    public var systemImage: String {
        switch self {
        case .disconnected: "antenna.radiowaves.left.and.right.slash"
        case .connecting, .connected: "antenna.radiowaves.left.and.right"
        }
    }

    public var tone: StatusTone {
        switch self {
        case .disconnected: .critical
        case .connecting: .warning
        case .connected: .positive
        }
    }
}

/// Capsule with a tinted icon and short text, e.g. the GPS Feed or connection state.
public struct StatusPill: View {
    private let text: String
    private let systemImage: String
    private let tone: StatusTone

    public init(text: String, systemImage: String, tone: StatusTone) {
        self.text = text
        self.systemImage = systemImage
        self.tone = tone
    }

    public init(gps status: GPSFeedStatus) {
        self.init(text: status.text, systemImage: status.systemImage, tone: status.tone)
    }

    public init(connection status: ConnectionStatus) {
        self.init(text: status.text, systemImage: status.systemImage, tone: status.tone)
    }

    public var body: some View {
        // HStack rather than Label: inside a List, Label pads its icon to the row's icon column.
        HStack(spacing: MCSpacing.xs + 2) {
            Image(systemName: systemImage).foregroundStyle(tone.color)
            Text(text)
        }
        .font(.footnote.weight(.medium))
        .lineLimit(1)
        .padding(.horizontal, MCSpacing.s + 2)
        .padding(.vertical, MCSpacing.xs + 2)
        .background(Capsule().fill(MCColor.chipBackground))
        .accessibilityElement(children: .combine)
    }
}
