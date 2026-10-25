import Foundation

extension MeshError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConnected: "The radio isn't connected."
        case .timeout: "The radio didn't answer in time."
        case .disabled: "This is turned off in the radio's firmware."
        case .unexpectedResponse: "The radio sent an unexpected reply."
        case .decoding: "Couldn't read the radio's reply."
        case .transport(let message): "Connection problem: \(message)"
        case .device(let code, _):
            switch code {
            case .unsupportedCommand: "The radio's firmware doesn't support this."
            case .notFound: "The radio couldn't find it."
            case .tableFull: "The radio's list is full."
            case .badState: "The radio isn't ready for that."
            case .fileIOError: "The radio couldn't save it."
            case .illegalArgument: "The radio rejected the value."
            case .other, nil: "The radio reported an error."
            }
        }
    }
}

extension TransportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notOpen: "The radio isn't connected."
        case .alreadyOpen: "Already connected."
        case .connectionFailed(let message): "Couldn't connect: \(message)"
        case .disconnected(let message): message.map { "The radio disconnected: \($0)" } ?? "The radio disconnected."
        case .bluetoothUnavailable(let message): message
        case .peripheralNotFound: "The radio wasn't found."
        case .serviceNotFound: "That device isn't a MeshCore radio."
        case .timedOut: "The radio didn't answer in time."
        case .frameTooLarge: "That's too large for the radio."
        }
    }
}
