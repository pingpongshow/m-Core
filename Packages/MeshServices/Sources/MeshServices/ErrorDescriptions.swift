import Foundation

extension MessagingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConnected: "The radio isn't connected."
        case .unknownConversation: "This chat isn't on the connected radio."
        case .messageTooLong(let maxBytes): "Too long: messages can be up to \(maxBytes) bytes."
        case .noFreeChannelSlot: "All channel slots on the radio are in use."
        case .loginFailed: "Wrong password."
        case .loginTimedOut: "No answer. The node may be out of range."
        }
    }
}

extension RemoteRequestError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConnected: "The radio isn't connected."
        case .unknownNode: "This node isn't in the radio's contacts."
        case .timedOut: "No answer. The node may be out of range."
        }
    }
}

extension RadioSettingsError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConnected: "The radio isn't connected."
        case .invalidPin: "The PIN must be 6 digits."
        case .disabledByFirmware: "This radio's firmware doesn't allow that."
        }
    }
}

extension CustomPresetError: LocalizedError {
    public var errorDescription: String? { description }
}

extension InternetMapError: LocalizedError {
    public var errorDescription: String? { description }
}

extension RemoteSettingError: LocalizedError {
    public var errorDescription: String? { description }
}

extension Error {
    /// Readable text for messages shown to the user.
    var readable: String { localizedDescription }
}
