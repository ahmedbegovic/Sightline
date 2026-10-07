import SwiftUI

extension View {
    /// Glass on any insettable shape. The shadow belongs to the shape, not the composite — attaching it to the
    /// composite forces an offscreen pass over the content (text included) on every frame the content changes.
    func glassSurface<S: InsettableShape>(_ shape: S,
                                          elevation: Theme.Elevation = .medium,
                                          strokeWidth: CGFloat = 1) -> some View {
        background {
            shape.fill(.ultraThinMaterial)
                .overlay(shape.strokeBorder(Theme.glassStroke, lineWidth: strokeWidth))
                .shadow(color: elevation.color, radius: elevation.radius, y: elevation.y)
        }
    }

    /// Source-compatible with every existing call site.
    func glassCard(cornerRadius: CGFloat = Theme.Radius.card,
                   elevation: Theme.Elevation = .medium) -> some View {
        glassSurface(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
                     elevation: elevation)
    }

    func glassCapsule(elevation: Theme.Elevation = .low) -> some View {
        glassSurface(Capsule(style: .continuous), elevation: elevation)
    }

    func glassCircle(elevation: Theme.Elevation = .low) -> some View {
        glassSurface(Circle(), elevation: elevation)
    }

    /// Bubble chips only: an extra dark floor under the material so a chip survives a bright sky.
    func bubbleGlass(cornerRadius: CGFloat = Theme.Radius.pill) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background {
            shape.fill(Theme.bubbleFloor)
                .background(shape.fill(.ultraThinMaterial))
                .overlay(shape.strokeBorder(Theme.glassStroke, lineWidth: 1))
                .shadow(color: Theme.Elevation.low.color,
                        radius: Theme.Elevation.low.radius, y: Theme.Elevation.low.y)
        }
    }
}
