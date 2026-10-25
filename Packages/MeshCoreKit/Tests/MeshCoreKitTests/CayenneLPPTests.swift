import Foundation
import Testing
@testable import MeshCoreKit

struct CayenneLPPTests {
    @Test func decodesTypicalMeshCoreTelemetry() {
        // ch1 voltage 4.05 V (0x0195 = 405), ch1 temperature 27.2 °C (0x0110 = 272), ch2 humidity 41.5 % (83).
        let readings = CayenneLPP.decode(hex("0174", "0195", "0167", "0110", "0268", "53"))
        #expect(readings == [
            LPPReading(channel: 1, kind: .voltage, values: [4.05]),
            LPPReading(channel: 1, kind: .temperature, values: [27.2]),
            LPPReading(channel: 2, kind: .humidity, values: [41.5]),
        ])
    }

    @Test func decodesNegativeTemperatureAndPressure() {
        // -4.1 °C = 0xFFD7; 1013.2 hPa = 10132 = 0x2794.
        let readings = CayenneLPP.decode(hex("0367", "ffd7", "0473", "2794"))
        #expect(abs(readings[0].value - -4.1) < 1e-9)
        #expect(abs(readings[1].value - 1013.2) < 1e-9)
        #expect(readings[1].kind.name == "pressure")
    }

    @Test func decodesGPS() {
        // lat 37.7749 → 377749 = 0x05C395; lon -122.4194 → -1224194 = 0xED51FE; alt 52.00 m → 5200 = 0x001450.
        let readings = CayenneLPP.decode(hex("0188", "05c395", "ed51fe", "001450"))
        let gps = readings[0]
        #expect(gps.kind == .gps)
        #expect(abs(gps.values[0] - 37.7749) < 1e-9)
        #expect(abs(gps.values[1] - -122.4194) < 1e-9)
        #expect(abs(gps.values[2] - 52) < 1e-9)
    }

    @Test func stopsAtUnknownTypeOrTruncation() {
        #expect(CayenneLPP.decode(hex("0174", "0195", "01fe", "0000")).count == 1)
        #expect(CayenneLPP.decode(hex("0174", "01")).isEmpty)
        #expect(CayenneLPP.decode(Data()).isEmpty)
    }

    @Test func stopsAtZeroPaddingFromBlockDecryption() {
        // A remote telemetry reply: voltage, then AES block padding. Each "00 00 00" used to decode as
        // a channel-0 digital input reading of 0.
        let readings = CayenneLPP.decode(hex("0174", "0195", zeros(9)))
        #expect(readings == [LPPReading(channel: 1, kind: .voltage, values: [4.05])])
    }

    @Test func currentIsSigned() {
        // -0.120 A = -120 = 0xFF88, as CayenneLPP 1.6.1's addCurrent writes it.
        let readings = CayenneLPP.decode(hex("0275", "ff88"))
        #expect(abs(readings[0].value - -0.12) < 1e-9)
    }

    @Test func multiFieldTypes() {
        let readings = CayenneLPP.decode(hex("0571", "03e8", "fc18", "0000"))
        #expect(readings[0].values == [1, -1, 0])
    }
}
