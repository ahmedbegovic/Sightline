import SwiftUI

/// Hero scan control. The mark is a code-drawn signal fan — a beacon, not a camera reticle.
/// No view is ever mounted or unmounted by a state change: pressing Scan only changes values.
struct ScanButton: View {
    private let state: ScanState
    private let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false
    @State private var successTick = 0
    @State private var flash = false

    init(state: ScanState, action: @escaping () -> Void) {
        self.state = state
        self.action = action
    }

    private var isScanning: Bool { state == .scanning }
    private var breath: Double { breathe ? 1 : 0 }
    /// A paused TimelineView still emits one entry, so the rings must fade out rather than freeze mid-expansion.
    private var activeFactor: Double { isScanning && !reduceMotion ? 1 : 0 }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                beacon
                Text("SCAN")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .tracking(1.6)
                    .foregroundStyle(Theme.textSecondary)
                    .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(ScanPressStyle(reduceMotion: reduceMotion))
        .accessibilityLabel("Scan surroundings")
        .accessibilityHint("Finds places in the direction you're facing")
        .accessibilityValue(isScanning ? "Scanning" : "")
        .accessibilityAddTraits(isScanning ? [.isButton, .updatesFrequently] : .isButton)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
        .onChange(of: state) { _, new in
            if new == .found { successTick += 1 }
        }
        // .task(id:) so a state flip inside the flash window cancels and restarts it instead of stacking.
        .task(id: successTick) {
            guard successTick > 0 else { return }
            withAnimation(Theme.Motion.gated(.spring(response: 0.24, dampingFraction: 0.60),
                                             reduceMotion: reduceMotion)) { flash = true }
            try? await Task.sleep(nanoseconds: 260_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.34)) { flash = false }
        }
    }

    // MARK: - Layers

    private var beacon: some View {
        ZStack {
            halo
            pingRings
            Color.clear
                .frame(width: 80, height: 80)
                .glassCircle(elevation: .medium)
            Circle()
                .strokeBorder(Theme.accent.opacity(isScanning ? 0.80 : 0), lineWidth: 2)
                .frame(width: 80, height: 80)
                .animation(Theme.Motion.standard, value: isScanning)
            core
            ScanMark(idleBreath: breath, isScanning: isScanning, reduceMotion: reduceMotion)
            // Reduce Motion keeps the confirmation but drops the expansion.
            Circle()
                .strokeBorder(Theme.positive, lineWidth: 2.5)
                .frame(width: 80, height: 80)
                .scaleEffect(reduceMotion ? 1 : (flash ? 1.16 : 0.94))
                .opacity(flash ? 0.95 : 0)
        }
        .frame(width: 92, height: 92)
    }

    private var halo: some View {
        Circle()
            .fill(RadialGradient(stops: [
                .init(color: Theme.accent.opacity(0.30), location: 0.42),
                .init(color: Theme.accent.opacity(0.10), location: 0.72),
                .init(color: .clear, location: 1.0),
            ], center: .center, startRadius: 0, endRadius: 46))
            .frame(width: 92, height: 92)
            .scaleEffect(1 + 0.06 * breath)
            .opacity(0.60 + 0.40 * breath)
            .allowsHitTesting(false)
    }

    /// The schedule pauses; the views never unmount, so a press causes no identity churn.
    private var pingRings: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isScanning)) { timeline in
            let phase = ScanButton.cyclePhase(timeline.date)
            ZStack {
                ForEach(0..<3, id: \.self) { index in
                    let p = (phase + Double(index) / 3).truncatingRemainder(dividingBy: 1)
                    Circle()
                        .strokeBorder(Theme.accent, lineWidth: 1.5)
                        .frame(width: 80, height: 80)
                        .scaleEffect(1 + 0.85 * p)
                        .opacity(pow(1 - p, 1.4) * 0.55 * activeFactor)
                }
            }
        }
        .animation(Theme.Motion.fade, value: activeFactor)
        .allowsHitTesting(false)
    }

    private var core: some View {
        Circle()
            .fill(Theme.accentGradient)
            .frame(width: 64, height: 64)
            .overlay {
                Circle().fill(RadialGradient(colors: [.white.opacity(0.28), .clear],
                                             center: UnitPoint(x: 0.32, y: 0.24),
                                             startRadius: 2, endRadius: 34))
            }
            .shadow(color: Theme.accent.opacity(0.42), radius: 12)
    }

    /// One 1.25 s cycle shared by the rings and the mark so they never drift apart.
    fileprivate static func cyclePhase(_ date: Date) -> Double {
        date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.25) / 1.25
    }
}

// MARK: - Mark

/// Signal fan: an origin dot with three arcs spanning the app's real 64 degree scan cone.
private struct ScanMark: View {
    let idleBreath: Double
    let isScanning: Bool
    let reduceMotion: Bool

    private static let radii: [CGFloat] = [8.5, 13.5, 18.5]
    private static let idleOpacities: [Double] = [0.95, 0.62, 0.34]

    var body: some View {
        ZStack {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isScanning)) { timeline in
                // head sweeps -1…3 once per cycle; both ends land on factor 0, so the loop has no seam.
                let head = ScanButton.cyclePhase(timeline.date) * 4.0 - 1.0
                ZStack {
                    ForEach(0..<3, id: \.self) { index in
                        ScanArc(radius: ScanMark.radii[index])
                            .stroke(Color.white,
                                    style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                            .opacity(opacity(index, head: head))
                    }
                }
            }
            .animation(Theme.Motion.fade, value: isScanning)

            Circle()
                .fill(Color.white)
                .frame(width: 5, height: 5)
                .position(x: 15, y: 22)
        }
        .frame(width: 30, height: 30)
        .allowsHitTesting(false)
    }

    private func opacity(_ index: Int, head: Double) -> Double {
        guard isScanning, !reduceMotion else {
            return ScanMark.idleOpacities[index] * (0.85 + 0.15 * idleBreath)
        }
        return 0.25 + 0.75 * max(0, 1 - abs(Double(index) - head))
    }
}

/// Arc centered on the mark's origin dot, spanning ±32° around straight up (PlacesService.scanConeDegrees).
private struct ScanArc: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let origin = CGPoint(x: rect.midX, y: rect.maxY - 8)
        path.addArc(center: origin, radius: radius,
                    startAngle: .degrees(-90 - 32), endAngle: .degrees(-90 + 32),
                    clockwise: false)
        return path
    }
}

// MARK: - Press style

private struct ScanPressStyle: ButtonStyle {
    var reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.90 : 1.0)
            .animation(reduceMotion ? nil : Theme.Motion.snap, value: configuration.isPressed)
            // Press-down feedback, so a tap that fails AppState's location guard is still acknowledged.
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { Haptics.light() }
            }
    }
}
