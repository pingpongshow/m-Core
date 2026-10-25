/// Persistence for m-Core: one SwiftData store per radio.
///
/// Models and migrations arrive with messaging in Phase 3; see PLAN.md §6.1.
public enum MeshStore {
    /// Bumped whenever the persisted schema changes.
    public static let schemaVersion = 1

    /// File name of the store for a radio, keyed by the radio's public key (hex).
    public static func storeFileName(forRadioPublicKeyHex key: String) -> String {
        "radio-\(key.lowercased()).store"
    }
}
