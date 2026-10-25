import Foundation
import MeshCoreKit

/// The JWT-style token MeshCore MQTT brokers (LetsMesh and compatible) accept as a password.
///
/// `base64url(header) "." base64url(payload) "." UPPERHEX(signature)`, where the signature is
/// Ed25519 by the node's own key over the UTF-8 bytes of `base64url(header) "." base64url(payload)`.
/// The header is `{"alg":"Ed25519","typ":"JWT"}`; the payload is `{"publicKey":…,"iat":…,"exp":…}`
/// followed by any extra claims, compact and in that order.
public enum MeshCoreAuthToken {
    /// Signs bytes with the node's private key (on a companion radio, via its sign command).
    public typealias Signer = @Sendable (Data) async throws -> Data

    public enum TokenError: Error, Equatable, Sendable {
        /// The signer returned something other than a 64-byte Ed25519 signature.
        case invalidSignatureLength(Int)
    }

    /// Default token lifetime used by the community bridge.
    public static let defaultLifetime: TimeInterval = 3600

    /// MQTT username paired with the token: `v1_` + uppercase public key hex.
    public static func username(for publicKey: PublicKey) -> String {
        "v1_" + publicKey.hex.uppercased()
    }

    /// The text to sign: `base64url(header).base64url(payload)`.
    public static func signingInput(
        publicKey: PublicKey,
        issuedAt: Date,
        lifetime: TimeInterval = defaultLifetime,
        claims: [(String, String)] = []
    ) -> String {
        let header = OrderedJSON.object([("alg", .string("Ed25519")), ("typ", .string("JWT"))])
        let iat = Int(issuedAt.timeIntervalSince1970.rounded(.down))
        var members: [(String, OrderedJSON)] = [
            ("publicKey", .string(publicKey.hex.uppercased())),
            ("iat", .int(iat)),
            ("exp", .int(iat + Int(lifetime))),
        ]
        for (name, value) in claims {
            if let index = members.firstIndex(where: { $0.0 == name }) {
                members[index].1 = .string(value)
            } else {
                members.append((name, .string(value)))
            }
        }
        let payload = OrderedJSON.object(members)
        return base64URL(header.serialized(asciiOnly: true)) + "." + base64URL(payload.serialized(asciiOnly: true))
    }

    /// Builds and signs a token.
    /// - Parameter claims: extra string claims appended in order, e.g. `[("aud", "mqtt-us-v1.letsmesh.net")]`.
    public static func make(
        publicKey: PublicKey,
        issuedAt: Date = Date(),
        lifetime: TimeInterval = defaultLifetime,
        claims: [(String, String)] = [],
        signer: Signer
    ) async throws -> String {
        let input = signingInput(publicKey: publicKey, issuedAt: issuedAt, lifetime: lifetime, claims: claims)
        let signature = try await signer(Data(input.utf8))
        guard signature.count == MeshCoreProtocol.signatureSize else {
            throw TokenError.invalidSignatureLength(signature.count)
        }
        return input + "." + signature.hexString.uppercased()
    }

    /// Base64url without padding.
    static func base64URL(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
