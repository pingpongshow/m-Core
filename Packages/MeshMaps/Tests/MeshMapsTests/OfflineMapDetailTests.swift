import Testing
@testable import MeshMaps

struct OfflineMapDetailTests {
    @Test func zoomRangesMatchPlan() {
        #expect(OfflineMapDetail.standard.zoomRange == 0...13)
        #expect(OfflineMapDetail.high.zoomRange == 0...15)
    }
}
