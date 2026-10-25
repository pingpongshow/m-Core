import Foundation
import MeshCoreKit
import MeshStore
import Observation

/// A repeater's or room server's counters (`RepeaterStats` in the firmware).
public struct RepeaterStatus: Equatable, Sendable {
    public var batteryMillivolts: UInt16
    public var txQueueLength: UInt16
    public var noiseFloor: Int16
    public var lastRSSI: Int16
    public var packetsReceived: UInt32
    public var packetsSent: UInt32
    public var airtimeSeconds: UInt32
    public var uptimeSeconds: UInt32
    public var sentFlood: UInt32
    public var sentDirect: UInt32
    public var receivedFlood: UInt32
    public var receivedDirect: UInt32
    public var errorFlags: UInt16
    public var lastSNR: Double
    public var directDuplicates: UInt16
    public var floodDuplicates: UInt16
    public var rxAirtimeSeconds: UInt32?
    public var receiveErrors: UInt32?

    /// Parses the little-endian struct; the last two fields are newer and optional.
    public init?(payload: Data) {
        let bytes = [UInt8](payload)
        guard bytes.count >= 48 else { return nil }
        var offset = 0
        func u16() -> UInt16 {
            defer { offset += 2 }
            return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
        }
        func u32() -> UInt32 {
            defer { offset += 4 }
            return (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * UInt32($1)) }
        }
        batteryMillivolts = u16()
        txQueueLength = u16()
        noiseFloor = Int16(bitPattern: u16())
        lastRSSI = Int16(bitPattern: u16())
        packetsReceived = u32()
        packetsSent = u32()
        airtimeSeconds = u32()
        uptimeSeconds = u32()
        sentFlood = u32()
        sentDirect = u32()
        receivedFlood = u32()
        receivedDirect = u32()
        errorFlags = u16()
        lastSNR = Double(Int16(bitPattern: u16())) / 4
        directDuplicates = u16()
        floodDuplicates = u16()
        rxAirtimeSeconds = bytes.count >= offset + 4 ? u32() : nil
        receiveErrors = bytes.count >= offset + 4 ? u32() : nil
    }
}

/// A node a repeater hears directly.
public struct Neighbour: Equatable, Hashable, Sendable {
    public var keyPrefixHex: String
    public var heardSecondsAgo: UInt32
    public var snr: Double
}

/// One line of a remote command-line session.
public struct CLIEntry: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public var isCommand: Bool
    public var text: String
    public var date: Date
}

/// Remote administration of repeaters and room servers: login, status, neighbours and the command line.
@MainActor
@Observable
public final class RemoteNodeService: RadioEventHandler {
    /// Logins that succeeded this connection, by node key.
    public private(set) var logins: [String: LoginResult] = [:]
    public private(set) var transcripts: [String: [CLIEntry]] = [:]

    @ObservationIgnored private let radio: RadioController
    @ObservationIgnored private let messaging: MessagingService
    @ObservationIgnored private let statusWaiter = PushWaiter<Data>()
    @ObservationIgnored private let binaryWaiter = PushWaiter<Data>()
    @ObservationIgnored private let cliWaiter = PushWaiter<String>()
    /// Last timestamp sent to each node (key hex). Repeaters and rooms treat a command with the same timestamp as the
    /// previous one as a retry and don't run it, so every command needs a later one.
    @ObservationIgnored private var lastCommandTimestamps: [String: UInt32] = [:]
    @ObservationIgnored private let now: () -> Date

    public init(radio: RadioController, messaging: MessagingService, now: @escaping () -> Date = { Date() }) {
        self.radio = radio
        self.messaging = messaging
        self.now = now
        radio.addHandler(self)
        messaging.onCommandReply = { [weak self] prefixHex, text in self?.receiveCommandReply(prefixHex: prefixHex, text: text) }
    }

    private func session() async throws -> MeshSession {
        guard let session = await radio.session() else { throw RemoteRequestError.notConnected }
        return session
    }

    private func key(_ keyHex: String) throws -> PublicKey {
        guard let key = PublicKey(hex: keyHex) else { throw RemoteRequestError.unknownNode }
        return key
    }

    public func login(keyHex: String, password: String) async throws -> LoginResult {
        let result = try await messaging.login(to: keyHex, password: password)
        logins[keyHex] = result
        // The login carries the radio's current time, which the node also remembers.
        lastCommandTimestamps[keyHex.lowercased()] = max(lastCommandTimestamps[keyHex.lowercased()] ?? 0, Self.seconds(now()))
        return result
    }

    public func status(keyHex: String) async throws -> RepeaterStatus {
        let key = try key(keyHex)
        let sent = try await session().request(.sendStatusRequest(key)) { response -> SentInfo? in
            if case .sent(let info) = response { return info }
            return nil
        }
        let payload = try await statusWaiter.wait(for: key.prefix.hex, timeout: meshTimeout(estimatedMs: sent.estimatedTimeoutMs))
        guard let status = RepeaterStatus(payload: payload) else { throw RemoteRequestError.timedOut }
        return status
    }

    /// Neighbours the repeater hears, strongest first.
    public func neighbours(keyHex: String, count: UInt8 = 20) async throws -> [Neighbour] {
        let key = try key(keyHex)
        let prefixLength: UInt8 = 6
        var request = Data([0x06, 0, count, 0, 0, 2, prefixLength])
        request.append(contentsOf: (0..<4).map { _ in UInt8.random(in: .min ... .max) })
        let sent = try await session().request(.sendBinaryRequest(to: key, data: request)) { response -> SentInfo? in
            if case .sent(let info) = response { return info }
            return nil
        }
        let timeout = meshTimeout(estimatedMs: sent.estimatedTimeoutMs)
        let payload = [UInt8](try await binaryWaiter.wait(for: String(sent.tag), timeout: timeout))
        guard payload.count >= 4 else { return [] }
        let results = Int(UInt16(payload[2]) | UInt16(payload[3]) << 8)
        var neighbours: [Neighbour] = []
        var offset = 4
        let entrySize = Int(prefixLength) + 5
        for _ in 0..<results where offset + entrySize <= payload.count {
            let prefix = Data(payload[offset..<offset + Int(prefixLength)]).hexString
            let base = offset + Int(prefixLength)
            let seconds = (0..<4).reduce(UInt32(0)) { $0 | UInt32(payload[base + $1]) << (8 * UInt32($1)) }
            let snr = Double(Int8(bitPattern: payload[base + 4])) / 4
            neighbours.append(Neighbour(keyPrefixHex: prefix, heardSecondsAgo: seconds, snr: snr))
            offset += entrySize
        }
        return neighbours
    }

    /// Runs a command on a repeater or room (requires an admin login) and returns its reply.
    public func runCommand(_ command: String, keyHex: String, timeout: Duration = .seconds(20)) async throws -> String {
        let key = try key(keyHex)
        append(CLIEntry(isCommand: true, text: command, date: Date()), keyHex: keyHex)
        let timestamp = nextCommandTimestamp(keyHex: key.hex)
        let message = Command.sendTextMessage(to: key.prefix, text: command, timestamp: timestamp, type: .cliData)
        _ = try await session().request(message) { response -> SentInfo? in
            if case .sent(let info) = response { return info }
            return nil
        }
        let reply = try await cliWaiter.wait(for: key.prefix.hex, timeout: timeout)
        return reply
    }

    /// Runs a command on the connected radio itself (firmware protocol v14+).
    public func runLocalCommand(_ command: String) async throws -> String {
        let reply = try await session().runCLICommand(command)
        let selfKey = radio.selfInfo?.publicKey.hex ?? "local"
        append(CLIEntry(isCommand: true, text: command, date: Date()), keyHex: selfKey)
        append(CLIEntry(isCommand: false, text: reply, date: Date()), keyHex: selfKey)
        return reply
    }

    /// Now, or one second after the last command to the node when that was sent within the same second.
    func nextCommandTimestamp(keyHex: String) -> UInt32 {
        let current = Self.seconds(now())
        let timestamp = lastCommandTimestamps[keyHex].map { max(current, $0 &+ 1) } ?? current
        lastCommandTimestamps[keyHex] = timestamp
        return timestamp
    }

    private static func seconds(_ date: Date) -> UInt32 {
        UInt32(clamping: Int64(date.timeIntervalSince1970))
    }

    private func receiveCommandReply(prefixHex: String, text: String) {
        let keyHex = messaging.store?.contact(prefixHex: prefixHex)?.keyHex ?? prefixHex
        append(CLIEntry(isCommand: false, text: text, date: Date()), keyHex: keyHex)
        cliWaiter.resolve(prefixHex, with: .success(text))
    }

    private func append(_ entry: CLIEntry, keyHex: String) {
        transcripts[keyHex, default: []].append(entry)
    }

    // MARK: RadioEventHandler

    public func radioDidConnect(_ info: ConnectionInfo, session: MeshSession) async {
        logins.removeAll()
    }

    public func radioDidDisconnect() {
        statusWaiter.cancelAll()
        binaryWaiter.cancelAll()
        cliWaiter.cancelAll()
    }

    public func radioDidReceive(_ push: Push, session: MeshSession) async {
        switch push {
        case .statusResponse(let response):
            statusWaiter.resolve(response.senderPrefix.hex, with: .success(response.payload))
        case .binaryResponse(let response):
            binaryWaiter.resolve(String(response.tag), with: .success(response.payload))
        default:
            break
        }
    }
}
