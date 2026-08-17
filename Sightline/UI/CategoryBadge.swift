import SwiftUI

/// One icon-badge recipe for every surface that shows a category. Size and silhouette are the only knobs.
struct CategoryBadge: View {
    enum Silhouette { case circle, rounded }

    let category: PlaceCategory
    var size: CGFloat = 30
    var silhouette: Silhouette = .circle

    private var fill: LinearGradient {
        LinearGradient(colors: [category.tint, category.tint.opacity(0.68)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var glyph: some View {
        Image(systemName: category.symbolName)
            .font(.system(size: size * 0.43, weight: .semibold))
            .foregroundStyle(.white)
    }

    var body: some View {
        ZStack {
            // Two explicit branches: a @ViewBuilder cannot return `some Shape`.
            if silhouette == .circle {
                Circle().fill(fill)
            } else {
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(fill)
            }
            glyph
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
