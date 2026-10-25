import Testing
@testable import MeshDesign

struct StatusTests {
    @Test(arguments: [
        (0.0, "just now"),
        (4.4, "just now"),
        (12, "12 s ago"),
        (59, "59 s ago"),
        (60, "1 min ago"),
        (3_599, "59 min ago"),
        (7_200, "2 h ago"),
        (172_800, "2 d ago"),
        (-5, "just now"),
    ])
    func relativeAge(seconds: Double, expected: String) {
        #expect(RelativeAge.text(seconds: seconds) == expected)
    }

    @Test func gpsFeedText() {
        #expect(GPSFeedStatus.off.text == "GPS Feed off")
        #expect(GPSFeedStatus.radioGPS(lastPositionAge: nil).text == "Radio GPS")
        #expect(GPSFeedStatus.radioGPS(lastPositionAge: 12).text == "Radio GPS · 12 s ago")
        #expect(GPSFeedStatus.phone(accuracyMeters: 7.6, lastSyncAge: 12).text == "Phone · ±8 m · synced 12 s ago")
        #expect(GPSFeedStatus.phone(accuracyMeters: 25, lastSyncAge: nil).text == "Phone · ±25 m")
    }

    @Test func gpsFeedTone() {
        #expect(GPSFeedStatus.radioGPS(lastPositionAge: nil).tone == .positive)
        #expect(GPSFeedStatus.waitingForPhoneLocation.tone == .warning)
        #expect(GPSFeedStatus.locationAccessNeeded.tone == .critical)
    }

    @Test func connectionText() {
        #expect(ConnectionStatus.connected(name: "Heltec V3").text == "Heltec V3")
        #expect(ConnectionStatus.connecting(name: "T1000-E").text == "Connecting to T1000-E…")
        #expect(ConnectionStatus.disconnected.tone == .critical)
    }

    @Test(arguments: [
        (nil as Double?, SignalLevel.noSignal),
        (8, .excellent),
        (5, .excellent),
        (4.9, .good),
        (0, .good),
        (-0.5, .fair),
        (-7, .fair),
        (-7.5, .weak),
        (-15, .weak),
        (-15.5, .noSignal),
    ])
    func signalLevel(snr: Double?, expected: SignalLevel) {
        #expect(SignalLevel(snr: snr) == expected)
    }
}
