import Foundation

/// Whether the phone is in Low Power Mode; faked in tests.
@MainActor
public protocol PowerStateMonitor: AnyObject {
    var isLowPowerModeEnabled: Bool { get }
    /// Called on the main actor whenever Low Power Mode turns on or off.
    var onChange: (() -> Void)? { get set }
}

/// Follows Low Power Mode through `NSProcessInfoPowerStateDidChange`.
@MainActor
public final class SystemPowerStateMonitor: PowerStateMonitor {
    public private(set) var isLowPowerModeEnabled: Bool
    public var onChange: (() -> Void)?

    private let center: NotificationCenter
    private let read: @Sendable () -> Bool
    nonisolated(unsafe) private var token: (any NSObjectProtocol)?

    /// - Parameters:
    ///   - center: Where the power-state notification is posted.
    ///   - read: Reads the current state; `ProcessInfo` in the app.
    public init(
        center: NotificationCenter = .default,
        read: @escaping @Sendable () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled }
    ) {
        self.center = center
        self.read = read
        isLowPowerModeEnabled = read()
        // The notification arrives on an arbitrary thread; hop to the main actor before touching state.
        token = center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: nil) { [weak self] _ in
            let enabled = read()
            Task { @MainActor in self?.apply(enabled) }
        }
    }

    deinit {
        if let token { center.removeObserver(token) }
    }

    private func apply(_ enabled: Bool) {
        guard enabled != isLowPowerModeEnabled else { return }
        isLowPowerModeEnabled = enabled
        onChange?()
    }
}
