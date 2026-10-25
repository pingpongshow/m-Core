import Foundation
import MeshDesign
import MeshServices

extension RadioController {
    /// Connection state for status pills.
    var status: ConnectionStatus {
        switch state {
        case .idle: .disconnected
        case .connecting, .waitingToReconnect: .connecting(name: target?.displayName)
        case .connected(let info): .connected(name: info.selfInfo.name)
        }
    }
}

extension GPSFeedService {
    /// GPS Feed state for status pills.
    func displayStatus(now: Date = Date()) -> GPSFeedStatus {
        switch status {
        case .notConnected: .notConnected
        case .off: .off
        case .radioGPS(let isOn): isOn ? .radioGPS(lastPositionAge: nil) : .radioGPSOff
        case .waitingForLocation: .waitingForPhoneLocation
        case .locationDenied: .locationAccessNeeded
        case .pausedLowPower: .paused(reason: "Low Power Mode")
        case let .phone(accuracy, lastSync): .phone(accuracyMeters: accuracy, lastSyncAge: lastSync.map { now.timeIntervalSince($0) })
        }
    }
}
