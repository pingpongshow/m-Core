import CryptoKit
import Foundation

extension MockRadio {
    /// Deterministic key whose bytes all derive from `seed`.
    public static func demoKey(_ seed: UInt8) -> PublicKey {
        PublicKey(bytes: (0..<32).map { seed &+ UInt8($0) &* 7 })!
    }

    /// A populated radio for running the app without hardware: San Francisco contacts, channels and a few messages.
    public static var demoState: State {
        var state = sampleState
        state.clock = UInt32(Date().timeIntervalSince1970) - 60
        let clock = state.clock
        func contact(
            _ seed: UInt8, _ name: String, _ type: AdvertType, lat: Double, lon: Double,
            path: MeshPath? = .empty, favourite: Bool = false, heardAgo: UInt32 = 600
        ) -> Contact {
            Contact(
                publicKey: demoKey(seed), type: type, flags: favourite ? 1 : 0, outPath: path, name: name,
                lastAdvert: clock - heardAgo, latitudeE6: Int32(lat * 1e6), longitudeE6: Int32(lon * 1e6),
                lastModified: clock - heardAgo
            )
        }
        state.contacts = [
            contact(0x0A, "Alice Chen", .chat, lat: 37.7955, lon: -122.3937, path: MeshPath(hashSize: 1, hashes: [[0x10], [0xA3]])),
            contact(0x14, "Bob Martinez", .chat, lat: 37.7599, lon: -122.4148, path: MeshPath(hashSize: 1, hashes: [[0x20]])),
            contact(0x50, "Hannah Lee", .chat, lat: 37.7280, lon: -122.4900,
                    path: MeshPath(hashSize: 1, hashes: [[0x30]]), favourite: true),
            contact(0x3C, "Dad", .chat, lat: 37.7340, lon: -122.4600, path: nil, heardAgo: 3_600),
            contact(0x32, "Eve Thompson", .chat, lat: 37.7450, lon: -122.4700, path: nil, heardAgo: 7_200),
            contact(0x10, "Charlie Node", .repeater, lat: 37.7544, lon: -122.4477),
            contact(0xA3, "Twin Peaks RPT", .repeater, lat: 37.7520, lon: -122.4470, heardAgo: 120),
            contact(0x44, "Diana's Room", .room, lat: 37.7475, lon: -122.4400),
            contact(0x66, "Weather Station", .sensor, lat: 37.8000, lon: -122.4500, heardAgo: 1_800),
        ]
        state.channels.append(ChannelInfo(index: 1, name: "#test", secret: [UInt8](Data(hexString: "9cd8fcf22a47333b591d96a2b848b73f")!)))
        state.channels.append(ChannelInfo(index: 2, name: "Bay Area", secret: (0..<16).map { UInt8(0x40 + $0) }))
        state.selfInfo.name = "Sim"
        state.repeaterStatus = demoRepeaterStatus
        state.queuedMessages = [
            .channelMessage(ChannelMessage(
                channelIndex: 0, routing: .flood(hops: 1), senderTimestamp: clock - 5_400,
                text: "Carol Diaz: Welcome to all the new members this week!", snr: 6.5
            )),
            .channelMessage(ChannelMessage(
                channelIndex: 2, routing: .flood(hops: 1), senderTimestamp: clock - 1_800,
                text: "Carol Diaz: @[Sim] can you cover the cleanup this Saturday?", snr: 4
            )),
            .contactMessage(ContactMessage(
                senderPrefix: demoKey(0x0A).prefix, routing: .flood(hops: 2), senderTimestamp: clock - 900,
                text: "Yeah! Want to go hiking? 🥾", snr: 3.25
            )),
            .contactMessage(ContactMessage(
                senderPrefix: demoKey(0x50).prefix, routing: .direct, senderTimestamp: clock - 300,
                text: "Meet me at the trailhead: 37.8651, -119.5383", snr: 8
            )),
        ]
        return state
    }

    /// The radio's own flood advert packet, as export-contact returns it: header, empty path, key, timestamp,
    /// a demo signature, then app data with type, position (when set) and name.
    public static func selfAdvert(for state: State) -> Data {
        let info = state.selfInfo
        var appData = Data()
        let hasPosition = info.latitudeE6 != 0 || info.longitudeE6 != 0
        appData.append(info.advertType.rawValue & 0x0F | (hasPosition ? 0x10 : 0) | 0x80)
        if hasPosition {
            for value in [info.latitudeE6, info.longitudeE6] {
                appData.append(contentsOf: withUnsafeBytes(of: value.littleEndian) { Array($0) })
            }
        }
        appData.append(Data(info.name.utf8))
        let timestamp = Data(withUnsafeBytes(of: state.clock.littleEndian) { Array($0) })
        let signature = demoSignature(of: Data(info.publicKey.bytes) + timestamp + appData)
        return Data([0x11, 0x00]) + Data(info.publicKey.bytes) + timestamp + signature + appData
    }

    /// Stand-in for the radio's Ed25519 signature: deterministic 64 bytes derived from the data.
    public static func demoSignature(of data: Data) -> Data {
        let digest = SHA256.hash(data: data)
        return Data(digest) + Data(digest.reversed())
    }
}

/// RepeaterStats for a healthy repeater: 4.12 V, -112 dBm noise, 3 days up.
let demoRepeaterStatus: Data = {
    var bytes: [UInt8] = []
    func u16(_ value: UInt16) { bytes += [UInt8(value & 0xFF), UInt8(value >> 8)] }
    func u32(_ value: UInt32) { bytes += (0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) } }
    u16(4_120); u16(0); u16(UInt16(bitPattern: -112)); u16(UInt16(bitPattern: -78))
    u32(18_250); u32(9_640); u32(1_830); u32(259_200)
    u32(4_100); u32(5_540); u32(11_900); u32(6_350)
    u16(0); u16(UInt16(bitPattern: 38)); u16(12); u16(410)
    u32(5_210); u32(7)
    return Data(bytes)
}()
