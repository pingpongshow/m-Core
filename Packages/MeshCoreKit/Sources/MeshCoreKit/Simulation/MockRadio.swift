import Foundation
import Synchronization

/// A simulated companion radio that answers commands like the firmware does. Pair it with
/// `MockTransport` to test sessions or run the UI without hardware.
public final class MockRadio: Sendable {
    public struct State: Sendable {
        public var device: DeviceInfo
        public var selfInfo: SelfInfo
        /// Radio clock (Unix seconds).
        public var clock: UInt32
        public var contacts: [Contact]
        public var queuedMessages: [Response]
        public var battery: BatteryAndStorage
        public var customVars: [String: String]
        /// Number of `sendSelfAdvert` commands received.
        public var advertsSent = 0
        /// Number of position writes (`setAdvertLatLon`) received; each is a flash write on real radios.
        public var positionWrites = 0
        public var channels: [ChannelInfo] = [
            ChannelInfo(index: 0, name: "Public", secret: [UInt8](Data(base64Encoded: "izOH6cXN6mrJ5e26oRXNcg==")!)),
        ]
        /// Direct messages sent by the app: recipient prefix and text.
        public var sentDirectMessages: [SentDirectMessage] = []
        /// Channel messages sent by the app.
        public var sentChannelMessages: [(index: UInt8, text: String)] = []
        /// Whether sent direct messages are acknowledged straight away.
        public var autoAck = true
        /// Password that room/repeater logins must match.
        public var loginPassword = "password"
        public var pathResets: [PublicKey] = []
        public var nextTag: UInt32 = 0x1000
        /// Raw repeater status payload returned to status requests.
        public var repeaterStatus = Data()
        public var tuning = TuningParams(rxDelayBase: 0, airtimeFactor: 1)
        public var autoAdd = AutoAddConfig(flags: 0x1E, maxHops: 0)
        public var blePin: UInt32 = 123_456
        public var privateKey = Data((0..<64).map { UInt8($0) })
        public var privateKeyExportEnabled = true
        public var reboots = 0
        /// Bytes collected between sign-start and sign-finish.
        public var signBuffer: Data?
        /// Advert packets handed over with import-contact.
        public var importedContacts: [Data] = []
        public var cliCommands: [String] = []
        /// Settings a simulated repeater or room reports and changes through the remote CLI (`get`/`set` keys).
        public var remoteSettings: [String: String] = MockRadio.defaultRemoteSettings
        /// Remote CLI commands received, in order.
        public var remoteCLICommands: [String] = []
        public var clientRepeat = false
    }

    /// A direct message the app sent, as recorded by the simulated radio.
    public struct SentDirectMessage: Sendable {
        public var prefix: KeyPrefix
        public var text: String
        public var attempt: UInt8
    }

    private struct WeakTransport: @unchecked Sendable {
        weak var transport: MockTransport?
    }

    private let state: Mutex<State>
    private let transports = Mutex<[WeakTransport]>([])

    public init(state: State = MockRadio.sampleState) {
        self.state = Mutex(state)
    }

    public var current: State { state.withLock { $0 } }

    public func update(_ change: (inout State) -> Void) {
        state.withLock { change(&$0) }
    }

    /// A transport wired to this radio.
    public func makeTransport() -> MockTransport {
        let transport = MockTransport(responder: { [self] frame in respond(to: frame) })
        transports.withLock { list in
            list.removeAll { $0.transport == nil }
            list.append(WeakTransport(transport: transport))
        }
        return transport
    }

    /// Sends a push frame to every open transport, as if the radio raised it.
    public func push(_ push: Push) {
        guard let frame = RadioFrameEncoder.encode(push) else { return }
        transports.withLock { $0.compactMap(\.transport) }.forEach { $0.inject(frame) }
    }

    /// Drops every open link, as if the radio went out of range or lost power.
    public func simulateDisconnect() {
        transports.withLock { $0.compactMap(\.transport) }.forEach { $0.simulateDisconnect() }
    }

    /// Queues an incoming message and tells the app, like the radio does when a message arrives.
    public func receive(_ message: Response) {
        update { $0.queuedMessages.append(message) }
        push(.messagesWaiting)
    }

    /// Reply frames for one command frame, followed by any pushes the command triggers (ACKs, login results).
    public func respond(to frame: Data) -> [Data] {
        let (responses, pushes) = state.withLock { state in
            let responses = Self.responses(to: frame, state: &state)
            // The firmware only goes on to send (and so gets ACKs, login results, …) when the command succeeded.
            let failed = responses.contains { if case .error = $0 { true } else { false } }
            return (responses, failed ? [] : Self.followUpPushes(to: frame, state: state))
        }
        return responses.compactMap { RadioFrameEncoder.encode($0) } + pushes.compactMap { RadioFrameEncoder.encode($0) }
    }

    private static func followUpPushes(to frame: Data, state: State) -> [Push] {
        guard let first = frame.first, let code = CommandCode(rawValue: first) else { return [] }
        var reader = ByteReader(frame, code: first, offset: 1)
        switch code {
        case .sendTextMessage:
            if frame.count > 1, frame[1] == TextType.cliData.rawValue { return [.messagesWaiting] }
            return state.autoAck ? [.sendConfirmed(SendConfirmation(ackCode: state.nextTag, roundTripMs: 850))] : []
        case .sendBinaryRequest:
            return neighboursPushes(&reader, state: state)
        case .sendLogin:
            guard let bytes = try? reader.bytes(32), let key = PublicKey(bytes: bytes) else { return [] }
            let password = reader.restString()
            return password == state.loginPassword
                ? [.loginSuccess(LoginResult(senderPrefix: key.prefix, permissions: 1, serverTimestamp: state.clock))]
                : [.loginFailed(key.prefix)]
        case .sendTracePath:
            guard let tag = try? reader.u32(), (try? reader.u32()) != nil, let flags = try? reader.u8() else { return [] }
            let hashBytes = reader.rest()
            let hashSize = 1 << Int(flags & 0x03)
            let hops = hashBytes.count / hashSize
            return [.traceData(TraceResult(
                tag: tag, authCode: 0, flags: flags,
                pathHashes: stride(from: 0, to: hashBytes.count, by: hashSize).map { Array(hashBytes[$0..<$0 + hashSize]) },
                hopSNRs: (0..<hops).map { Double(8 - $0 * 2) }, finalSNR: 5.5
            ))]
        case .sendTelemetryRequest:
            return telemetryPushes(&reader, state: state)
        case .sendStatusRequest:
            guard let bytes = try? reader.bytes(32), let key = PublicKey(bytes: bytes) else { return [] }
            return [.statusResponse(StatusResponse(senderPrefix: key.prefix, payload: state.repeaterStatus))]
        case .sendPathDiscoveryRequest:
            _ = try? reader.u8()
            guard let bytes = try? reader.bytes(32), let contact = state.contacts.first(where: { $0.publicKey.bytes == bytes }) else {
                return []
            }
            return [.pathDiscoveryResponse(PathDiscoveryResult(
                senderPrefix: contact.publicKey.prefix,
                outPath: contact.outPath ?? MeshPath(hashSize: 1, hashes: [[0x10]]),
                inPath: contact.outPath.map { MeshPath(hashSize: $0.hashSize, hashes: $0.hashes.reversed()) }
                    ?? MeshPath(hashSize: 1, hashes: [[0x10]])
            ))]
        default:
            return []
        }
    }

    private static func neighboursPushes(_ reader: inout ByteReader, state: State) -> [Push] {
        guard let bytes = try? reader.bytes(32), PublicKey(bytes: bytes) != nil, let requestType = try? reader.u8() else { return [] }
        guard requestType == 0x06 else { return [] }
        // Neighbours reply: total, count, then prefix(6) + heard-seconds-ago (u32) + snr×4 per entry.
        var payload: [UInt8] = [2, 0, 2, 0]
        for (index, contact) in state.contacts.prefix(2).enumerated() {
            payload += contact.publicKey.bytes.prefix(6)
            payload += [UInt8(30 * (index + 1)), 0, 0, 0, UInt8(bitPattern: Int8(24 - index * 12))]
        }
        return [.binaryResponse(BinaryResponse(tag: state.nextTag, payload: Data(payload)))]
    }

    private static func telemetryPushes(_ reader: inout ByteReader, state: State) -> [Push] {
        _ = try? reader.bytes(3)
        if reader.remaining < 32 {
            return [.telemetryResponse(TelemetryResponse(senderPrefix: state.selfInfo.publicKey.prefix, lpp: demoLPP(
                millivolts: state.battery.millivolts, latitudeE6: state.selfInfo.latitudeE6, longitudeE6: state.selfInfo.longitudeE6
            )))]
        }
        guard let bytes = try? reader.bytes(32), let contact = state.contacts.first(where: { $0.publicKey.bytes == bytes }) else {
            return []
        }
        return [.telemetryResponse(TelemetryResponse(
            senderPrefix: contact.publicKey.prefix,
            lpp: demoLPP(millivolts: 3_900, latitudeE6: contact.latitudeE6, longitudeE6: contact.longitudeE6)
        ))]
    }

    public static let samplePublicKey = PublicKey(bytes: (0..<32).map { UInt8($0) })!

    public static var sampleState: State {
        State(
            device: DeviceInfo(
                protocolVersion: 14, maxContacts: 350, maxChannels: 40, blePin: 123_456,
                buildDate: "15 Oct 2026", model: "Heltec V3", firmwareVersion: "v1.18.0",
                clientRepeat: false, pathHashMode: 0
            ),
            selfInfo: SelfInfo(
                advertType: .chat, txPowerDbm: 22, maxTxPowerDbm: 22, publicKey: samplePublicKey,
                latitudeE6: 0, longitudeE6: 0, multiAcks: 0, advertLocationPolicy: 1,
                telemetryModes: TelemetryModes(base: .allowAll, location: .allowFlagged, environment: .deny),
                manualAddContacts: 0,
                radio: RadioParameters(frequencyKHz: 910_525, bandwidthHz: 62_500, spreadingFactor: 7, codingRate: 5),
                name: "m-Core Sim"
            ),
            clock: 1_790_000_000,
            contacts: [],
            queuedMessages: [],
            battery: BatteryAndStorage(millivolts: 4_050, usedKB: 120, totalKB: 1_024),
            customVars: [:]
        )
    }
}

/// CayenneLPP with battery voltage and, when set, GPS — like a MeshCore node's telemetry reply.
func demoLPP(millivolts: UInt16, latitudeE6: Int32, longitudeE6: Int32) -> Data {
    let centivolts = UInt16(millivolts / 10)
    var bytes: [UInt8] = [1, LPPKind.voltage.rawValue, UInt8(centivolts >> 8), UInt8(centivolts & 0xFF)]
    if latitudeE6 != 0 || longitudeE6 != 0 {
        func three(_ value: Int32) -> [UInt8] {
            let raw = UInt32(bitPattern: value / 100) & 0xFFFFFF
            return [UInt8(raw >> 16), UInt8((raw >> 8) & 0xFF), UInt8(raw & 0xFF)]
        }
        bytes += [1, LPPKind.gps.rawValue] + three(latitudeE6) + three(longitudeE6) + [0, 0, 0]
    }
    return Data(bytes)
}
