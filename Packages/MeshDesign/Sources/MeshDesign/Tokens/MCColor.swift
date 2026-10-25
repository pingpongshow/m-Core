import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Semantic colours for m-Core. Every token has a light and a dark value.
public enum MCColor {
    public static let accent = Color(light: Color(hex: 0x2563EB), dark: Color(hex: 0x4C8DFF))

    public static let bubbleOutgoing = accent
    public static let bubbleOutgoingText = Color.white
    public static let bubbleIncoming = Color(light: Color(hex: 0xE9E9EE), dark: Color(hex: 0x2C2C31))

    public static let surface = Color(light: Color(hex: 0xF2F2F7), dark: Color(hex: 0x000000))
    public static let surfaceElevated = Color(light: Color(hex: 0xFFFFFF), dark: Color(hex: 0x1C1C1E))
    public static let chipBackground = Color(light: Color(hex: 0xE5E5EA), dark: Color(hex: 0x2C2C2E))

    public static let positive = Color(light: Color(hex: 0x34C759), dark: Color(hex: 0x30D158))
    public static let warning = Color(light: Color(hex: 0xFF9500), dark: Color(hex: 0xFF9F0A))
    public static let critical = Color(light: Color(hex: 0xFF3B30), dark: Color(hex: 0xFF453A))

    // Node types, matching the map pins and avatars.
    public static let contact = Color(light: Color(hex: 0xB5714E), dark: Color(hex: 0xC98462))
    public static let repeater = Color(light: Color(hex: 0x1BA7D0), dark: Color(hex: 0x3CC3EA))
    public static let room = Color(light: Color(hex: 0xEE8A1E), dark: Color(hex: 0xF5A03C))
    public static let sensor = Color(light: Color(hex: 0x8E5BD9), dark: Color(hex: 0xA67CF0))
    public static let channel = Color(light: Color(hex: 0x3D5A80), dark: Color(hex: 0x4F6E99))

    /// Muted backgrounds for contact avatars; white initials stay readable on all of them.
    public static let avatarPalette: [Color] = [
        Color(hex: 0x4E3F7A), Color(hex: 0x3E5F4A), Color(hex: 0x7A3B47), Color(hex: 0x5C5A2E),
        Color(hex: 0x2F5A7A), Color(hex: 0x7A5A2F), Color(hex: 0x2F6B6B), Color(hex: 0x6B2F5F),
    ]
}

public extension Color {
    /// Creates a colour from a 24-bit RGB value, e.g. `0x2563EB`.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    /// Creates a colour that resolves differently in light and dark appearance.
    init(light: Color, dark: Color) {
        #if canImport(UIKit)
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
        #elseif canImport(AppKit)
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
        })
        #endif
    }
}
