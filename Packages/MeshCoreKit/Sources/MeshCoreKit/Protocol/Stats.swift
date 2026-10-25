import Foundation

public struct CoreStats: Equatable, Hashable, Sendable {
    public init(batteryMillivolts: UInt16, uptimeSeconds: UInt32, errorFlags: UInt16, outboundQueueLength: UInt8) {
        self.batteryMillivolts = batteryMillivolts
        self.uptimeSeconds = uptimeSeconds
        self.errorFlags = errorFlags
        self.outboundQueueLength = outboundQueueLength
    }

    public var batteryMillivolts: UInt16
    public var uptimeSeconds: UInt32
    public var errorFlags: UInt16
    public var outboundQueueLength: UInt8
}

public struct RadioStats: Equatable, Hashable, Sendable {
    public init(noiseFloorDbm: Int16, lastRSSI: Int8, lastSNR: Double, txAirtimeSeconds: UInt32, rxAirtimeSeconds: UInt32) {
        self.noiseFloorDbm = noiseFloorDbm
        self.lastRSSI = lastRSSI
        self.lastSNR = lastSNR
        self.txAirtimeSeconds = txAirtimeSeconds
        self.rxAirtimeSeconds = rxAirtimeSeconds
    }

    public var noiseFloorDbm: Int16
    public var lastRSSI: Int8
    /// dB, 0.25 dB precision.
    public var lastSNR: Double
    public var txAirtimeSeconds: UInt32
    public var rxAirtimeSeconds: UInt32
}

public struct PacketStats: Equatable, Hashable, Sendable {
    public init(
        received: UInt32, sent: UInt32, sentFlood: UInt32, sentDirect: UInt32,
        receivedFlood: UInt32, receivedDirect: UInt32, receiveErrors: UInt32
    ) {
        self.received = received
        self.sent = sent
        self.sentFlood = sentFlood
        self.sentDirect = sentDirect
        self.receivedFlood = receivedFlood
        self.receivedDirect = receivedDirect
        self.receiveErrors = receiveErrors
    }

    public var received: UInt32
    public var sent: UInt32
    public var sentFlood: UInt32
    public var sentDirect: UInt32
    public var receivedFlood: UInt32
    public var receivedDirect: UInt32
    public var receiveErrors: UInt32
}

public enum Stats: Equatable, Hashable, Sendable {
    case core(CoreStats)
    case radio(RadioStats)
    case packets(PacketStats)
    case unknown(type: UInt8, payload: Data)
}
