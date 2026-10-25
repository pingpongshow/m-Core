import Foundation
import MeshCoreKit
import MeshTools
import Network
import Observation

/// Settings for the optional observer uplink. Off by default.
public struct ObserverSettings: Codable, Equatable, Sendable {
    public enum Broker: String, Codable, CaseIterable, Sendable {
        case letsMeshUS
        case letsMeshEU
        case custom

        public var title: String {
            switch self {
            case .letsMeshUS: "LetsMesh (US)"
            case .letsMeshEU: "LetsMesh (EU)"
            case .custom: "Custom broker"
            }
        }
    }

    public enum CustomTransport: String, Codable, CaseIterable, Sendable {
        case tcp, tls, webSocket, secureWebSocket

        public var title: String {
            switch self {
            case .tcp: "TCP"
            case .tls: "TLS"
            case .webSocket: "WebSocket"
            case .secureWebSocket: "Secure WebSocket"
            }
        }
    }

    public var isEnabled = false
    public var broker: Broker = .letsMeshUS
    /// Three-letter airport code for the observer's region, e.g. "SFO".
    public var iata = ""
    public var wifiOnly = true
    public var customHost = ""
    public var customPort: UInt16 = 1883
    public var customTransport: CustomTransport = .tcp
    public var customPath = "/mqtt"
    public var customUsername = ""
    /// Disconnect while m-Core is in the background and reconnect when it's opened again.
    public var pauseInBackground = false

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case isEnabled, broker, iata, wifiOnly, customHost, customPort, customTransport, customPath, customUsername, pauseInBackground
    }

    /// Missing keys keep their defaults, so settings saved by an older version still load.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ObserverSettings()
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? defaults.isEnabled
        broker = try container.decodeIfPresent(Broker.self, forKey: .broker) ?? defaults.broker
        iata = try container.decodeIfPresent(String.self, forKey: .iata) ?? defaults.iata
        wifiOnly = try container.decodeIfPresent(Bool.self, forKey: .wifiOnly) ?? defaults.wifiOnly
        customHost = try container.decodeIfPresent(String.self, forKey: .customHost) ?? defaults.customHost
        customPort = try container.decodeIfPresent(UInt16.self, forKey: .customPort) ?? defaults.customPort
        customTransport = try container.decodeIfPresent(CustomTransport.self, forKey: .customTransport) ?? defaults.customTransport
        customPath = try container.decodeIfPresent(String.self, forKey: .customPath) ?? defaults.customPath
        customUsername = try container.decodeIfPresent(String.self, forKey: .customUsername) ?? defaults.customUsername
        pauseInBackground = try container.decodeIfPresent(Bool.self, forKey: .pauseInBackground) ?? defaults.pauseInBackground
    }

    public var normalizedIATA: String { iata.trimmingCharacters(in: .whitespaces).uppercased() }

    public var isIATAValid: Bool {
        normalizedIATA.count == 3 && normalizedIATA.allSatisfy { $0.isASCII && $0.isLetter }
    }

    public var endpoint: MQTTEndpoint? {
        switch broker {
        case .letsMeshUS: return MQTTEndpoint(host: "mqtt-us-v1.letsmesh.net", port: 443, kind: .secureWebSocket(path: "/"))
        case .letsMeshEU: return MQTTEndpoint(host: "mqtt-eu-v1.letsmesh.net", port: 443, kind: .secureWebSocket(path: "/"))
        case .custom:
            let host = customHost.trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty else { return nil }
            let kind: MQTTEndpoint.Kind = switch customTransport {
            case .tcp: .tcp
            case .tls: .tls
            case .webSocket: .webSocket(path: customPath)
            case .secureWebSocket: .secureWebSocket(path: customPath)
            }
            return MQTTEndpoint(host: host, port: customPort, kind: kind)
        }
    }
}

/// Where the custom broker's password is kept (the Keychain in the app).
public protocol SecretStore: AnyObject, Sendable {
    func secret(for key: String) -> String?
    func setSecret(_ value: String?, for key: String)
}

/// Whether the phone is on Wi-Fi, for the "Wi-Fi only" option.
@MainActor
public protocol NetworkReachability: AnyObject {
    var isOnWiFi: Bool { get }
    var onChange: (() -> Void)? { get set }
}

@MainActor
public final class PathMonitorReachability: NetworkReachability {
    public private(set) var isOnWiFi = false
    public var onChange: (() -> Void)?
    private let monitor = NWPathMonitor()

    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let wifi = path.status == .satisfied && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
            Task { @MainActor in
                guard let self, self.isOnWiFi != wifi else { return }
                self.isOnWiFi = wifi
                self.onChange?()
            }
        }
        monitor.start(queue: .main)
    }

    deinit { monitor.cancel() }
}

/// Phone-as-observer: forwards every packet the radio hears to an MQTT broker in the meshcoretomqtt format, so
/// community maps and analyzers can see this part of the mesh. Off unless the user turns it on.
@MainActor
@Observable
public final class ObserverService: RadioEventHandler {
    public enum Status: Equatable, Sendable {
        case off
        case needsSetup(String)
        case waitingForRadio
        case waitingForWiFi
        /// Disconnected while the app is in the background (the "pause in background" option).
        case pausedInBackground
        case connecting
        case connected(since: Date)
        case retrying(reason: String, at: Date)
    }

    public private(set) var settings: ObserverSettings
    public private(set) var status: Status = .off
    public private(set) var packetsSent = 0

    @ObservationIgnored private let radio: RadioController
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let secrets: any SecretStore
    @ObservationIgnored private let reachability: any NetworkReachability
    @ObservationIgnored private let clientVersion: String
    @ObservationIgnored private let makeTransport: @Sendable (MQTTEndpoint) -> any MQTTTransport
    @ObservationIgnored private let retryDelays: [Duration]
    @ObservationIgnored private let tokenRefresh: Duration
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var client: MQTTClient?
    @ObservationIgnored private var identity: ObserverIdentity?
    @ObservationIgnored private var isAppActive = true
    private static let settingsKey = "observer.settings"
    public static let passwordKey = "observer.customPassword"

    public init(
        radio: RadioController,
        defaults: UserDefaults = .standard,
        secrets: any SecretStore,
        reachability: any NetworkReachability = PathMonitorReachability(),
        clientVersion: String,
        makeTransport: @escaping @Sendable (MQTTEndpoint) -> any MQTTTransport = { NetworkMQTTTransport(endpoint: $0) },
        retryDelays: [Duration] = [.seconds(5), .seconds(15), .seconds(60), .seconds(300)],
        tokenRefresh: Duration = .seconds(50 * 60)
    ) {
        self.radio = radio
        self.defaults = defaults
        self.secrets = secrets
        self.reachability = reachability
        self.clientVersion = clientVersion
        self.makeTransport = makeTransport
        self.retryDelays = retryDelays
        self.tokenRefresh = tokenRefresh
        if let data = defaults.data(forKey: Self.settingsKey), let saved = try? JSONDecoder().decode(ObserverSettings.self, from: data) {
            settings = saved
        } else {
            settings = ObserverSettings()
        }
        radio.addHandler(self)
        reachability.onChange = { [weak self] in self?.reevaluate() }
        reevaluate()
    }

    public var customPassword: String {
        get { secrets.secret(for: Self.passwordKey) ?? "" }
        set { secrets.setSecret(newValue.isEmpty ? nil : newValue, for: Self.passwordKey) }
    }

    public func update(_ settings: ObserverSettings) {
        let restart = settings != self.settings && runTask != nil
        self.settings = settings
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Self.settingsKey) }
        if restart { stop() }
        reevaluate()
    }

    /// Tells the uplink whether m-Core is in the foreground; with ``ObserverSettings/pauseInBackground`` it disconnects
    /// in the background and reconnects when the app is active again.
    public func setAppActive(_ active: Bool) {
        guard active != isAppActive else { return }
        isAppActive = active
        reevaluate()
    }

    /// The topic packets go to, once a radio is connected.
    public var packetsTopic: String? { identity.map(ObserverUplink.packetsTopic(for:)) }

    // MARK: Lifecycle

    private func reevaluate() {
        guard settings.isEnabled else { return halt(.off) }
        guard settings.isIATAValid else { return halt(.needsSetup("Enter your region's three-letter airport code.")) }
        guard settings.endpoint != nil else { return halt(.needsSetup("Enter the broker's address.")) }
        guard let info = radio.connectionInfo else { return halt(.waitingForRadio) }
        guard !settings.wifiOnly || reachability.isOnWiFi else { return halt(.waitingForWiFi) }
        guard isAppActive || !settings.pauseInBackground else { return halt(.pausedInBackground) }
        identity = ObserverIdentity(name: info.selfInfo.name, publicKey: info.selfInfo.publicKey, iata: settings.normalizedIATA)
        guard runTask == nil else { return }
        runTask = Task { [weak self] in await self?.run() }
    }

    private func halt(_ status: Status) {
        stop()
        self.status = status
    }

    private func stop() {
        runTask?.cancel()
        runTask = nil
        if let client {
            self.client = nil
            Task { await client.disconnect() }
        }
    }

    private func run() async {
        var failures = 0
        while !Task.isCancelled {
            status = .connecting
            do {
                let client = try await connect()
                // Turned off (or the radio went away) while connecting: don't come online for a run that was stopped.
                guard !Task.isCancelled else {
                    await client.disconnect()
                    break
                }
                self.client = client
                let connectedAt = Date()
                status = .connected(since: connectedAt)
                try? await client.publish(topic: ObserverUplink.statusTopic(for: try requireIdentity()),
                                          string: statusMessage(online: true))
                let dropped = await waitForDropOrRefresh(client)
                if self.client === client { self.client = nil }
                await client.disconnect()
                if dropped {
                    // A broker that accepts and then drops at once (e.g. the same observer connected elsewhere) must not
                    // be redialled in a tight loop; back off as for a failed connect.
                    guard !Task.isCancelled else { break }
                    if Date().timeIntervalSince(connectedAt) >= 60 { failures = 0 }
                    let delay = retryDelays[min(failures, retryDelays.count - 1)]
                    failures += 1
                    status = .retrying(reason: "The broker closed the connection.", at: Date().addingTimeInterval(delay.timeInterval))
                    try? await Task.sleep(for: delay)
                } else {
                    failures = 0
                }
            } catch is CancellationError {
                break
            } catch {
                guard !Task.isCancelled else { break }
                let delay = retryDelays[min(failures, retryDelays.count - 1)]
                failures += 1
                status = .retrying(reason: Self.describe(error), at: Date().addingTimeInterval(delay.timeInterval))
                try? await Task.sleep(for: delay)
            }
        }
    }

    private func connect() async throws -> MQTTClient {
        let identity = try requireIdentity()
        guard let endpoint = settings.endpoint else { throw ObserverError.notConfigured }
        let will = MQTTWill(topic: ObserverUplink.statusTopic(for: identity), payload: Data(statusMessage(online: false).utf8),
                            qos: .atMostOnce, retain: true)
        var options = MQTTConnectOptions(clientID: ObserverUplink.clientID(for: identity.publicKey), will: will)
        switch settings.broker {
        case .letsMeshUS, .letsMeshEU:
            guard let session = await radio.session() else { throw ObserverError.radioUnavailable }
            options.username = MeshCoreAuthToken.username(for: identity.publicKey)
            options.password = try await MeshCoreAuthToken.make(
                publicKey: identity.publicKey,
                claims: [("aud", endpoint.host), ("client", clientVersion)],
                signer: { try await session.sign($0) }
            )
        case .custom:
            let username = settings.customUsername.trimmingCharacters(in: .whitespaces)
            options.username = username.isEmpty ? nil : username
            options.password = customPassword.isEmpty ? nil : customPassword
        }
        let client = MQTTClient(transport: makeTransport(endpoint), options: options)
        try await client.connect()
        return client
    }

    /// Returns when the connection drops (true), or when the auth token is due for renewal (false).
    private func waitForDropOrRefresh(_ client: MQTTClient) async -> Bool {
        let refresh = tokenRefresh
        let needsRefresh = settings.broker != .custom
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await state in await client.stateUpdates() {
                    if case .failed = state { return true }
                    if state == .disconnected { return true }
                }
                return true
            }
            if needsRefresh {
                group.addTask {
                    try? await Task.sleep(for: refresh)
                    return false
                }
            }
            let dropped = await group.next() ?? true
            group.cancelAll()
            return dropped
        }
    }

    private func requireIdentity() throws -> ObserverIdentity {
        guard let identity else { throw ObserverError.radioUnavailable }
        return identity
    }

    private func statusMessage(online: Bool) -> String {
        let info = radio.connectionInfo
        let status = ObserverStatus(
            isOnline: online,
            radio: info.map { ObserverUplink.radioDescription($0.selfInfo.radio) },
            model: info?.device.model,
            firmwareVersion: info?.device.firmwareVersion,
            clientVersion: clientVersion
        )
        return identity.map { ObserverUplink.statusMessage(status, observer: $0) } ?? ""
    }

    private static func describe(_ error: any Error) -> String {
        switch error {
        case MQTTClientError.refused(let refusal): refusalMessage(refusal)
        case MQTTClientError.timeout: "The broker didn't answer."
        case ObserverError.radioUnavailable: "The radio isn't available to sign in."
        case let error as MeshError: "The radio couldn't sign in: \(error.readable)"
        default: String(describing: error)
        }
    }

    // MARK: RadioEventHandler

    public func radioDidConnect(_ info: ConnectionInfo, session: MeshSession) async {
        reevaluate()
    }

    public func radioDidDisconnect() {
        reevaluate()
    }

    public func radioDidReceive(_ push: Push, session: MeshSession) async {
        guard case .rxLog(let entry) = push, case .connected = status, let client, let identity else { return }
        guard let message = ObserverUplink.packetMessage(entry, observer: identity, radio: radio.selfInfo?.radio) else { return }
        do {
            try await client.publish(topic: ObserverUplink.packetsTopic(for: identity), string: message)
            packetsSent += 1
        } catch {
            // A dropped connection is noticed by the run loop, which reconnects.
        }
    }
}

public enum ObserverError: Error, Equatable, Sendable {
    case notConfigured
    case radioUnavailable
}

extension Duration {
    var timeInterval: TimeInterval { seconds }
}
