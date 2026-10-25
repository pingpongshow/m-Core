import SwiftUI

/// Link quality bucket derived from LoRa SNR (dB). Negative SNR is normal for LoRa.
public enum SignalLevel: Int, Sendable, Comparable, CaseIterable {
    case noSignal = 0
    case weak
    case fair
    case good
    case excellent

    public init(snr: Double?) {
        guard let snr else {
            self = .noSignal
            return
        }
        switch snr {
        case 5...: self = .excellent
        case 0..<5: self = .good
        case -7..<0: self = .fair
        case -15 ..< -7: self = .weak
        default: self = .noSignal
        }
    }

    public var label: String {
        switch self {
        case .noSignal: "No signal"
        case .weak: "Weak"
        case .fair: "Fair"
        case .good: "Good"
        case .excellent: "Excellent"
        }
    }

    public static func < (lhs: SignalLevel, rhs: SignalLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Four-bar signal meter.
public struct SignalBars: View {
    private let level: SignalLevel

    public init(level: SignalLevel) {
        self.level = level
    }

    public init(snr: Double?) {
        self.init(level: SignalLevel(snr: snr))
    }

    public var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...4, id: \.self) { bar in
                RoundedRectangle(cornerRadius: 1)
                    .fill(bar <= level.rawValue ? tint : Color.secondary.opacity(0.3))
                    .frame(width: 3, height: CGFloat(3 + bar * 3))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Signal: \(level.label)")
    }

    private var tint: Color {
        switch level {
        case .excellent, .good: MCColor.positive
        case .fair: MCColor.warning
        case .weak: MCColor.critical
        case .noSignal: .secondary
        }
    }
}
