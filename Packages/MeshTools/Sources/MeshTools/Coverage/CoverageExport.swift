import Foundation

/// One point of a coverage walk/drive: where you were and whether the radio heard back.
public struct CoverageSample: Equatable, Hashable, Sendable, Codable {
    public var time: Date
    public var coordinate: GeoCoordinate
    public var snr: Double?
    public var rssi: Int?
    /// Whether the ping/ack succeeded at this point.
    public var success: Bool
    public var note: String?

    public init(time: Date, coordinate: GeoCoordinate, snr: Double? = nil, rssi: Int? = nil, success: Bool, note: String? = nil) {
        self.time = time
        self.coordinate = coordinate
        self.snr = snr
        self.rssi = rssi
        self.success = success
        self.note = note
    }
}

/// Writes coverage samples as GPX 1.1 or CSV.
public enum CoverageExport {
    /// XML namespace of the `<mcore:…>` extension elements (snr, rssi, success).
    public static let gpxExtensionNamespace = "urn:m-core:coverage:1"

    /// What a GPX file contains.
    public struct GPXContent: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        /// One `<wpt>` per sample.
        public static let waypoints = GPXContent(rawValue: 1)
        /// One `<trk>` with a `<trkpt>` per sample, in time order.
        public static let track = GPXContent(rawValue: 2)
    }

    public static func gpx(
        _ samples: [CoverageSample],
        name: String = "m-Core coverage",
        content: GPXContent = [.waypoints, .track],
        creator: String = "m-Core"
    ) -> String {
        var lines = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            #"<gpx version="1.1" creator="\#(xmlEscape(creator))" xmlns="http://www.topografix.com/GPX/1/1" "#
                + #"xmlns:mcore="\#(gpxExtensionNamespace)">"#,
            "  <metadata>",
            "    <name>\(xmlEscape(name))</name>",
        ]
        if let first = samples.map(\.time).min() {
            lines.append("    <time>\(isoTime(first))</time>")
        }
        lines.append("  </metadata>")
        if content.contains(.waypoints) {
            for sample in samples {
                lines += point(sample, element: "wpt", indent: "  ", includeName: true)
            }
        }
        if content.contains(.track), !samples.isEmpty {
            lines += ["  <trk>", "    <name>\(xmlEscape(name))</name>", "    <trkseg>"]
            for sample in samples.sorted(by: { $0.time < $1.time }) {
                lines += point(sample, element: "trkpt", indent: "      ", includeName: false)
            }
            lines += ["    </trkseg>", "  </trk>"]
        }
        lines.append("</gpx>")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Columns: time (ISO 8601 UTC), latitude, longitude, snr, rssi, success (true/false), note.
    /// Fields are quoted per RFC 4180 when they contain commas, quotes or line breaks.
    public static func csv(_ samples: [CoverageSample]) -> String {
        var rows = ["time,latitude,longitude,snr,rssi,success,note"]
        for sample in samples {
            rows.append([
                isoTime(sample.time),
                coordinateText(sample.coordinate.latitude),
                coordinateText(sample.coordinate.longitude),
                sample.snr.map(numberText) ?? "",
                sample.rssi.map(String.init) ?? "",
                sample.success ? "true" : "false",
                csvField(sample.note ?? ""),
            ].joined(separator: ","))
        }
        return rows.joined(separator: "\r\n") + "\r\n"
    }

    /// Escapes `&`, `<`, `>`, `"` and `'`, and drops characters XML 1.0 forbids.
    public static func xmlEscape(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default:
                let value = scalar.value
                let allowed = value == 0x9 || value == 0xA || value == 0xD || (0x20...0xD7FF).contains(value)
                    || (0xE000...0xFFFD).contains(value) || value >= 0x10000
                if allowed { out.unicodeScalars.append(scalar) }
            }
        }
        return out
    }

    private static func point(_ sample: CoverageSample, element: String, indent: String, includeName: Bool) -> [String] {
        let lat = coordinateText(sample.coordinate.latitude)
        let lon = coordinateText(sample.coordinate.longitude)
        var lines = ["\(indent)<\(element) lat=\"\(lat)\" lon=\"\(lon)\">", "\(indent)  <time>\(isoTime(sample.time))</time>"]
        if includeName {
            lines.append("\(indent)  <name>\(sample.success ? "OK" : "Miss")\(sample.snr.map { " \(numberText($0)) dB" } ?? "")</name>")
        }
        if let note = sample.note, !note.isEmpty {
            lines.append("\(indent)  <desc>\(xmlEscape(note))</desc>")
        }
        lines.append("\(indent)  <extensions>")
        if let snr = sample.snr { lines.append("\(indent)    <mcore:snr>\(numberText(snr))</mcore:snr>") }
        if let rssi = sample.rssi { lines.append("\(indent)    <mcore:rssi>\(rssi)</mcore:rssi>") }
        lines.append("\(indent)    <mcore:success>\(sample.success)</mcore:success>")
        lines += ["\(indent)  </extensions>", "\(indent)</\(element)>"]
        return lines
    }

    private static func csvField(_ text: String) -> String {
        guard text.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func coordinateText(_ value: Double) -> String {
        String(format: "%.7f", value)
    }

    /// Shortest form with up to two decimals (SNR has 0.25 dB steps).
    private static func numberText(_ value: Double) -> String {
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }

    private static func isoTime(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: .gmt))
    }
}
