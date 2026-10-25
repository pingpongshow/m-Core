import Foundation

/// A radio this phone has connected to, kept for one-tap reconnect.
public struct KnownRadio: Codable, Hashable, Identifiable, Sendable {
    public var target: RadioTarget
    /// The name the radio reported on its last connect.
    public var radioName: String?
    /// The user's own name for it, if they renamed it.
    public var customName: String?
    public var lastConnected: Date?

    public init(target: RadioTarget, radioName: String? = nil, customName: String? = nil, lastConnected: Date? = nil) {
        self.target = target
        self.radioName = radioName
        self.customName = customName
        self.lastConnected = lastConnected
    }

    public var id: String { Self.id(for: target) }

    public var displayName: String {
        if let customName, !customName.isEmpty { return customName }
        if let radioName, !radioName.isEmpty { return radioName }
        return target.displayName
    }

    /// "Bluetooth" or the host and port, for a subtitle.
    public var transportDescription: String {
        switch target {
        case .bluetooth: "Bluetooth"
        case .tcp(let host, let port): "Wi‑Fi · \(host):\(port)"
        case .simulator: "Simulator"
        }
    }

    static func id(for target: RadioTarget) -> String {
        switch target {
        case .bluetooth(let id, _): "ble:\(id.uuidString)"
        case .tcp(let host, let port): "tcp:\(host.lowercased()):\(port)"
        case .simulator: "simulator"
        }
    }
}

/// Persists known radios (Bluetooth identifier and name, TCP host and port, last connected) in user defaults.
/// The simulated radio isn't remembered here; it has its own button in debug builds.
public struct KnownRadiosStore {
    private let defaults: UserDefaults
    static let key = "radio.known"

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Most recently connected first; never-connected radios last, by name.
    public func load() -> [KnownRadio] {
        guard let data = defaults.data(forKey: Self.key), let radios = try? JSONDecoder().decode([KnownRadio].self, from: data) else {
            return []
        }
        return Self.sorted(radios)
    }

    /// Records a successful connection, adding the radio if it's new.
    @discardableResult
    public func recordConnection(to target: RadioTarget, radioName: String?, at date: Date) -> [KnownRadio] {
        guard target != .simulator else { return load() }
        var radios = load()
        let id = KnownRadio.id(for: target)
        if let index = radios.firstIndex(where: { $0.id == id }) {
            radios[index].target = target
            radios[index].lastConnected = date
            if let radioName, !radioName.isEmpty { radios[index].radioName = radioName }
        } else {
            radios.append(KnownRadio(target: target, radioName: radioName, lastConnected: date))
        }
        return save(radios)
    }

    /// Adds a radio without connecting (e.g. one just authorized in the accessory picker).
    @discardableResult
    public func add(_ target: RadioTarget, radioName: String?) -> [KnownRadio] {
        guard target != .simulator else { return load() }
        var radios = load()
        guard !radios.contains(where: { $0.id == KnownRadio.id(for: target) }) else { return radios }
        radios.append(KnownRadio(target: target, radioName: radioName))
        return save(radios)
    }

    /// Sets or clears (empty name) the user's name for a radio.
    @discardableResult
    public func rename(id: String, to name: String) -> [KnownRadio] {
        var radios = load()
        guard let index = radios.firstIndex(where: { $0.id == id }) else { return radios }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        radios[index].customName = trimmed.isEmpty ? nil : trimmed
        return save(radios)
    }

    @discardableResult
    public func forget(id: String) -> [KnownRadio] {
        save(load().filter { $0.id != id })
    }

    private func save(_ radios: [KnownRadio]) -> [KnownRadio] {
        let sorted = Self.sorted(radios)
        if let data = try? JSONEncoder().encode(sorted) { defaults.set(data, forKey: Self.key) }
        return sorted
    }

    private static func sorted(_ radios: [KnownRadio]) -> [KnownRadio] {
        radios.sorted { lhs, rhs in
            switch (lhs.lastConnected, rhs.lastConnected) {
            case let (left?, right?): left > right
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
        }
    }
}
