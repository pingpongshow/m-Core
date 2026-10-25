import Foundation

/// A CayenneLPP data type, as used by MeshCore telemetry. Values are big-endian.
public enum LPPKind: UInt8, Sendable, CaseIterable {
    case digitalInput = 0
    case digitalOutput = 1
    case analogInput = 2
    case analogOutput = 3
    case genericSensor = 100
    case illuminance = 101
    case presence = 102
    case temperature = 103
    case humidity = 104
    case accelerometer = 113
    case barometer = 115
    case voltage = 116
    case current = 117
    case frequency = 118
    case percentage = 120
    case altitude = 121
    case load = 122
    case concentration = 125
    case power = 128
    case distance = 130
    case energy = 131
    case direction = 132
    case unixTime = 133
    case gyrometer = 134
    case colour = 135
    case gps = 136
    case switchValue = 142

    /// Payload layout: field count, bytes per field, signedness, and the divisor applied to each raw value.
    struct Layout {
        let fields: Int
        let bytes: Int
        let signed: Bool
        let divisor: Double

        init(_ fields: Int, _ bytes: Int, _ signed: Bool, _ divisor: Double) {
            self.fields = fields
            self.bytes = bytes
            self.signed = signed
            self.divisor = divisor
        }
    }

    var layout: Layout {
        switch self {
        case .digitalInput, .digitalOutput, .presence, .switchValue, .percentage: Layout(1, 1, false, 1)
        case .analogInput, .analogOutput: Layout(1, 2, true, 100)
        case .genericSensor, .frequency, .unixTime: Layout(1, 4, false, 1)
        case .illuminance, .concentration, .power, .direction: Layout(1, 2, false, 1)
        case .temperature: Layout(1, 2, true, 10)
        case .humidity: Layout(1, 1, false, 2)
        case .accelerometer: Layout(3, 2, true, 1_000)
        case .barometer: Layout(1, 2, false, 10)
        case .voltage: Layout(1, 2, false, 100)
        // Signed in the CayenneLPP 1.6.1 encoder the firmware uses, and in MeshCore's own `LPPReader`:
        // a discharging INA sensor reports a negative current.
        case .current: Layout(1, 2, true, 1_000)
        case .altitude: Layout(1, 2, true, 1)
        case .load: Layout(1, 3, true, 1_000)
        case .distance, .energy: Layout(1, 4, false, 1_000)
        case .gyrometer: Layout(3, 2, true, 100)
        case .colour: Layout(3, 1, false, 1)
        case .gps: Layout(3, 3, true, 1) // per-field divisors below
        }
    }

    /// Short storage key, e.g. "voltage".
    public var name: String {
        switch self {
        case .digitalInput: "digitalInput"
        case .digitalOutput: "digitalOutput"
        case .analogInput: "analogInput"
        case .analogOutput: "analogOutput"
        case .genericSensor: "generic"
        case .illuminance: "illuminance"
        case .presence: "presence"
        case .temperature: "temperature"
        case .humidity: "humidity"
        case .accelerometer: "accelerometer"
        case .barometer: "pressure"
        case .voltage: "voltage"
        case .current: "current"
        case .frequency: "frequency"
        case .percentage: "percentage"
        case .altitude: "altitude"
        case .load: "load"
        case .concentration: "concentration"
        case .power: "power"
        case .distance: "distance"
        case .energy: "energy"
        case .direction: "direction"
        case .unixTime: "time"
        case .gyrometer: "gyrometer"
        case .colour: "colour"
        case .gps: "gps"
        case .switchValue: "switch"
        }
    }

    /// Display unit, e.g. "V".
    public var unit: String {
        switch self {
        case .temperature: "°C"
        case .humidity, .percentage: "%"
        case .barometer: "hPa"
        case .voltage: "V"
        case .current: "A"
        case .frequency: "Hz"
        case .altitude, .distance: "m"
        case .illuminance: "lx"
        case .concentration: "ppm"
        case .power: "W"
        case .energy: "kWh"
        case .direction: "°"
        default: ""
        }
    }
}

/// One decoded reading: a channel, its type and its value(s). GPS is [latitude, longitude, altitude m].
public struct LPPReading: Equatable, Hashable, Sendable {
    public var channel: UInt8
    public var kind: LPPKind
    public var values: [Double]

    public init(channel: UInt8, kind: LPPKind, values: [Double]) {
        self.channel = channel
        self.kind = kind
        self.values = values
    }

    public var value: Double { values.first ?? 0 }
}

public enum CayenneLPP {
    /// Decodes readings until the data ends, channel 0 (end of data, as in MeshCore's `LPPReader`) or an
    /// unknown type (its length can't be known). Remote replies are decrypted in 16-byte blocks, so they
    /// usually end in zero padding that would otherwise read as bogus channel-0 digital inputs.
    public static func decode(_ data: Data) -> [LPPReading] {
        let bytes = [UInt8](data)
        var readings: [LPPReading] = []
        var index = 0
        while index + 2 <= bytes.count {
            let channel = bytes[index]
            guard channel != 0, let kind = LPPKind(rawValue: bytes[index + 1]) else { break }
            let layout = kind.layout
            let length = layout.fields * layout.bytes
            let start = index + 2
            guard start + length <= bytes.count else { break }
            let raw = (0..<layout.fields).map { field in
                integer(bytes[(start + field * layout.bytes)..<(start + (field + 1) * layout.bytes)], signed: layout.signed)
            }
            let values: [Double]
            if kind == .gps {
                values = [Double(raw[0]) / 10_000, Double(raw[1]) / 10_000, Double(raw[2]) / 100]
            } else {
                values = raw.map { Double($0) / layout.divisor }
            }
            readings.append(LPPReading(channel: channel, kind: kind, values: values))
            index = start + length
        }
        return readings
    }

    /// Big-endian integer of 1–4 bytes, sign-extended when `signed`.
    private static func integer(_ slice: ArraySlice<UInt8>, signed: Bool) -> Int64 {
        let unsigned = slice.reduce(Int64(0)) { $0 << 8 | Int64($1) }
        guard signed else { return unsigned }
        let bits = Int64(slice.count * 8)
        let signBit = Int64(1) << (bits - 1)
        return unsigned & signBit != 0 ? unsigned - (Int64(1) << bits) : unsigned
    }
}
