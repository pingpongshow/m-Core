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
    }

    private let state: Mutex<State>

    public init(state: State = MockRadio.sampleState) {
        self.state = Mutex(state)
    }

    public var current: State { state.withLock { $0 } }

    public func update(_ change: (inout State) -> Void) {
        state.withLock { change(&$0) }
    }

    /// A transport wired to this radio.
    public func makeTransport() -> MockTransport {
        MockTransport(responder: { [self] frame in respond(to: frame) })
    }

    /// Reply frames for one command frame.
    public func respond(to frame: Data) -> [Data] {
        let responses = state.withLock { state in Self.responses(to: frame, state: &state) }
        return responses.compactMap { RadioFrameEncoder.encode($0) }
    }

    private static func responses(to frame: Data, state: inout State) -> [Response] {
        guard let first = frame.first, let code = CommandCode(rawValue: first) else {
            return [.error(.unsupportedCommand)]
        }
        var reader = ByteReader(frame, code: first, offset: 1)
        switch code {
        case .deviceQuery:
            return [.deviceInfo(state.device)]
        case .appStart:
            return [.selfInfo(state.selfInfo)]
        case .getDeviceTime:
            return [.currentTime(state.clock)]
        case .setDeviceTime:
            guard let time = try? reader.u32() else { return [.error(.illegalArgument)] }
            guard time >= state.clock else { return [.error(.illegalArgument)] }
            state.clock = time
            return [.ok(nil)]
        case .getContacts:
            let since = reader.remaining >= 4 ? (try? reader.u32()) ?? 0 : 0
            let changed = state.contacts.filter { $0.lastModified > since }
            let lastModified = changed.map(\.lastModified).max() ?? 0
            return [.contactsStart(count: UInt32(state.contacts.count))]
                + changed.map(Response.contact)
                + [.endOfContacts(lastModified: lastModified)]
        case .syncNextMessage:
            return state.queuedMessages.isEmpty ? [.noMoreMessages] : [state.queuedMessages.removeFirst()]
        case .getBatteryAndStorage:
            return [.batteryAndStorage(state.battery)]
        case .getCustomVars:
            return [.customVars(state.customVars)]
        case .setAdvertLatLon:
            guard let lat = try? reader.i32(), let lon = try? reader.i32(),
                  abs(Int(lat)) <= 90_000_000, abs(Int(lon)) <= 180_000_000 else {
                return [.error(.illegalArgument)]
            }
            state.selfInfo.latitudeE6 = lat
            state.selfInfo.longitudeE6 = lon
            return [.ok(nil)]
        case .setAdvertName:
            state.selfInfo.name = reader.restString()
            return [.ok(nil)]
        case .sendSelfAdvert:
            return [.ok(nil)]
        default:
            return [.error(.unsupportedCommand)]
        }
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
