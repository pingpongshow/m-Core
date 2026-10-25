import Testing
@testable import MeshDesign

struct MessageMetadataTests {
    @Test func routeText() {
        #expect(MessageRoute.flood.text == "Flood")
        #expect(MessageRoute.direct(hops: []).text == "Direct")
        #expect(MessageRoute.direct(hops: ["10A3", "20B7"]).text == "10A3, 20B7")
    }

    @Test func hopHashesFormatOneAndTwoByteHashes() {
        #expect(MessageRoute.hopHashes([[0x10, 0xA3], [0x20, 0xB7]]) == ["10A3", "20B7"])
        #expect(MessageRoute.hopHashes([[0x0A], [0xFF]]) == ["0A", "FF"])
    }

    @Test(arguments: [
        (DeliveryStatus.sending, "Sending…"),
        (.sent, "Sent"),
        (.repeated(count: 1), "1 repeat"),
        (.repeated(count: 3), "3 repeats"),
        (.delivered(repeats: 0), "Delivered"),
        (.delivered(repeats: 1), "1 repeat · Delivered"),
        (.failed, "Failed"),
    ])
    func deliveryText(status: DeliveryStatus, expected: String) {
        #expect(status.text == expected)
    }
}
