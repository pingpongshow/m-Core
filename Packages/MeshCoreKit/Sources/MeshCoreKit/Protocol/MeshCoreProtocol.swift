/// Constants for the MeshCore companion radio protocol (firmware `examples/companion_radio`).
public enum MeshCoreProtocol {
    /// Companion protocol version (`FIRMWARE_VER_CODE`) that m-Core is built against (firmware v1.18.0).
    public static let referenceVersionCode: UInt8 = 14

    /// Protocol version m-Core tells the radio it understands (`CMD_DEVICE_QUERY`).
    /// 3+ makes the radio send the V3 message frames that carry SNR.
    public static let appTargetVersion: UInt8 = 3

    /// Largest frame the firmware sends or accepts (`MAX_FRAME_SIZE`).
    public static let maxFrameSize = 176

    public static let publicKeySize = 32
    public static let keyPrefixSize = 6
    public static let signatureSize = 64
    public static let maxPathSize = 64

    /// TCP port used by Wi‑Fi companion builds (`TCP_PORT`).
    public static let defaultTCPPort: UInt16 = 5000

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
