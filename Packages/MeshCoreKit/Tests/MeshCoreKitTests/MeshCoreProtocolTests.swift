import Foundation
import Testing
@testable import MeshCoreKit

struct MeshCoreProtocolTests {
    @Test func bleUUIDsAreValid() {
        let uuids = [
            MeshCoreProtocol.BLE.serviceUUID,
            MeshCoreProtocol.BLE.rxCharacteristicUUID,
            MeshCoreProtocol.BLE.txCharacteristicUUID,
        ]
        for uuid in uuids {
            #expect(UUID(uuidString: uuid) != nil, "\(uuid) is not a valid UUID")
        }
        #expect(Set(uuids).count == 3)
    }

    @Test func referenceVersionMatchesPlan() {
        #expect(MeshCoreProtocol.referenceVersionCode == 14)
    }
}
