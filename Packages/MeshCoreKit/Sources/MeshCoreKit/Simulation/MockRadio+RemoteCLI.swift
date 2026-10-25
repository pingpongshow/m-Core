import Foundation

extension MockRadio {
    /// What a freshly configured v1.18 repeater reports for `get <key>`.
    public static let defaultRemoteSettings: [String: String] = [
        "name": "Charlie Node",
        "radio": "910.525,62.5,7,5",
        "tx": "22",
        "advert.interval": "0",
        "flood.advert.interval": "47",
        "flood.max": "64",
        "guest.password": "",
        "lat": "37.7544",
        "lon": "-122.4477",
        "repeat": "on",
    ]

    /// A repeater's or room server's reply to a remote CLI command, following MeshCore v1.18 `CommonCLI` and
    /// `CommonRadioPrefs`. Nil for `reboot`, which restarts the node without replying.
    static func remoteCLIReply(to command: String, state: inout State) -> String? {
        state.remoteCLICommands.append(command)
        if command == "ver" { return "v1.18.0 (Build: 15 Oct 2026)" }
        if command.hasPrefix("reboot") { return nil }
        if command.hasPrefix("password ") { return "password now: \(command.dropFirst(9))" }
        if command == "advert" { return "OK - Advert sent" }
        if command == "advert.zerohop" { return "OK - zerohop advert sent" }
        if command.hasPrefix("get ") {
            let key = String(command.dropFirst(4))
            guard let value = state.remoteSettings[key] else { return "??: \(key)" }
            return "> \(value)"
        }
        if command.hasPrefix("set ") { return remoteSetReply(command.dropFirst(4), state: &state) }
        return "OK - \(command)"
    }

    /// `set <key> <value>`: stores known keys, with the firmware's reply wording.
    private static func remoteSetReply(_ rest: Substring, state: inout State) -> String {
        guard let space = rest.firstIndex(of: " ") else { return "unknown config: \(rest)" }
        let key = String(rest[..<space])
        let value = String(rest[rest.index(after: space)...])
        guard state.remoteSettings[key] != nil else { return "unknown config: \(rest)" }
        switch key {
        case "flood.max":
            guard let hops = Int(value), hops <= 64 else { return "Error, max 64" }
        case "radio":
            state.remoteSettings[key] = value
            return "OK - reboot to apply"
        case "repeat":
            state.remoteSettings[key] = value == "off" ? "off" : "on"
            return value == "off" ? "OK - repeat is now OFF" : "OK - repeat is now ON"
        default:
            break
        }
        state.remoteSettings[key] = value
        return "OK"
    }
}
