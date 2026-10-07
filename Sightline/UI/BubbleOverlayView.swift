import SwiftUI
import CoreLocation

/// AR layer re-projecting places each pose update (~30Hz): bubbles, leader lines, and edge indicators for off-FOV places.
struct BubbleOverlayView: View {

    private let places: [Place]
    @ObservedObject private var poseManager: PoseManager
    @Binding private var selected: Place?

    /// Per-view render memory. A reference type so the per-frame layout can update it without a state write during body evaluation.
    private final class LayoutMemory {
        var onScreenIDs: Set<String> = []
    }

    @State private var memory = LayoutMemory()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(places: [Place], poseManager: PoseManager, selected: Binding<Place?>) {
        self.places = places
        self.poseManager = poseManager
        self._selected = selected
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let pose = poseManager.pose
            let layout = Self.computeLayout(places: places, pose: pose, size: size, memory: memory)

            ZStack {
                ZStack {
                    leaderLines(for: layout.bubbles, pose: pose, size: size)
                        .zIndex(-1_000_000_000)

                    ForEach(layout.bubbles) { item in
                        PlaceBubbleView(place: item.place,
                                        distance: item.placement.distance,
                                        isSelected: selected?.id == item.place.id)
                            .onTapGesture {
                                Haptics.light()
                                selected = item.place
                            }
                            .scaleEffect(item.placement.scale, anchor: .bottom)
                            // Center 27 pt above the projected anchor so the notch tip (bottom edge, half-height 27) lands exactly on the spot it claims.
                            .position(x: item.placement.point.x,
                                      y: item.placement.point.y - item.lift - 27)
                            .zIndex(-(item.placement.distance ?? 0))
                            .transition(.asymmetric(
                                insertion: reduceMotion
                                    ? AnyTransition.opacity.animation(.easeOut(duration: 0.2))
                                    : AnyTransition.scale(scale: 0.5).combined(with: .opacity)
                                        .animation(.spring(response: 0.5, dampingFraction: 0.75)
                                            .delay(Double(item.index) * 0.05)),
                                removal: .opacity.animation(.easeOut(duration: 0.2))))
                            // The declutter row is discrete; without this the 58 pt bump reads as a jump rather than a bubble making room.
                            .animation(.easeOut(duration: 0.18), value: item.lift)
                    }
                }

                // The animation belongs to this container only; hoisting it onto the ZStack would capture the bubbles.
                edgeIndicators(layout.edges, size: size)
                    .animation(Theme.Motion.standard, value: layout.edgesSignature)
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Leader lines

    /// Single Canvas behind all bubbles; gradient line from each nearby search bubble to its ground anchor.
    /// Scan sightings skip it: they already sit on the thing the camera saw, and the ground model assumes street level.
    private func leaderLines(for items: [OnScreenItem],
                             pose: DevicePose, size: CGSize) -> some View {
        Canvas { context, _ in
            for item in items where item.place.sighting == nil && (item.placement.distance ?? .infinity) <= 300 {
                guard let ground = ARProjector.groundPoint(for: item.place.coordinate,
                                                           pose: pose,
                                                           screenSize: size)
                else { continue }
                // The notch tip sits on the projected anchor minus the declutter lift, so the line's length is exactly the lift (plus any clamp divergence).
                let top = CGPoint(x: item.placement.point.x,
                                  y: item.placement.point.y - item.lift)
                guard ground.y > top.y + 4 else { continue }
                var line = Path()
                line.move(to: top)
                line.addLine(to: ground)
                context.stroke(
                    line,
                    with: .linearGradient(
                        Gradient(colors: [Theme.accent.opacity(0.7),
                                          Theme.accent.opacity(0)]),
                        startPoint: top, endPoint: ground),
                    lineWidth: 1.5)
                // Anchor dot: the line alone fades to nothing and never reads as touching the ground.
                let r: CGFloat = 2.5
                context.fill(Path(ellipseIn: CGRect(x: ground.x - r, y: ground.y - r,
                                                    width: r * 2, height: r * 2)),
                             with: .color(Theme.accent.opacity(0.5)))
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Edge indicators

    private func edgeIndicators(_ items: [EdgeItem], size: CGSize) -> some View {
        ZStack {
            ForEach(items) { item in
                EdgeIndicatorView(item: item) {
                    Haptics.light()
                    selected = item.place
                }
                .transition(.scale(scale: 0.7).combined(with: .opacity))
                // Constant x, and y is slot * 64 — nothing here is a projected position.
                .position(x: item.isLeft ? 32 : size.width - 32,
                          y: size.height * 0.34 + CGFloat(item.slot) * 64)
            }
        }
    }

    /// One indicator with its own breathe phase, offset per slot so the column does not pulse in lockstep.
    private struct EdgeIndicatorView: View {
        let item: EdgeItem
        let onTap: () -> Void

        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var breathing = false

        var body: some View {
            VStack(spacing: 3) {
                HStack(spacing: 1.5) {
                    if item.isLeft {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Image(systemName: item.place.category.symbolName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(item.place.category.tint)
                    if !item.isLeft {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .frame(width: 44, height: 44)
                .glassCircle(elevation: .low)

                if let distance = item.distance {
                    Text(Format.bubbleDistance(distance))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .monospacedDigit()
                }
            }
            .opacity(breathing ? 1.0 : 0.85)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .accessibilityLabel(item.place.name)
            .accessibilityAddTraits(.isButton)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.9)
                    .repeatForever(autoreverses: true)
                    .delay(Double(item.slot) * 0.22)) {
                    breathing = true
                }
            }
        }
    }

    // MARK: - Layout model

    private struct OnScreenItem: Identifiable {
        let place: Place
        let placement: BubblePlacement
        /// Upward y-offset applied by the declutter pass.
        let lift: CGFloat
        /// Position in the distance-sorted list, used for the stagger delay.
        let index: Int
        var id: String { place.id }
    }

    private struct EdgeItem: Identifiable {
        let place: Place
        let distance: CLLocationDistance?
        let isLeft: Bool
        let slot: Int
        var id: String { place.id }
    }

    private struct OverlayLayout {
        var bubbles: [OnScreenItem] = []
        var edges: [EdgeItem] = []
        /// Discrete signature (ids + slots + side). Never includes distance or any projected value.
        var edgesSignature: Int = 0
    }

    /// Most bubbles drawn at once; the rest of the result set still shows on the mini-map.
    private static let maxBubbles = 5

    /// 5 m buckets: sub-meter distance noise must not reshuffle the ranking, which drives both the maxBubbles cut and the declutter rows.
    private static func rankBucket(_ distance: CLLocationDistance?) -> Int {
        distance.map { Int(($0 / 5).rounded()) } ?? 0
    }

    /// Bubble ranking: what the scan saw first, then nearest first.
    private static func ranksBefore(_ a: (place: Place, placement: BubblePlacement),
                                    _ b: (place: Place, placement: BubblePlacement)) -> Bool {
        if (a.place.sighting != nil) != (b.place.sighting != nil) {
            return a.place.sighting != nil
        }
        let (bucketA, bucketB) = (rankBucket(a.placement.distance), rankBucket(b.placement.distance))
        return bucketA != bucketB ? bucketA < bucketB : a.place.id < b.place.id
    }

    /// Projects every place and runs the greedy row declutter; deterministic and allocation-light (runs per frame).
    private static func computeLayout(places: [Place],
                                      pose: DevicePose,
                                      size: CGSize,
                                      memory: LayoutMemory) -> OverlayLayout {
        var onScreen: [(place: Place, placement: BubblePlacement)] = []
        var offScreen: [(place: Place, placement: BubblePlacement)] = []
        var nextOnScreen: Set<String> = []
        onScreen.reserveCapacity(places.count)

        for place in places {
            // A scan sighting sits where the camera saw it; a search result where the map puts it.
            let projected: BubblePlacement?
            if let sighting = place.sighting(at: pose.location) {
                projected = ARProjector.bubblePlacement(for: sighting,
                                                        distance: place.distance(from: pose.location),
                                                        pose: pose, screenSize: size)
            } else {
                projected = ARProjector.bubblePlacement(for: place.coordinate, pose: pose, screenSize: size)
            }
            guard var placement = projected else { continue }
            let onScreenNow = ARProjector.isOnScreen(edgeAngle: placement.edgeAngle,
                                                     wasOnScreen: memory.onScreenIDs.contains(place.id))
            if onScreenNow {
                nextOnScreen.insert(place.id)
                // Nudge only by the bubble's own half-width so a calibrated FOV keeps its real horizontal spread.
                let margin = 78 * placement.scale
                placement.point.x = min(max(placement.point.x, margin), size.width - margin)
                onScreen.append((place, placement))
            } else {
                offScreen.append((place, placement))
            }
        }

        // Rank the whole FOV set, then keep only the best few — a wall of bubbles reads as noise.
        onScreen.sort(by: ranksBefore)
        if onScreen.count > maxBubbles { onScreen.removeSubrange(maxBubbles...) }

        var layout = OverlayLayout()
        layout.bubbles.reserveCapacity(onScreen.count)

        // Greedy declutter: nearest first, bump up a row (max 3 rows, 58pt) on x-interval overlap.
        var intervals: [(row: Int, lo: CGFloat, hi: CGFloat)] = []
        intervals.reserveCapacity(onScreen.count)

        for (index, entry) in onScreen.enumerated() {
            let half: CGFloat = 78 * entry.placement.scale
            let lo = entry.placement.point.x - half
            let hi = entry.placement.point.x + half
            var row = 0
            while row < 2,
                  intervals.contains(where: { $0.row == row && $0.hi > lo && $0.lo < hi }) {
                row += 1
            }
            intervals.append((row, lo, hi))
            layout.bubbles.append(OnScreenItem(place: entry.place,
                                               placement: entry.placement,
                                               lift: CGFloat(row) * 58 * entry.placement.scale,
                                               index: index))
        }

        func edgeItems(_ entries: [(place: Place, placement: BubblePlacement)],
                       isLeft: Bool) -> [EdgeItem] {
            return entries.sorted(by: ranksBefore).prefix(4).enumerated().map { slot, entry in
                EdgeItem(place: entry.place,
                         distance: entry.placement.distance,
                         isLeft: isLeft,
                         slot: slot)
            }
        }

        layout.edges =
            edgeItems(offScreen.filter { $0.placement.edgeAngle < 0 }, isLeft: true) +
            edgeItems(offScreen.filter { $0.placement.edgeAngle >= 0 }, isLeft: false)
        // Precomputed here so the body never allocates an id array 30 times a second just to key an animation.
        var hasher = Hasher()
        for edge in layout.edges {
            hasher.combine(edge.place.id)
            hasher.combine(edge.slot)
            hasher.combine(edge.isLeft)
        }
        layout.edgesSignature = hasher.finalize()
        memory.onScreenIDs = nextOnScreen
        return layout
    }
}
