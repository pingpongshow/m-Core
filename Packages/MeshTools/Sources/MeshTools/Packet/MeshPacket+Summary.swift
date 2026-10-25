import Foundation
import MeshCoreKit

extension MeshPacket: CustomStringConvertible {
    /// One-line description, e.g. "Advert · Charlie Node · flood · 2 hops".
    public var summary: String {
        var parts = [payloadType.name]
        if let advert {
            parts.append(advert.name ?? "key \(advert.publicKey.prefix.hex.uppercased())")
        } else if let hashes = addressHashes {
            parts.append(String(format: "%02X → %02X", hashes.source, hashes.destination))
        } else if let channelHash {
            parts.append(String(format: "channel %02X", channelHash))
        }
        parts.append(routeType.name)
        parts.append(hopCount == 1 ? "1 hop" : "\(hopCount) hops")
        return parts.joined(separator: " · ")
    }

    public var description: String { summary }
}

/// LoRa link estimates matching what the firmware logs for each received packet.
public enum LoRaEstimate {
    /// Minimum SNR (dB) for reception at SF7…SF12 (firmware `snr_threshold`).
    static let snrThresholds: [Double] = [-7.5, -10, -12.5, -15, -17.5, -20]

    /// The firmware's packet score (0…1): SNR margin over the SF's threshold / 10, times `1 − length/256`.
    public static func packetScore(snr: Double, spreadingFactor: Int, packetLength: Int) -> Double {
        guard (7...12).contains(spreadingFactor) else { return 0 }
        let threshold = snrThresholds[spreadingFactor - 7]
        guard snr >= threshold else { return 0 }
        let score = (snr - threshold) / 10 * (1 - Double(packetLength) / 256)
        return min(1, max(0, score))
    }

    /// Preamble symbols MeshCore configures (`preambleLengthForSF`): 32 at SF ≤ 8, otherwise 16.
    public static func preambleSymbols(spreadingFactor: Int) -> Int {
        spreadingFactor <= 8 ? 32 : 16
    }

    /// Semtech time-on-air in milliseconds for an explicit-header, CRC-on LoRa packet.
    /// Low-data-rate optimisation is assumed when a symbol lasts 16 ms or more.
    public static func airtimeMilliseconds(
        payloadLength: Int,
        spreadingFactor: Int,
        bandwidthKHz: Double,
        codingRate: Int,
        preambleSymbols: Int? = nil
    ) -> Double {
        guard spreadingFactor > 0, bandwidthKHz > 0 else { return 0 }
        let sf = Double(spreadingFactor)
        let symbolMs = pow(2, sf) / bandwidthKHz
        let lowDataRate = symbolMs >= 16 ? 1.0 : 0.0
        let cr = Double(min(max(codingRate, 5), 8) - 4)
        let preamble = Double(preambleSymbols ?? Self.preambleSymbols(spreadingFactor: spreadingFactor))
        let numerator = 8 * Double(payloadLength) - 4 * sf + 28 + 16
        let payloadSymbols = 8 + max(ceil(numerator / (4 * (sf - 2 * lowDataRate))) * (cr + 4), 0)
        return (preamble + 4.25 + payloadSymbols) * symbolMs
    }
}
