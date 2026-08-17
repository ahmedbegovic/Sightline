import SwiftUI

/// Code-drawn busy ring. Replaces every ProgressView — the UIKit-backed indicator rasterizes on first use, on the main thread.
struct SpinnerRing: View {
    var size: CGFloat = 18
    var lineWidth: CGFloat = 2
    var tint: Color = Theme.textPrimary

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin = false

    var body: some View {
        Circle()
            .trim(from: 0.06, to: 0.94)
            .stroke(AngularGradient(colors: [tint.opacity(0.05), tint], center: .center),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .opacity(reduceMotion ? 0.6 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                    spin = true
                }
            }
            .accessibilityHidden(true)
    }
}
