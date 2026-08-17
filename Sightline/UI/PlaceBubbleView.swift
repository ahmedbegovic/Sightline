import SwiftUI
import CoreLocation

/// Floating glass chip for one place (icon, name, rating, distance) with a pointer notch anchoring it to the world.
struct PlaceBubbleView: View {

    private let place: Place
    private let distance: CLLocationDistance?
    private let isSelected: Bool

    init(place: Place, distance: CLLocationDistance?, isSelected: Bool) {
        self.place = place
        self.distance = distance
        self.isSelected = isSelected
    }

    var body: some View {
        VStack(spacing: 0) {
            chip
            notch
        }
        .frame(maxWidth: place.isFarLandmark ? 190 : 168)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = [place.name]
        if place.rating > 0 { parts.append(String(format: "%.1f stars", place.rating)) }
        if let distance { parts.append(Format.bubbleDistance(distance)) }
        return parts.joined(separator: ", ")
    }

    // MARK: - Chip

    private var chip: some View {
        HStack(spacing: Theme.Space.s) {
            CategoryBadge(category: place.category, size: 30, silhouette: .circle)
            labels
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .bubbleGlass()
        .overlay {
            if place.isFarLandmark {
                RoundedRectangle(cornerRadius: Theme.Radius.pill, style: .continuous)
                    .strokeBorder(Theme.landmark.opacity(0.45), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        // Width, not presence: an if-branch would re-insert the overlay and the stroke would pop in.
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.pill, style: .continuous)
                .strokeBorder(Theme.accentGradient, lineWidth: isSelected ? 1.8 : 0)
                .allowsHitTesting(false)
        }
        .animation(Theme.Motion.snap, value: isSelected)
        .modifier(SelectionGlow(active: isSelected))
    }

    private var notch: some View {
        ZStack {
            BubbleNotchShape().fill(.ultraThinMaterial)
            BubbleNotchEdgeShape().stroke(Theme.hairline, lineWidth: 1)
        }
        .frame(width: 10, height: 7)
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                if place.isFarLandmark {
                    Image(systemName: "sparkles")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.landmark)
                }
                Text(place.name)
                    .font(Theme.Typography.cardBodyStrong)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            HStack(spacing: 3) {
                if place.rating > 0 {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.star)
                    Text(String(format: "%.1f", place.rating))
                        .foregroundStyle(Theme.textSecondary)
                }
                if let distance {
                    Text("·")
                        .foregroundStyle(Theme.textTertiary)
                    // Gold means "far landmark"; accent is reserved for "selected".
                    Text(Format.bubbleDistance(distance))
                        .foregroundStyle(place.isFarLandmark ? Theme.landmark : Theme.textSecondary)
                }
            }
            .font(Theme.Typography.micro)
            // .position centers the chip, so a proportional digit changing width twitches both edges every frame.
            .monospacedDigit()
        }
    }
}

/// Applied conditionally: an always-attached shadow rasterizes a blur on every bubble every frame.
private struct SelectionGlow: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content.shadow(color: Theme.accent.opacity(0.5), radius: 10)
        } else {
            content
        }
    }
}

/// Small downward-pointing triangle drawn under the chip.
fileprivate struct BubbleNotchShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// The notch's two slanted edges only — the top edge would draw a seam across the chip.
fileprivate struct BubbleNotchEdgeShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}
