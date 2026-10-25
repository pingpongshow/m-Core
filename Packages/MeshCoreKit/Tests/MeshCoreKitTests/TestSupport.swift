import Foundation
@testable import MeshCoreKit

/// Joins hex fragments into Data. Fragments mirror firmware fields so fixtures read like the layout.
func hex(_ parts: String...) -> Data {
    guard let data = Data(hexString: parts.joined()) else { fatalError("bad hex fixture: \(parts)") }
    return data
}

/// `count` zero bytes as hex.
func zeros(_ count: Int) -> String {
    String(repeating: "00", count: count)
}

/// UTF-8 of `text`, NUL-padded to `width` bytes, as hex.
func padded(_ text: String, _ width: Int) -> String {
    let bytes = Array(text.utf8)
    return Data(bytes + [UInt8](repeating: 0, count: width - bytes.count)).hexString
}

func utf8Hex(_ text: String) -> String {
    Data(text.utf8).hexString
}

/// Public key 00 01 02 … 1f.
let sampleKey = PublicKey(bytes: (0..<32).map { UInt8($0) })!
let sampleKeyHex = Data((0..<32).map { UInt8($0) }).hexString

/// Public key a0 a1 … bf.
let otherKey = PublicKey(bytes: (0..<32).map { UInt8(0xA0 + $0) })!
let otherKeyHex = Data((0..<32).map { UInt8(0xA0 + $0) }).hexString

let samplePrefix = KeyPrefix([0x01, 0x02, 0x03, 0x04, 0x05, 0x06])

func decodeResponse(_ data: Data) throws -> Response {
    guard case .response(let response) = try Frame.decode(data) else {
        fatalError("expected a response frame")
    }
    return response
}

func decodePush(_ data: Data) throws -> Push {
    guard case .push(let push) = try Frame.decode(data) else {
        fatalError("expected a push frame")
    }
    return push
}
