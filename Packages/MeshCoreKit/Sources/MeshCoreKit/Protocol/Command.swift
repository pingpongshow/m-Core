import Foundation

/// A command frame sent to the radio. Layouts follow `MyMesh::handleCmdFrame` in the companion firmware.
public enum Command: Equatable, Sendable {
    // Connection
    case deviceQuery(appTargetVersion: UInt8 = MeshCoreProtocol.appTargetVersion)
    case appStart(appName: String)
    case getDeviceTime
    case setDeviceTime(UInt32)

    // Messaging
    case sendTextMessage(to: KeyPrefix, text: String, timestamp: UInt32, attempt: UInt8 = 0, type: TextType = .plain)
    case sendChannelTextMessage(channelIndex: UInt8, text: String, timestamp: UInt32)
    /// `path` nil floods the datagram.
    case sendChannelData(channelIndex: UInt8, path: MeshPath?, dataType: UInt16, payload: Data)
    case syncNextMessage

    // Contacts
    /// `since` limits the reply to contacts modified after that radio time.
    case getContacts(since: UInt32? = nil)
    case getContactByKey(PublicKey)
    case addUpdateContact(Contact)
    case removeContact(PublicKey)
    case resetPath(PublicKey)
    case shareContact(PublicKey)
    /// nil exports this radio's own advert.
    case exportContact(PublicKey?)
    case importContact(Data)
    case getAdvertPath(PublicKey)
    case setAutoAddConfig(AutoAddConfig)
    case getAutoAddConfig

    // Self & adverts
    /// `flood` false sends a zero-hop advert.
    case sendSelfAdvert(flood: Bool)
    case setAdvertName(String)
    /// Microdegrees. Firmware v1.18 accepts but ignores altitude (millimetres per the "FUTURE" field).
    case setAdvertLatLon(latitudeE6: Int32, longitudeE6: Int32, altitude: Int32? = nil)
    case setOtherParams(OtherParams)

    // Radio
    case setRadioParams(RadioParameters, clientRepeat: Bool? = nil)
    case setRadioTxPower(Int8)
    case setTuningParams(TuningParams)
    case getTuningParams
    case getAllowedRepeatFrequencies
    case setPathHashMode(UInt8)
    case setFloodScopeKey([UInt8]?)
    case setUnscopedFlood
    case setDefaultFloodScope(FloodScope?)
    case getDefaultFloodScope

    // Device
    case getBatteryAndStorage
    case getStats(StatsType)
    case getCustomVars
    case setCustomVar(name: String, value: String)
    case setDevicePin(UInt32)
    case runCLICommand(String)
    case reboot
    case factoryReset
    case exportPrivateKey
    case importPrivateKey(Data)

    // Channels
    case getChannel(index: UInt8)
    case setChannel(ChannelInfo)

    // Remote nodes
    case sendLogin(to: PublicKey, password: String)
    case logout(PublicKey)
    case hasConnection(PublicKey)
    case sendStatusRequest(PublicKey)
    /// nil requests telemetry from the connected radio itself.
    case sendTelemetryRequest(PublicKey?)
    case sendBinaryRequest(to: PublicKey, data: Data)
    case sendAnonRequest(to: PublicKey, data: Data)
    case sendPathDiscoveryRequest(PublicKey)
    /// `pathHashes` is the flat list of hop hashes; `flags & 0x03` selects 1, 2 or 4-byte hashes.
    case sendTracePath(tag: UInt32, authCode: UInt32, flags: UInt8, pathHashes: [UInt8])

    // Raw / signing
    case sendRawData(path: MeshPath, payload: Data)
    case sendRawPacket(priority: UInt8, packet: Data)
    case sendControlData(Data)
    case signStart
    case signData(Data)
    case signFinish

    public var code: CommandCode {
        switch self {
        case .deviceQuery: .deviceQuery
        case .appStart: .appStart
        case .getDeviceTime: .getDeviceTime
        case .setDeviceTime: .setDeviceTime
        case .sendTextMessage: .sendTextMessage
        case .sendChannelTextMessage: .sendChannelTextMessage
        case .sendChannelData: .sendChannelData
        case .syncNextMessage: .syncNextMessage
        case .getContacts: .getContacts
        case .getContactByKey: .getContactByKey
        case .addUpdateContact: .addUpdateContact
        case .removeContact: .removeContact
        case .resetPath: .resetPath
        case .shareContact: .shareContact
        case .exportContact: .exportContact
        case .importContact: .importContact
        case .getAdvertPath: .getAdvertPath
        case .setAutoAddConfig: .setAutoAddConfig
        case .getAutoAddConfig: .getAutoAddConfig
        case .sendSelfAdvert: .sendSelfAdvert
        case .setAdvertName: .setAdvertName
        case .setAdvertLatLon: .setAdvertLatLon
        case .setOtherParams: .setOtherParams
        case .setRadioParams: .setRadioParams
        case .setRadioTxPower: .setRadioTxPower
        case .setTuningParams: .setTuningParams
        case .getTuningParams: .getTuningParams
        case .getAllowedRepeatFrequencies: .getAllowedRepeatFrequencies
        case .setPathHashMode: .setPathHashMode
        case .setFloodScopeKey, .setUnscopedFlood: .setFloodScopeKey
        case .setDefaultFloodScope: .setDefaultFloodScope
        case .getDefaultFloodScope: .getDefaultFloodScope
        case .getBatteryAndStorage: .getBatteryAndStorage
        case .getStats: .getStats
        case .getCustomVars: .getCustomVars
        case .setCustomVar: .setCustomVar
        case .setDevicePin: .setDevicePin
        case .runCLICommand: .runCLICommand
        case .reboot: .reboot
        case .factoryReset: .factoryReset
        case .exportPrivateKey: .exportPrivateKey
        case .importPrivateKey: .importPrivateKey
        case .getChannel: .getChannel
        case .setChannel: .setChannel
        case .sendLogin: .sendLogin
        case .logout: .logout
        case .hasConnection: .hasConnection
        case .sendStatusRequest: .sendStatusRequest
        case .sendTelemetryRequest: .sendTelemetryRequest
        case .sendBinaryRequest: .sendBinaryRequest
        case .sendAnonRequest: .sendAnonRequest
        case .sendPathDiscoveryRequest: .sendPathDiscoveryRequest
        case .sendTracePath: .sendTracePath
        case .sendRawData: .sendRawData
        case .sendRawPacket: .sendRawPacket
        case .sendControlData: .sendControlData
        case .signStart: .signStart
        case .signData: .signData
        case .signFinish: .signFinish
        }
    }

    /// The frame bytes, starting with the command code.
    public func encoded() -> Data {
        var writer = ByteWriter(code: code.rawValue)
        let encoders = [encodeConnectionAndMessaging, encodeContacts, encodeSelfAndRadio, encodeDevice, encodeRemote, encodeRaw]
        let handled = encoders.contains { $0(&writer) }
        assert(handled, "no encoder for \(code)")
        return writer.data
    }
}
