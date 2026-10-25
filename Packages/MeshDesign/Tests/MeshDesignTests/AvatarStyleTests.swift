import Testing
@testable import MeshDesign

struct AvatarStyleTests {
    @Test(arguments: [
        ("Hannah Lee", "HL"),
        ("Bob Martinez", "BM"),
        ("Dad", "D"),
        ("bay area", "BA"),
        ("Eve Thompson ✋", "ET"),
        ("Mary Ann Smith", "MS"),
        ("🔥", "🔥"),
        ("   ", "?"),
        ("", "?"),
    ])
    func initials(name: String, expected: String) {
        #expect(AvatarStyle.initials(for: name) == expected)
    }

    @Test func paletteIndexIsStableAndCaseInsensitive() {
        let count = MCColor.avatarPalette.count
        let first = AvatarStyle.paletteIndex(for: "Alice Chen", paletteCount: count)
        #expect(first == AvatarStyle.paletteIndex(for: "Alice Chen", paletteCount: count))
        #expect(first == AvatarStyle.paletteIndex(for: "ALICE CHEN", paletteCount: count))
        #expect((0..<count).contains(first))
    }

    @Test func paletteIndexSpreadsAcrossPalette() {
        let names = ["Alice", "Bob", "Carol", "Dave", "Eve", "Frank", "Grace", "Heidi", "Ivan", "Judy"]
        let indices = Set(names.map { AvatarStyle.paletteIndex(for: $0, paletteCount: 8) })
        #expect(indices.count >= 4)
    }
}
