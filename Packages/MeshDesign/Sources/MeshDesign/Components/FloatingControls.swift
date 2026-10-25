import SwiftUI

public extension View {
    /// Floating background for buttons over content: Liquid Glass on iOS 26+, material before that.
    @ViewBuilder
    func mcFloatingSurface<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        }
    }
}

/// Round floating button, e.g. the connection (antenna) and compose buttons.
public struct FloatingIconButton: View {
    private let systemImage: String
    private let accessibilityLabel: String
    private let tint: Color
    private let action: @MainActor () -> Void

    public init(
        systemImage: String,
        accessibilityLabel: String,
        tint: Color = .primary,
        action: @escaping @MainActor () -> Void
    ) {
        self.systemImage = systemImage
        self.accessibilityLabel = accessibilityLabel
        self.tint = tint
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3.weight(.medium))
                .foregroundStyle(tint)
                .frame(width: MCSize.control, height: MCSize.control)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .mcFloatingSurface(in: Circle())
        .accessibilityLabel(accessibilityLabel)
    }
}

/// One button in the map's floating control column.
public struct MapControl: Identifiable {
    public let id: String
    public let systemImage: String
    public let accessibilityLabel: String
    public let action: @MainActor () -> Void

    public init(systemImage: String, accessibilityLabel: String, action: @escaping @MainActor () -> Void) {
        self.id = accessibilityLabel
        self.systemImage = systemImage
        self.accessibilityLabel = accessibilityLabel
        self.action = action
    }

    /// The map's standard controls (PLAN.md §4.4): compass, locate me, fullscreen.
    public static func standard(
        onCompass: @escaping @MainActor () -> Void,
        onLocate: @escaping @MainActor () -> Void,
        onFullscreen: @escaping @MainActor () -> Void
    ) -> [MapControl] {
        [
            MapControl(systemImage: "location.north.line", accessibilityLabel: "Reset north", action: onCompass),
            MapControl(systemImage: "location", accessibilityLabel: "Show my location", action: onLocate),
            MapControl(systemImage: "arrow.up.left.and.arrow.down.right", accessibilityLabel: "Fullscreen", action: onFullscreen),
        ]
    }
}

/// Vertical column of map controls on a floating surface.
public struct FloatingMapControls: View {
    private let controls: [MapControl]

    public init(_ controls: [MapControl]) {
        self.controls = controls
    }

    public var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(controls.enumerated()), id: \.element.id) { index, control in
                Button(action: control.action) {
                    Image(systemName: control.systemImage)
                        .font(.body.weight(.medium))
                        .frame(width: MCSize.control, height: MCSize.control)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(control.accessibilityLabel)
                if index < controls.count - 1 {
                    Divider().frame(width: 28)
                }
            }
        }
        .mcFloatingSurface(in: RoundedRectangle(cornerRadius: MCRadius.control, style: .continuous))
    }
}
