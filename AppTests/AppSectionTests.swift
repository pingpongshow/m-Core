import Foundation
import Testing
@testable import mCore

struct AppSectionTests {
    @Test func navigationOrderMatchesPlan() {
        #expect(AppSection.allCases.map(\.title) == ["Chats", "Nodes", "Map", "Tools", "Settings"])
    }

    @Test func everySectionHasASymbol() {
        for section in AppSection.allCases {
            #expect(!section.systemImage.isEmpty)
        }
    }
}

struct MapStyleTests {
    private func style(sources: [String] = ["pmtiles://file:///a.pmtiles", "pmtiles://file:///b.pmtiles"]) -> [String: Any] {
        MapStyle(sources: sources, palette: .light, glyphsDirectory: URL(filePath: "/Glyphs/", directoryHint: .isDirectory)).json()
    }

    @Test func drawsOnlyRoadsPlacesBoundariesAndCoastline() throws {
        let layers = try #require(style()["layers"] as? [[String: Any]])
        let sourceLayers = Set(layers.compactMap { $0["source-layer"] as? String })
        #expect(sourceLayers == ["roads", "places", "boundaries", "earth"])
        // The land outline is a line, never a fill: water and land use stay undrawn.
        #expect(!layers.contains { $0["type"] as? String == "fill" })
        #expect(layers.filter { $0["source-layer"] as? String == "earth" }.allSatisfy { $0["type"] as? String == "line" })
    }

    @Test func eachAreaGetsItsOwnSourceAndLabelsAreDrawnLast() throws {
        let json = style()
        let sources = try #require(json["sources"] as? [String: Any])
        #expect(sources.count == 2)
        let layers = try #require(json["layers"] as? [[String: Any]])
        let types = layers.compactMap { $0["type"] as? String }
        let firstSymbol = try #require(types.firstIndex(of: "symbol"))
        #expect(!types[firstSymbol...].contains("line"))
        #expect((json["glyphs"] as? String) == "file:///Glyphs/{fontstack}/{range}.pbf")
    }
}
