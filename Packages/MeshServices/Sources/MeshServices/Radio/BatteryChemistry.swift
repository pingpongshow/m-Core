import Foundation

/// The kind of battery powering a radio, which decides how its voltage maps to charge left.
///
/// MeshCore firmware only reports the battery voltage (`getBattMilliVolts()`); the percentage is the app's estimate.
/// Most boards (Heltec, RAK WisBlock, LilyGO T-Echo/T-Beam, Seeed) run on a single Li-ion/LiPo cell. Solar repeaters
/// often use a LiFePO4 cell, and some builds run from three AA NiMH cells.
public enum BatteryChemistry: String, Codable, CaseIterable, Sendable {
    case lithiumIon
    case lithiumIronPhosphate
    case nickelMetalHydride3Cell

    public var title: String {
        switch self {
        case .lithiumIon: "Li‑ion / LiPo"
        case .lithiumIronPhosphate: "LiFePO4"
        case .nickelMetalHydride3Cell: "NiMH (3 cells)"
        }
    }

    /// Resting (open-circuit) voltage in millivolts against state of charge in percent, rising.
    /// Readings between points are interpolated linearly; readings outside are clamped to 0 or 100.
    public var curve: [(millivolts: Int, percent: Int)] {
        switch self {
        case .lithiumIon:
            // Typical single-cell LiCoO2/NMC rest curve: flat 3.7–3.9 V plateau, steep below 3.7 V.
            [(3_270, 0), (3_610, 5), (3_690, 10), (3_710, 15), (3_730, 20), (3_750, 25), (3_770, 30), (3_790, 35),
             (3_800, 40), (3_820, 45), (3_840, 50), (3_850, 55), (3_870, 60), (3_910, 65), (3_950, 70), (3_980, 75),
             (4_020, 80), (4_080, 85), (4_110, 90), (4_150, 95), (4_200, 100)]
        case .lithiumIronPhosphate:
            // Single LiFePO4 cell: very flat 3.2–3.3 V plateau; 3.40 V at rest is full (3.65 V only while charging).
            [(2_500, 0), (3_000, 10), (3_200, 20), (3_220, 30), (3_250, 40), (3_260, 50), (3_270, 60), (3_300, 70),
             (3_320, 80), (3_350, 90), (3_400, 100)]
        case .nickelMetalHydride3Cell:
            // Three NiMH cells in series (per cell 1.00–1.40 V).
            [(3_000, 0), (3_450, 10), (3_600, 20), (3_660, 30), (3_720, 40), (3_750, 50), (3_780, 60), (3_840, 70),
             (3_900, 80), (4_050, 90), (4_200, 100)]
        }
    }

    /// Estimated charge (0–100) for a voltage reading, or nil for a missing (zero) reading.
    public func percent(millivolts: Int) -> Int? {
        guard millivolts > 0 else { return nil }
        let points = curve
        guard let first = points.first, let last = points.last else { return nil }
        if millivolts <= first.millivolts { return first.percent }
        if millivolts >= last.millivolts { return last.percent }
        for (lower, upper) in zip(points, points.dropFirst()) where millivolts <= upper.millivolts {
            let fraction = Double(millivolts - lower.millivolts) / Double(upper.millivolts - lower.millivolts)
            return Int((Double(lower.percent) + fraction * Double(upper.percent - lower.percent)).rounded())
        }
        return last.percent
    }

    /// "3.92 V · 71%".
    public func describe(millivolts: Int) -> String {
        let volts = String(format: "%.2f V", Double(millivolts) / 1000)
        guard let percent = percent(millivolts: millivolts) else { return volts }
        return "\(volts) · \(percent)%"
    }
}
