import CoreImage.CIFilterBuiltins
import CoreLocation
import Foundation
import MeshCoreKit
import MeshDesign
import MeshServices
import MeshStore
import Security
import SwiftUI
import UIKit

extension AdvertType {
    var avatarKind: AvatarKind {
        switch self {
        case .repeater: .repeater
        case .room: .room
        case .sensor: .sensor
        default: .contact
        }
    }
}

extension ContactRecord {
    var advertType: AdvertType { AdvertType(rawValue: UInt8(clamping: typeRaw)) }

    var avatarKind: AvatarKind { advertType.avatarKind }

    var coordinate: CLLocationCoordinate2D? {
        hasLocation ? CLLocationCoordinate2D(latitude: Double(latitudeE6) / 1e6, longitude: Double(longitudeE6) / 1e6) : nil
    }

    var outPathHashes: [String]? {
        guard outPathLength != 255, let path = MeshPath(encodedLength: UInt8(outPathLength), bytes: [UInt8](outPath)) else { return nil }
        return path.hashes.map { Data($0).hexString.uppercased() }
    }

    var hopsText: String {
        guard let hashes = outPathHashes else { return "Flood" }
        return hashes.isEmpty ? "Direct" : "\(hashes.count) hop\(hashes.count == 1 ? "" : "s")"
    }
}

extension ChannelRecord {
    var avatarKind: AvatarKind {
        if isPublic { return .publicChannel }
        return isHashtag ? .hashtagChannel : .privateChannel
    }

    var kindText: String {
        if isPublic { return "Public channel" }
        return isHashtag ? "Hashtag channel" : "Private channel"
    }
}

/// One phone location fix, for "Send my location" and distance displays.
@MainActor
enum PhoneLocation {
    static func current(timeout: Duration = .seconds(10)) async -> CLLocation? {
        let session = CLServiceSession(authorization: .whenInUse)
        defer { session.invalidate() }
        return await withTaskGroup(of: CLLocation?.self) { group in
            group.addTask {
                do {
                    for try await update in CLLocationUpdate.liveUpdates() {
                        if let location = update.location, location.horizontalAccuracy >= 0 { return location }
                        if update.authorizationDenied || update.authorizationDeniedGlobally || update.authorizationRestricted { return nil }
                    }
                } catch {
                    return nil
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let result = await group.next().flatMap { $0 }
            group.cancelAll()
            return result
        }
    }
}

/// QR code image for a string.
enum QRCode {
    static func image(for text: String, scale: CGFloat = 10) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// The observer's custom broker password, kept in the Keychain.
final class KeychainSecretStore: SecretStore {
    func secret(for key: String) -> String? { Keychain.password(for: key) }
    func setSecret(_ value: String?, for key: String) { Keychain.setPassword(value, for: key) }
}

/// Small Keychain wrapper for room and repeater passwords.
enum Keychain {
    private static let service = "app.mcore.passwords"

    static func password(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setPassword(_ password: String?, for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard let password, !password.isEmpty else { return }
        var attributes = query
        attributes[kSecValueData as String] = Data(password.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }
}

/// `meshcore://` links for sharing contacts and channels.
enum MeshLink {
    case contact(name: String, keyHex: String, type: Int)
    case channel(name: String, secretHex: String)

    var url: URL {
        var components = URLComponents()
        components.scheme = "meshcore"
        switch self {
        case let .contact(name, keyHex, type):
            components.host = "contact"
            components.path = "/add"
            components.queryItems = [
                URLQueryItem(name: "name", value: name),
                URLQueryItem(name: "public_key", value: keyHex),
                URLQueryItem(name: "type", value: String(type)),
            ]
        case let .channel(name, secretHex):
            components.host = "channel"
            components.path = "/add"
            components.queryItems = [URLQueryItem(name: "name", value: name), URLQueryItem(name: "secret", value: secretHex)]
        }
        return components.url!
    }

    init?(url: URL) {
        guard url.scheme == "meshcore", let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        switch url.host {
        case "contact":
            guard let key = items["public_key"], PublicKey(hex: key) != nil else { return nil }
            self = .contact(name: items["name"] ?? "", keyHex: key.lowercased(), type: Int(items["type"] ?? "1") ?? 1)
        case "channel":
            guard let name = items["name"], !name.isEmpty else { return nil }
            self = .channel(name: name, secretHex: items["secret"] ?? "")
        default:
            return nil
        }
    }
}

extension Date {
    /// "9:41 AM" today, "Yesterday", the weekday for the last six days, otherwise a short date
    /// (also for future dates from a sender whose clock is ahead).
    func chatListText(now: Date = .now, calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: self), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case 0: return formatted(date: .omitted, time: .shortened)
        case 1: return "Yesterday"
        case 2..<7: return formatted(.dateTime.weekday(.wide))
        default: return formatted(date: .numeric, time: .omitted)
        }
    }
}

/// Hands a coordinate to Apple Maps.
enum AppleMaps {
    @MainActor
    static func open(latitude: Double, longitude: Double, label: String) {
        var components = URLComponents(string: "maps://")!
        components.queryItems = [
            URLQueryItem(name: "ll", value: "\(latitude),\(longitude)"),
            URLQueryItem(name: "q", value: label),
        ]
        if let url = components.url { UIApplication.shared.open(url) }
    }
}

/// A short sentence for an error shown in a status line, e.g. "The radio isn't connected." rather than `notConnected`.
func errorMessage(_ error: any Error) -> String {
    switch error {
    case is DecodingError:
        return "The file isn't in the expected format."
    case let error as LocalizedError where error.errorDescription != nil:
        // The packages' errors describe themselves in user-facing sentences.
        return error.errorDescription ?? ""
    default:
        // Foundation and system errors describe themselves; anything else prints its case.
        if type(of: error) is NSError.Type || error is any CustomNSError { return error.localizedDescription }
        return String(describing: error)
    }
}

/// Y axis ranges for line charts.
enum ChartScale {
    /// The values' range with some room above and below. Charts' automatic scale collapses (and draws inverted axis
    /// labels, or none) when every value is the same, as with a steady battery voltage or noise floor.
    static func paddedDomain(_ values: [Double]) -> ClosedRange<Double> {
        guard let low = values.min(), let high = values.max() else { return 0...1 }
        let padding = max((high - low) * 0.1, abs(high) * 0.05, 0.1)
        return (low - padding)...(high + padding)
    }
}
