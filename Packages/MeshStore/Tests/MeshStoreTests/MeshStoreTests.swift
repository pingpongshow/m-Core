import Testing
@testable import MeshStore

struct MeshStoreTests {
    @Test func storeFileNameIsLowercasedPerRadio() {
        #expect(MeshStore.storeFileName(forRadioPublicKeyHex: "AB12CD") == "radio-ab12cd.store")
    }
}
