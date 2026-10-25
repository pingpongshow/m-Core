import Foundation
import Testing
@testable import MeshTools

struct CoverageExportTests {
    let samples = [
        CoverageSample(
            time: Date(timeIntervalSince1970: 1_716_554_100), coordinate: GeoCoordinate(latitude: 47.6062, longitude: -122.3321),
            snr: -4.25, rssi: -101, success: true, note: "Bridge <north> & \"east\" ridge's"
        ),
        CoverageSample(
            time: Date(timeIntervalSince1970: 1_716_554_000), coordinate: GeoCoordinate(latitude: 47.61, longitude: -122.33),
            success: false
        ),
    ]

    @Test func gpxIsWellFormedAndEscaped() throws {
        let gpx = CoverageExport.gpx(samples, name: "Walk & talk")
        #expect(gpx.hasPrefix(#"<?xml version="1.0" encoding="UTF-8"?>"#))
        #expect(gpx.contains(#"<gpx version="1.1" creator="m-Core" xmlns="http://www.topografix.com/GPX/1/1""#))
        #expect(gpx.contains("<name>Walk &amp; talk</name>"))
        #expect(gpx.contains("<desc>Bridge &lt;north&gt; &amp; &quot;east&quot; ridge&apos;s</desc>"))
        #expect(gpx.contains(#"<wpt lat="47.6062000" lon="-122.3321000">"#))
        #expect(gpx.contains("<mcore:snr>-4.25</mcore:snr>"))
        #expect(gpx.contains("<mcore:rssi>-101</mcore:rssi>"))
        #expect(gpx.contains("<mcore:success>false</mcore:success>"))
        #expect(gpx.contains("<time>2024-05-24T12:35:00Z</time>"))
        // Metadata time is the earliest sample.
        #expect(gpx.contains("<metadata>\n    <name>Walk &amp; talk</name>\n    <time>2024-05-24T12:33:20Z</time>"))

        let parser = XMLParser(data: Data(gpx.utf8))
        #expect(parser.parse(), "GPX should be well-formed: \(String(describing: parser.parserError))")
    }

    @Test func gpxTrackIsTimeOrdered() throws {
        let gpx = CoverageExport.gpx(samples, content: .track)
        #expect(!gpx.contains("<wpt"))
        let first = try #require(gpx.range(of: #"<trkpt lat="47.6100000""#))
        let second = try #require(gpx.range(of: #"<trkpt lat="47.6062000""#))
        #expect(first.lowerBound < second.lowerBound)
        #expect(!CoverageExport.gpx([], content: .track).contains("<trk>"))
    }

    @Test func xmlEscapeDropsIllegalCharacters() {
        #expect(CoverageExport.xmlEscape("a\u{01}b\u{FFFE}c\td") == "abc\td")
    }

    @Test func csvQuotesWhenNeeded() {
        let csv = CoverageExport.csv(samples)
        let rows = csv.components(separatedBy: "\r\n")
        #expect(rows[0] == "time,latitude,longitude,snr,rssi,success,note")
        #expect(rows[1] == #"2024-05-24T12:35:00Z,47.6062000,-122.3321000,-4.25,-101,true,"Bridge <north> & ""east"" ridge's""#)
        #expect(rows[2] == "2024-05-24T12:33:20Z,47.6100000,-122.3300000,,,false,")
        #expect(rows.count == 4 && rows[3].isEmpty)

        let multiline = CoverageSample(time: Date(timeIntervalSince1970: 0), coordinate: GeoCoordinate(latitude: 0, longitude: 0),
                                       snr: 6, success: true, note: "a,b\nc")
        #expect(CoverageExport.csv([multiline]).contains(",6,,true,\"a,b\nc\""))
    }
}
