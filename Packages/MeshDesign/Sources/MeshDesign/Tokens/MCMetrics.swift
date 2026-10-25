import SwiftUI

public enum MCSpacing {
    public static let xxs: CGFloat = 2
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 12
    public static let l: CGFloat = 16
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32
}

public enum MCRadius {
    public static let bubble: CGFloat = 18
    public static let card: CGFloat = 16
    public static let control: CGFloat = 22
}

public enum MCSize {
    /// Minimum tap target, also the floating button diameter.
    public static let control: CGFloat = 44
    public static let avatarRow: CGFloat = 44
    public static let avatarDetail: CGFloat = 120
}

public enum MCFont {
    /// Path hashes and keys, e.g. `10A3, 20B7`.
    public static let hash = Font.system(.caption2, design: .monospaced)
}
