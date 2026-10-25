import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Semantic colours for m-Core. Every token has a light and a dark value; status and accent colours also have
/// stronger variants used when Increase Contrast is on (in iOS Settings, or m-Core's own High contrast option).
public enum MCColor {
    public static let accent = Color(light: Color(hex: 0x2563EB), dark: Color(hex: 0x4C8DFF),
                                     highContrastLight: Color(hex: 0x1239A6), highContrastDark: Color(hex: 0x8FB6FF))

    /// Accent as a fill behind white text (outgoing bubbles, badges, selected chips). Its high-contrast dark value
    /// goes darker, not lighter like `accent`'s (which is tuned for text on a dark background), so white text stays
    /// readable: about 6.7:1 instead of 2:1.
    public static let accentFill = Color(light: Color(hex: 0x2563EB), dark: Color(hex: 0x4C8DFF),
                                         highContrastLight: Color(hex: 0x1239A6), highContrastDark: Color(hex: 0x1D4ED8))

    public static let bubbleOutgoing = accentFill
    public static let bubbleOutgoingText = Color.white
    public static let bubbleIncoming = Color(light: Color(hex: 0xE9E9EE), dark: Color(hex: 0x2C2C31),
                                             highContrastLight: Color(hex: 0xD1D1D8), highContrastDark: Color(hex: 0x45454D))

    public static let surface = Color(light: Color(hex: 0xF2F2F7), dark: Color(hex: 0x000000))
    public static let surfaceElevated = Color(light: Color(hex: 0xFFFFFF), dark: Color(hex: 0x1C1C1E))
    public static let chipBackground = Color(light: Color(hex: 0xE5E5EA), dark: Color(hex: 0x2C2C2E),
                                             highContrastLight: Color(hex: 0xC7C7CC), highContrastDark: Color(hex: 0x48484A))

    public static let positive = Color(light: Color(hex: 0x34C759), dark: Color(hex: 0x30D158),
                                       highContrastLight: Color(hex: 0x1C7A35), highContrastDark: Color(hex: 0x6BE38A))
    public static let warning = Color(light: Color(hex: 0xFF9500), dark: Color(hex: 0xFF9F0A),
                                      highContrastLight: Color(hex: 0xA35A00), highContrastDark: Color(hex: 0xFFC266))
    public static let critical = Color(light: Color(hex: 0xFF3B30), dark: Color(hex: 0xFF453A),
                                       highContrastLight: Color(hex: 0xB0170E), highContrastDark: Color(hex: 0xFF8A80))

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

    /// Creates a colour that resolves differently in light and dark appearance, and optionally with increased contrast.
    init(light: Color, dark: Color, highContrastLight: Color? = nil, highContrastDark: Color? = nil) {
        #if canImport(UIKit)
        self.init(uiColor: UIColor { traits in
            let high = traits.accessibilityContrast == .high
            if traits.userInterfaceStyle == .dark {
                return UIColor(high ? highContrastDark ?? dark : dark)
            }
            return UIColor(high ? highContrastLight ?? light : light)
        })
        #elseif canImport(AppKit)
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
        })
        #endif
    }
}
