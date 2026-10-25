/// Constants for the MeshCore companion radio protocol.
///
/// The frame codec, transports and session actor arrive in Phase 1; see PLAN.md §3.1.
public enum MeshCoreProtocol {
    /// Companion protocol version (`FIRMWARE_VER_CODE`) that m-Core is built against (firmware v1.18.0).
    public static let referenceVersionCode: UInt8 = 14

    /// Nordic UART Service UUIDs used by companion radios over BLE.
    public enum BLE {
        public static let serviceUUID = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
        /// App → radio (write with response). One write carries one frame.
        public static let rxCharacteristicUUID = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
        /// Radio → app (notify). One notification carries one frame.
        public static let txCharacteristicUUID = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"
    }

    /// Response codes at or above this value are unsolicited pushes.
    public static let firstPushCode: UInt8 = 0x80
}
