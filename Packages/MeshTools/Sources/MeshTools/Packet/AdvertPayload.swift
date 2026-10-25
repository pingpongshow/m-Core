import Foundation
import MeshCoreKit

/// A node's signed identity broadcast (`PAYLOAD_TYPE_ADVERT`).
///
/// Layout: public key (32), timestamp (u32 LE), Ed25519 signature (64), app data (≤ 32).
/// The signature covers public key + timestamp + app data; it isn't verified here.
public struct AdvertPayload: Equatable, Hashable, Sendable {
    /// App-data flag bits (`ADV_*_MASK`); the low nibble is the node type.
    public enum Flag {
        public static let location: UInt8 = 0x10
        public static let feature1: UInt8 = 0x20
        public static let feature2: UInt8 = 0x40
        public static let name: UInt8 = 0x80
    }

    public static let fixedSize = MeshCoreProtocol.publicKeySize + 4 + MeshCoreProtocol.signatureSize
    /// Firmware ignores app data beyond this (`MAX_ADVERT_DATA_SIZE`).
    public static let maxAppDataSize = 32

    public let publicKey: PublicKey
    /// Sender's clock when it emitted the advert (Unix seconds).
    public let timestamp: UInt32
    public let signature: [UInt8]
    /// App data as received, capped at 32 bytes.
    public let appData: Data
    /// First app-data byte; 0 when app data is missing.
    public let flags: UInt8
    /// False when app data is missing or shorter than its flags promise; optional fields are then nil.
    public let isAppDataValid: Bool
    public let latitudeE6: Int32?
    public let longitudeE6: Int32?
    public let feature1: UInt16?
    public let feature2: UInt16?
    public let name: String?

    public init?(payload: Data) {
        let bytes = [UInt8](payload)
        guard bytes.count >= Self.fixedSize,
              let key = PublicKey(bytes: Array(bytes[0..<32]))
        else { return nil }
        publicKey = key
        timestamp = Self.u32(bytes, at: 32)
        signature = Array(bytes[36..<100])
        let app = Array(bytes[100...].prefix(Self.maxAppDataSize))
        appData = Data(app)

        let parsed = Self.parseAppData(app)
        flags = app.first ?? 0
        isAppDataValid = parsed.valid
        latitudeE6 = parsed.latitude
        longitudeE6 = parsed.longitude
        feature1 = parsed.feature1
        feature2 = parsed.feature2
        name = parsed.name
    }

    public var type: AdvertType { AdvertType(rawValue: flags & 0x0F) }
    public var latitude: Double? { latitudeE6.map { Double($0) / 1e6 } }
    public var longitude: Double? { longitudeE6.map { Double($0) / 1e6 } }
    public var timestampDate: Date { Date(timeIntervalSince1970: TimeInterval(timestamp)) }

    private struct AppData {
        var valid = false
        var latitude: Int32?
        var longitude: Int32?
        var feature1: UInt16?
        var feature2: UInt16?
        var name: String?
    }

    /// Mirrors `AdvertDataParser`: optional fields appear in flag order; the name is the remainder.
    private static func parseAppData(_ app: [UInt8]) -> AppData {
        var result = AppData()
        guard let flags = app.first else { return result }
        var needed = 1
        if flags & Flag.location != 0 { needed += 8 }
        if flags & Flag.feature1 != 0 { needed += 2 }
        if flags & Flag.feature2 != 0 { needed += 2 }
        guard app.count >= needed else { return result }

        var index = 1
        if flags & Flag.location != 0 {
            result.latitude = Int32(bitPattern: u32(app, at: index))
            result.longitude = Int32(bitPattern: u32(app, at: index + 4))
            index += 8
        }
        if flags & Flag.feature1 != 0 {
            result.feature1 = UInt16(app[index]) | UInt16(app[index + 1]) << 8
            index += 2
        }
        if flags & Flag.feature2 != 0 {
            result.feature2 = UInt16(app[index]) | UInt16(app[index + 1]) << 8
            index += 2
        }
        if flags & Flag.name != 0, index < app.count {
            let nameBytes = app[index...]
            let end = nameBytes.firstIndex(of: 0) ?? nameBytes.endIndex
            let text = String(decoding: nameBytes[..<end], as: UTF8.self)
            result.name = text.isEmpty ? nil : text
        }
        result.valid = true
        return result
    }

    private static func u32(_ bytes: [UInt8], at index: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[index + $1]) << (8 * UInt32($1)) }
    }
}
