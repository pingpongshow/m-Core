/// Detail level for a downloaded offline map area.
///
/// The PMTiles extractor and offline store arrive in Phase 4; see PLAN.md §4.4.
public enum OfflineMapDetail: String, CaseIterable, Sendable {
    case standard
    case high

    /// Zoom levels included in an extract. Every area starts at z0 so zoomed-out context works offline.
    public var zoomRange: ClosedRange<Int> {
        switch self {
        case .standard: 0...13
        case .high: 0...15
        }
    }
}
