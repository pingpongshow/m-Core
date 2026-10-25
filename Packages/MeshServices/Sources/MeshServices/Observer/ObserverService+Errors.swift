import MeshTools

extension ObserverService {
    /// Plain-language CONNACK refusals rather than the enum case names.
    static func refusalMessage(_ refusal: MQTTConnectRefusal) -> String {
        switch refusal {
        case .notAuthorized, .badUsernameOrPassword: "The broker didn't accept the sign-in."
        case .identifierRejected: "The broker rejected this radio's ID."
        case .serverUnavailable: "The broker is unavailable right now."
        case .unacceptableProtocolVersion: "The broker doesn't support this MQTT version."
        }
    }
}
