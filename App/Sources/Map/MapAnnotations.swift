import MapLibre
import MeshDesign
import SwiftUI
import UIKit

final class PinAnnotation: MLNPointAnnotation {
    var pin: MapPin

    init(pin: MapPin) {
        self.pin = pin
        super.init()
        coordinate = pin.coordinate
        title = pin.title
    }

    required init?(coder: NSCoder) { nil }
}

final class DotAnnotation: MLNPointAnnotation {
    let dot: MapDot

    init(dot: MapDot) {
        self.dot = dot
        super.init()
        coordinate = dot.coordinate
    }

    required init?(coder: NSCoder) { nil }
}

final class LineAnnotation: MLNPolyline {
    var line: MapLine?
}

/// Avatar-style marker with the node's name underneath.
final class PinAnnotationView: MLNAnnotationView {
    private let imageView = UIImageView()

    override init(annotation: (any MLNAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        addSubview(imageView)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { nil }

    /// Rendered badges, so pins that leave and rejoin clusters don't re-render.
    private static var imageCache: [String: UIImage] = [:]

    @MainActor
    func configure(pin: MapPin, selected: Bool) {
        let key = "\(pin.title)|\(pin.kind)|\(pin.isStale)|\(pin.isRadio)|\(pin.isInternet)|\(selected)"
        let image: UIImage
        if let cached = Self.imageCache[key] {
            image = cached
        } else {
            let renderer = ImageRenderer(content: PinBadge(pin: pin, selected: selected))
            renderer.scale = UIScreen.main.scale
            guard let rendered = renderer.uiImage else { return }
            if Self.imageCache.count > 1_000 { Self.imageCache.removeAll() }
            Self.imageCache[key] = rendered
            image = rendered
        }
        imageView.image = image
        imageView.frame = CGRect(origin: .zero, size: image.size)
        frame.size = image.size
        // Anchor the avatar's centre, not the label, on the coordinate.
        centerOffset = CGVector(dx: 0, dy: image.size.height / 2 - PinBadge.avatarSize(selected: selected) / 2 - 2)
        accessibilityLabel = pin.title
        layer.zPosition = selected ? 2 : (pin.isRadio ? 1 : 0)
    }
}

private struct PinBadge: View {
    var pin: MapPin
    var selected: Bool

    static func avatarSize(selected: Bool) -> CGFloat { selected ? 40 : 30 }

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                if pin.isRadio {
                    Circle().fill(MCColor.accentFill)
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: Self.avatarSize(selected: selected) * 0.42, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    AvatarView(name: pin.title, kind: pin.kind, size: Self.avatarSize(selected: selected))
                }
            }
            .frame(width: Self.avatarSize(selected: selected), height: Self.avatarSize(selected: selected))
            .overlay(Circle().stroke(.white, lineWidth: selected ? 3 : 2))
            .overlay(alignment: .bottomTrailing) {
                if pin.isInternet {
                    Image(systemName: "globe")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(2)
                        .background(Color.gray, in: Circle())
                        .offset(x: 3, y: 3)
                }
            }
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            .opacity(pin.isStale || pin.isInternet ? 0.6 : 1)
            // Internet Map pins can be dense, so they show their name only when selected.
            if !pin.isInternet || selected {
                nameLabel
            }
        }
        .padding(2)
    }

    private var nameLabel: some View {
        Text(pin.title)
            .font(.system(size: 11, weight: selected ? .bold : .medium))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.white.opacity(0.85), in: Capsule())
            .foregroundStyle(.black)
            .frame(maxWidth: 120)
    }
}
