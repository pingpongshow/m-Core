import Foundation

// MARK: - Typed commands

extension MeshSession {
    /// Device query → app start → clock sync. Run once after `open()`.
    public func handshake(appName: String = "m-Core", now: Date = Date()) async throws -> ConnectionInfo {
        let device = try await deviceQuery()
        let selfInfo = try await appStart(appName: appName)
        let clock = try await syncClock(to: now)
        return ConnectionInfo(device: device, selfInfo: selfInfo, clockSync: clock)
    }

    public func deviceQuery(appTargetVersion: UInt8 = MeshCoreProtocol.appTargetVersion) async throws -> DeviceInfo {
        try await request(.deviceQuery(appTargetVersion: appTargetVersion)) {
            if case .deviceInfo(let info) = $0 { return info }
            return nil
        }
    }

    public func appStart(appName: String) async throws -> SelfInfo {
        try await request(.appStart(appName: appName)) {
            if case .selfInfo(let info) = $0 { return info }
            return nil
        }
    }

    public func getDeviceTime() async throws -> UInt32 {
        try await request(.getDeviceTime) {
            if case .currentTime(let time) = $0 { return time }
            return nil
        }
    }

    /// Sets the radio clock to `date`. If the radio is already ahead it refuses, and its time is returned.
    public func syncClock(to date: Date) async throws -> ClockSyncResult {
        let seconds = UInt32(clamping: Int64(date.timeIntervalSince1970.rounded(.down)))
        let reply = try await send(.setDeviceTime(seconds)) { response in
            if case .ok = response { return true }
            return Self.isFailure(response)
        }
        switch reply {
        case .ok:
            return .updated(to: seconds)
        case .error(.illegalArgument):
            return .radioAhead(radioTime: try await getDeviceTime())
        case let other:
            return try Self.unwrap(other, command: .setDeviceTime) { _ in nil }
        }
    }

    /// Fetches contacts, optionally only those changed after `since` (pass the previous `lastModified`).
    public func getContacts(since: UInt32? = nil) async throws -> ContactList {
        let replies = try await exchange(.getContacts(since: since), accepts: { response in
            switch response {
            case .contactsStart, .contact, .endOfContacts, .error: true
            default: false
            }
        }, isComplete: { replies in
            if case .endOfContacts = replies.last { return true }
            return false
        })
        var list = ContactList(contacts: [], totalCount: 0, lastModified: since ?? 0)
        for reply in replies {
            switch reply {
            case .contactsStart(let count): list.totalCount = count
            case .contact(let contact): list.contacts.append(contact)
            case .endOfContacts(let lastModified): list.lastModified = max(lastModified, since ?? 0)
            case .error(let code): throw MeshError.device(code, .getContacts)
            default: throw MeshError.unexpectedResponse(reply, .getContacts)
            }
        }
        return list
    }

    /// Pops the next queued message, or nil when the queue is empty.
    public func syncNextMessage() async throws -> Response? {
        let reply = try await send(.syncNextMessage) { response in
            switch response {
            case .noMoreMessages, .contactMessage, .channelMessage, .channelData: true
            default: Self.isFailure(response)
            }
        }
        switch reply {
        case .noMoreMessages: return nil
        case .contactMessage, .channelMessage, .channelData: return reply
        default: return try Self.unwrap(reply, command: .syncNextMessage) { _ in nil }
        }
    }

    public func getBatteryAndStorage() async throws -> BatteryAndStorage {
        try await request(.getBatteryAndStorage) {
            if case .batteryAndStorage(let value) = $0 { return value }
            return nil
        }
    }

    public func getCustomVars() async throws -> [String: String] {
        try await request(.getCustomVars) {
            if case .customVars(let vars) = $0 { return vars }
            return nil
        }
    }

    public func getStats(_ type: StatsType) async throws -> Stats {
        try await request(.getStats(type)) {
            if case .stats(let stats) = $0 { return stats }
            return nil
        }
    }

    public func getChannel(index: UInt8) async throws -> ChannelInfo {
        try await request(.getChannel(index: index)) {
            if case .channelInfo(let channel) = $0 { return channel }
            return nil
        }
    }

    /// Sends a direct message; the returned tag matches the later `sendConfirmed` push.
    public func sendTextMessage(to recipient: KeyPrefix, text: String, timestamp: UInt32, attempt: UInt8 = 0) async throws -> SentInfo {
        try await request(.sendTextMessage(to: recipient, text: text, timestamp: timestamp, attempt: attempt)) {
            if case .sent(let info) = $0 { return info }
            return nil
        }
    }

    public func runCLICommand(_ command: String) async throws -> String {
        try await request(.runCLICommand(command)) {
            if case .cliReply(let reply) = $0 { return reply }
            return nil
        }
    }

    /// Has the radio sign `data` with its own Ed25519 key (the key never leaves the radio).
    public func sign(_ data: Data) async throws -> Data {
        let maxLength = try await request(.signStart) {
            if case .signStart(let maxLength) = $0 { return maxLength }
            return nil
        }
        guard data.count <= Int(maxLength) else { throw MeshError.device(.tableFull, .signStart) }
        var offset = 0
        while offset < data.count {
            let end = min(offset + Self.signChunkSize, data.count)
            try await perform(.signData(data.subdata(in: offset..<end)))
            offset = end
        }
        return try await request(.signFinish) {
            if case .signature(let signature) = $0 { return signature }
            return nil
        }
    }

    /// Fits a sign-data frame comfortably inside the companion frame limit.
    static let signChunkSize = 128
}
