import Foundation
import MeshCoreKit
import MeshTools
import Observation

/// One packet the radio heard, decoded where possible.
public struct RxLogRecord: Identifiable, Equatable, Sendable {
    public let id: Int
    public var date: Date
    public var snr: Double
    public var rssi: Int
    public var raw: Data
    /// Nil when the bytes don't parse as a MeshCore packet.
    public var packet: MeshPacket?
}

/// Live log of every packet the radio receives (`PUSH_CODE_LOG_RX_DATA`), kept in memory only.
@MainActor
@Observable
public final class RxLogService: RadioEventHandler {
    public private(set) var records: [RxLogRecord] = []
    public var isPaused = false
    /// Packets heard since launch, including ones dropped from `records`.
    public private(set) var totalHeard = 0

    @ObservationIgnored private let limit: Int
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var nextID = 0

    public init(radio: RadioController, limit: Int = 2_000, now: @escaping () -> Date = { Date() }) {
        self.limit = limit
        self.now = now
        radio.addHandler(self)
    }

    public func clear() {
        records = []
    }

    /// Records grouped by payload type name, most common first.
    public var countsByType: [(name: String, count: Int)] {
        Dictionary(grouping: records) { $0.packet?.payloadType.name ?? "Unknown" }
            .map { (name: $0.key, count: $0.value.count) }
            .sorted { $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count }
    }

    /// The records as CSV, oldest first. Columns: time (ISO 8601 UTC), snr (dB), rssi (dBm), type, route, hops,
    /// hash and raw (both hex). Undecodable packets leave the decoded columns empty. Lines end in CRLF (RFC 4180).
    nonisolated public static func csv(_ records: [RxLogRecord]) -> String {
        var rows = ["time,snr,rssi,type,route,hops,hash,raw"]
        for record in records.sorted(by: { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }) {
            let packet = record.packet
            rows.append([
                record.date.formatted(Date.ISO8601FormatStyle(timeZone: .gmt)),
                snrText(record.snr),
                String(record.rssi),
                csvField(packet?.payloadType.name ?? ""),
                csvField(packet?.routeType.name ?? ""),
                packet.map { String($0.hopCount) } ?? "",
                packet?.hashHex ?? "",
                record.raw.hexString.uppercased(),
            ].joined(separator: ","))
        }
        return rows.joined(separator: "\r\n") + "\r\n"
    }

    nonisolated private static func csvField(_ text: String) -> String {
        guard text.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Up to two decimals (SNR comes in 0.25 dB steps), no trailing zeros.
    nonisolated private static func snrText(_ value: Double) -> String {
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }

    // MARK: RadioEventHandler

    public func radioDidConnect(_ info: ConnectionInfo, session: MeshSession) async {}

    public func radioDidDisconnect() {}

    public func radioDidReceive(_ push: Push, session: MeshSession) async {
        guard case .rxLog(let entry) = push else { return }
        totalHeard += 1
        guard !isPaused else { return }
        let record = RxLogRecord(
            id: nextID, date: now(), snr: entry.snr, rssi: Int(entry.rssi), raw: entry.raw,
            packet: MeshPacket.decode(entry.raw)
        )
        nextID += 1
        records.insert(record, at: 0)
        if records.count > limit { records.removeLast(records.count - limit) }
    }
}
