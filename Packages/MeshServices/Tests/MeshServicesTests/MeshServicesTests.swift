import Testing
@testable import MeshServices

struct MeshServicesTests {
    @Test func usesReferenceProtocolVersion() {
        #expect(MeshServices.protocolVersionCode == 14)
    }
}
