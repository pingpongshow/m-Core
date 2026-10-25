import Foundation

/// A JSON value written with keys in insertion order and compact separators, like Python's
/// `json.dumps(..., separators=(",", ":"))`.
enum OrderedJSON: Sendable, Equatable {
    case string(String)
    case int(Int)
    case object([(String, OrderedJSON)])

    static func == (lhs: OrderedJSON, rhs: OrderedJSON) -> Bool {
        lhs.serialized() == rhs.serialized()
    }

    /// - Parameter asciiOnly: escape non-ASCII as `\uXXXX` (Python's default `ensure_ascii`).
    func serialized(asciiOnly: Bool = false) -> String {
        var out = ""
        write(into: &out, asciiOnly: asciiOnly)
        return out
    }

    private func write(into out: inout String, asciiOnly: Bool) {
        switch self {
        case .string(let value):
            Self.writeString(value, into: &out, asciiOnly: asciiOnly)
        case .int(let value):
            out += String(value)
        case .object(let members):
            out += "{"
            for (index, member) in members.enumerated() {
                if index > 0 { out += "," }
                Self.writeString(member.0, into: &out, asciiOnly: asciiOnly)
                out += ":"
                member.1.write(into: &out, asciiOnly: asciiOnly)
            }
            out += "}"
        }
    }

    private static func writeString(_ value: String, into out: inout String, asciiOnly: Bool) {
        out += "\""
        for unit in value.unicodeScalars {
            switch unit {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if unit.value < 0x20 || (asciiOnly && unit.value > 0x7F) {
                    for codeUnit in String(unit).utf16 {
                        out += String(format: "\\u%04x", codeUnit)
                    }
                } else {
                    out.unicodeScalars.append(unit)
                }
            }
        }
        out += "\""
    }
}
