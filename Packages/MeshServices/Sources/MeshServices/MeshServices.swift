import MeshCoreKit
import MeshStore

/// App logic built on MeshCoreKit and MeshStore: message and contact sync, the GPS Feed,
/// telemetry, admin, Internet Map and the observer uplink. Services arrive from Phase 1; see PLAN.md §6.1.
public enum MeshServices {
    /// Protocol version the services layer is written against.
    public static var protocolVersionCode: UInt8 { MeshCoreProtocol.referenceVersionCode }
}
