import Foundation

/// Builds m-Core's minimal MapLibre style: roads with names, place labels, country/state boundaries and a thin
/// coastline on a plain background, drawn from the Protomaps v4 basemap layers. Water, land use and everything
/// else in the tiles is never drawn.
struct MapStyle {
    struct Palette {
        var background: String
        var coastline: String
        var boundaryCountry: String
        var boundaryRegion: String
        var highway: String
        var highwayCasing: String
        var majorRoad: String
        var minorRoad: String
        var roadCasing: String
        var path: String
        var label: String
        var labelMinor: String
        var labelHalo: String

        static let light = Palette(
            background: "#f2efe9", coastline: "#b9c6cf", boundaryCountry: "#9e9cab", boundaryRegion: "#b8b6c2",
            highway: "#f6c87a", highwayCasing: "#d9a556", majorRoad: "#ffffff", minorRoad: "#ffffff",
            roadCasing: "#d6d2c8", path: "#c9c4b8", label: "#3c3c3c", labelMinor: "#6b6b6b", labelHalo: "#f2efe9"
        )

        static let dark = Palette(
            background: "#1c1d20", coastline: "#3d4a55", boundaryCountry: "#6c6a78", boundaryRegion: "#4c4a56",
            highway: "#6e5a35", highwayCasing: "#4a3d25", majorRoad: "#45474d", minorRoad: "#37393e",
            roadCasing: "#2a2b2f", path: "#3a3b40", label: "#d8d8d8", labelMinor: "#a0a0a0", labelHalo: "#1c1d20"
        )
    }

    /// Font stack name; matches the folder in `App/Glyphs`.
    static let font = "NotoSans-Regular"

    /// PMTiles source URLs (`pmtiles://file://…`), drawn in order so later areas sit on top.
    var sources: [String]
    var palette: Palette
    var glyphsDirectory: URL

    /// The bundled world overview (z0–5), shown underneath any downloaded areas.
    static var overviewSource: String? {
        Bundle.main.url(forResource: "world-overview", withExtension: "pmtiles").map { "pmtiles://" + $0.absoluteString }
    }

    /// A sourceless style shown until the real one is written, so MapLibre never falls back to its online default.
    static let placeholderJSON = #"{"version":8,"sources":{},"layers":[]}"#

    static var bundledGlyphs: URL {
        Bundle.main.bundleURL.appending(path: "Glyphs", directoryHint: .isDirectory)
    }

    func json() -> [String: Any] {
        var sourceObjects: [String: Any] = [:]
        var layers: [[String: Any]] = [["id": "background", "type": "background", "paint": ["background-color": palette.background]]]
        let ids = sources.indices.map { "src\($0)" }
        for (id, url) in zip(ids, sources) {
            sourceObjects[id] = ["type": "vector", "url": url, "attribution": "© OpenStreetMap contributors · Protomaps"]
        }
        // Lines first for every source, then labels, so no area's lines cover another area's labels.
        for id in ids { layers += SourceLayers(source: id, palette: palette).lineLayers() }
        for id in ids { layers += SourceLayers(source: id, palette: palette).labelLayers() }
        return [
            "version": 8,
            "name": "m-Core",
            "glyphs": glyphsDirectory.absoluteString + "{fontstack}/{range}.pbf",
            "sources": sourceObjects,
            "layers": layers
        ]
    }

    /// Writes the style to a file MapLibre can load and returns its URL.
    func write(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(name).json")
        let data = try JSONSerialization.data(withJSONObject: json(), options: [.sortedKeys])
        try data.write(to: url, options: .atomic)
        return url
    }
}

// MARK: Layers

/// The layers drawn from one PMTiles source.
private struct SourceLayers {
    let source: String
    let palette: MapStyle.Palette

    func lineLayers() -> [[String: Any]] {
        [
            // Only the outline of the land, so coasts are recognisable; water and land are never filled.
            line("earth", id: "coastline", filter: ["==", ["geometry-type"], "Polygon"],
                 color: palette.coastline, width: zoomed([(0, 0.4), (10, 1)])),
            line("boundaries", id: "boundary-region", filter: ["==", ["get", "kind"], "region"], minZoom: 3,
                 color: palette.boundaryRegion, width: zoomed([(3, 0.5), (10, 1.2)]), dash: [2, 2]),
            line("boundaries", id: "boundary-country", filter: ["==", ["get", "kind"], "country"],
                 color: palette.boundaryCountry, width: zoomed([(0, 0.6), (10, 2)])),
            line("roads", id: "road-path", filter: kind("path"), minZoom: 14,
                 color: palette.path, width: zoomed([(14, 0.5), (18, 2)]), dash: [2, 1]),
            line("roads", id: "road-minor-casing", filter: kind("minor_road"), minZoom: 13,
                 color: palette.roadCasing, width: zoomed([(13, 1.5), (18, 14)])),
            line("roads", id: "road-minor", filter: kind("minor_road"), minZoom: 11,
                 color: palette.minorRoad, width: zoomed([(11, 0.5), (13, 1), (18, 11)])),
            line("roads", id: "road-major-casing", filter: kind("major_road"), minZoom: 10,
                 color: palette.roadCasing, width: zoomed([(10, 1.5), (18, 18)])),
            line("roads", id: "road-major", filter: kind("major_road"), minZoom: 6,
                 color: palette.majorRoad, width: zoomed([(6, 0.5), (10, 1), (18, 15)])),
            line("roads", id: "road-highway-casing", filter: kind("highway"), minZoom: 8,
                 color: palette.highwayCasing, width: zoomed([(8, 1.5), (18, 22)])),
            line("roads", id: "road-highway", filter: kind("highway"), minZoom: 3,
                 color: palette.highway, width: zoomed([(3, 0.4), (8, 1), (18, 18)]))
        ]
    }

    func labelLayers() -> [[String: Any]] {
        let locality: [Any] = ["==", ["get", "kind"], "locality"]
        return [
            roadLabel(id: "label-road-minor", filter: ["any", kind("minor_road"), kind("path")], minZoom: 15, size: 11),
            roadLabel(id: "label-road-major", filter: ["any", kind("major_road"), kind("highway")], minZoom: 12, size: 12),
            place(id: "label-neighbourhood", filter: ["in", ["get", "kind"], ["literal", ["neighbourhood", "macrohood"]]],
                  minZoom: 13, size: 11, color: palette.labelMinor, uppercase: true),
            place(id: "label-village", filter: ["all", locality, [">", ["get", "min_zoom"], 10]],
                  minZoom: 11, size: 12, color: palette.labelMinor),
            place(id: "label-town", filter: ["all", locality, ["<=", ["get", "min_zoom"], 10], [">", ["get", "min_zoom"], 7]],
                  minZoom: 8, size: zoomed([(8, 12), (14, 15)]), color: palette.label),
            place(id: "label-city", filter: ["all", locality, ["<=", ["get", "min_zoom"], 7]],
                  minZoom: 3, size: zoomed([(3, 11), (8, 15), (14, 19)]), color: palette.label),
            place(id: "label-region", filter: ["==", ["get", "kind"], "region"],
                  minZoom: 4, maxZoom: 9, size: zoomed([(4, 10), (8, 13)]), color: palette.labelMinor, uppercase: true),
            place(id: "label-country", filter: ["==", ["get", "kind"], "country"],
                  minZoom: 1, maxZoom: 7, size: zoomed([(1, 10), (6, 15)]), color: palette.label)
        ]
    }

    private func kind(_ value: String) -> [Any] { ["==", ["get", "kind"], value] }

    private func zoomed(_ stops: [(Double, Double)]) -> [Any] {
        var expression: [Any] = ["interpolate", ["exponential", 1.4], ["zoom"]]
        for (zoom, value) in stops { expression += [zoom, value] }
        return expression
    }

    private func line(
        _ sourceLayer: String, id: String, filter: [Any], minZoom: Double = 0,
        color: String, width: Any, dash: [Double]? = nil
    ) -> [String: Any] {
        var paint: [String: Any] = ["line-color": color, "line-width": width]
        if let dash { paint["line-dasharray"] = dash }
        return [
            "id": "\(source)-\(id)", "type": "line", "source": source, "source-layer": sourceLayer,
            "filter": filter, "minzoom": minZoom,
            "layout": ["line-cap": "round", "line-join": "round"], "paint": paint
        ]
    }

    private func roadLabel(id: String, filter: [Any], minZoom: Double, size: Double) -> [String: Any] {
        [
            "id": "\(source)-\(id)", "type": "symbol", "source": source, "source-layer": "roads",
            "filter": ["all", filter, ["has", "name"]], "minzoom": minZoom,
            "layout": [
                "symbol-placement": "line", "text-field": ["get", "name"], "text-font": [MapStyle.font],
                "text-size": size, "text-max-angle": 30
            ],
            "paint": ["text-color": palette.labelMinor, "text-halo-color": palette.labelHalo, "text-halo-width": 1.5]
        ]
    }

    private func place(
        id: String, filter: [Any], minZoom: Double, maxZoom: Double = 24, size: Any,
        color: String, uppercase: Bool = false
    ) -> [String: Any] {
        [
            "id": "\(source)-\(id)", "type": "symbol", "source": source, "source-layer": "places",
            "filter": ["all", filter, ["has", "name"]], "minzoom": minZoom, "maxzoom": maxZoom,
            "layout": [
                "text-field": ["get", "name"], "text-font": [MapStyle.font], "text-size": size,
                "text-transform": uppercase ? "uppercase" : "none", "text-letter-spacing": uppercase ? 0.08 : 0,
                "text-max-width": 8, "symbol-sort-key": ["get", "min_zoom"]
            ],
            "paint": ["text-color": color, "text-halo-color": palette.labelHalo, "text-halo-width": 1.5]
        ]
    }
}
