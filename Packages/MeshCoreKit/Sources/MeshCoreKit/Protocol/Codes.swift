/// Command codes, app → radio (`CMD_*`).
public enum CommandCode: UInt8, Sendable, CaseIterable {
    case appStart = 1
    case sendTextMessage = 2
    case sendChannelTextMessage = 3
    case getContacts = 4
    case getDeviceTime = 5
    case setDeviceTime = 6
    case sendSelfAdvert = 7
    case setAdvertName = 8
    case addUpdateContact = 9
    case syncNextMessage = 10
    case setRadioParams = 11
    case setRadioTxPower = 12
    case resetPath = 13
    case setAdvertLatLon = 14
    case removeContact = 15
    case shareContact = 16
    case exportContact = 17
    case importContact = 18
    case reboot = 19
    case getBatteryAndStorage = 20
    case setTuningParams = 21
    case deviceQuery = 22
    case exportPrivateKey = 23
    case importPrivateKey = 24
    case sendRawData = 25
    case sendLogin = 26
    case sendStatusRequest = 27
    case hasConnection = 28
    case logout = 29
    case getContactByKey = 30
    case getChannel = 31
    case setChannel = 32
    case signStart = 33
    case signData = 34
    case signFinish = 35
    case sendTracePath = 36
    case setDevicePin = 37
    case setOtherParams = 38
    case sendTelemetryRequest = 39
    case getCustomVars = 40
    case setCustomVar = 41
    case getAdvertPath = 42
    case getTuningParams = 43
    case sendBinaryRequest = 50
    case factoryReset = 51
    case sendPathDiscoveryRequest = 52
    case setFloodScopeKey = 54
    case sendControlData = 55
    case getStats = 56
    case sendAnonRequest = 57
    case setAutoAddConfig = 58
    case getAutoAddConfig = 59
    case getAllowedRepeatFrequencies = 60
    case setPathHashMode = 61
    case sendChannelData = 62
    case setDefaultFloodScope = 63
    case getDefaultFloodScope = 64
    case sendRawPacket = 65
    case runCLICommand = 66
}

/// Response codes, radio → app, replying to a command (`RESP_CODE_*`).
public enum ResponseCode: UInt8, Sendable, CaseIterable {
    case ok = 0
    case error = 1
    case contactsStart = 2
    case contact = 3
    case endOfContacts = 4
    case selfInfo = 5
    case sent = 6
    case contactMessageV2 = 7
    case channelMessageV2 = 8
    case currentTime = 9
    case noMoreMessages = 10
    case exportContact = 11
    case batteryAndStorage = 12
    case deviceInfo = 13
    case privateKey = 14
    case disabled = 15
    case contactMessage = 16
    case channelMessage = 17
    case channelInfo = 18
    case signStart = 19
    case signature = 20
    case customVars = 21
    case advertPath = 22
    case tuningParams = 23
    case stats = 24
    case autoAddConfig = 25
    case allowedRepeatFrequencies = 26
    case channelData = 27
    case defaultFloodScope = 28
    case cliReply = 29
}

/// Push codes, radio → app, sent at any time (`PUSH_CODE_*`).
public enum PushCode: UInt8, Sendable, CaseIterable {
    case advert = 0x80
    case pathUpdated = 0x81
    case sendConfirmed = 0x82
    case messagesWaiting = 0x83
    case rawData = 0x84
    case loginSuccess = 0x85
    case loginFailed = 0x86
    case statusResponse = 0x87
    case rxLog = 0x88
    case traceData = 0x89
    case newAdvert = 0x8A
    case telemetryResponse = 0x8B
    case binaryResponse = 0x8C
    case pathDiscoveryResponse = 0x8D
    case controlData = 0x8E
    case contactDeleted = 0x8F
    case contactsFull = 0x90
}

/// Error code carried by a `RESP_CODE_ERR` frame (`ERR_CODE_*`).
public enum MeshErrorCode: Equatable, Hashable, Sendable {
    case unsupportedCommand
    case notFound
    case tableFull
    case badState
    case fileIOError
    case illegalArgument
    case other(UInt8)

    public init(rawValue: UInt8) {
        switch rawValue {
        case 1: self = .unsupportedCommand
        case 2: self = .notFound
        case 3: self = .tableFull
        case 4: self = .badState
        case 5: self = .fileIOError
        case 6: self = .illegalArgument
        default: self = .other(rawValue)
        }
    }

    public var rawValue: UInt8 {
        switch self {
        case .unsupportedCommand: 1
        case .notFound: 2
        case .tableFull: 3
        case .badState: 4
        case .fileIOError: 5
        case .illegalArgument: 6
        case .other(let value): value
        }
    }
}

/// Kind of node an advert describes (`ADV_TYPE_*`).
public enum AdvertType: Equatable, Hashable, Sendable {
    case none
    case chat
    case repeater
    case room
    case sensor
    case other(UInt8)

    public init(rawValue: UInt8) {
        switch rawValue {
        case 0: self = .none
        case 1: self = .chat
        case 2: self = .repeater
        case 3: self = .room
        case 4: self = .sensor
        default: self = .other(rawValue)
        }
    }

    public var rawValue: UInt8 {
        switch self {
        case .none: 0
        case .chat: 1
        case .repeater: 2
        case .room: 3
        case .sensor: 4
        case .other(let value): value
        }
    }
}

/// Text message flavour (`TXT_TYPE_*`).
public enum TextType: Equatable, Hashable, Sendable {
    case plain
    case cliData
    case signedPlain
    case cliCommand
    case other(UInt8)

    public init(rawValue: UInt8) {
        switch rawValue {
        case 0: self = .plain
        case 1: self = .cliData
        case 2: self = .signedPlain
        case 3: self = .cliCommand
        default: self = .other(rawValue)
        }
    }

    public var rawValue: UInt8 {
        switch self {
        case .plain: 0
        case .cliData: 1
        case .signedPlain: 2
        case .cliCommand: 3
        case .other(let value): value
        }
    }
}

/// Sub-type for `CMD_GET_STATS` (`STATS_TYPE_*`).
public enum StatsType: UInt8, Sendable, CaseIterable {
    case core = 0
    case radio = 1
    case packets = 2
}
