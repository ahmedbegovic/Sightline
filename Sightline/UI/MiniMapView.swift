import SwiftUI
import MapKit
import CoreLocation

// MARK: - MiniMapView

/// Circular mini-map: collapsed is a non-interactive heading-up disc following the user; expanded is a north-up interactive card.
struct MiniMapView: View {

    private let poseManager: PoseManager
    @ObservedObject private var router: RouteManager
    private let places: [Place]
    @Binding private var selected: Place?
    @Binding private var isExpanded: Bool

    @State private var collapsedCamera: MapCameraPosition = .automatic
    @State private var expandedCamera: MapCameraPosition = .automatic
    /// Throttle bookkeeping for collapsed-mode camera follows.
    @State private var lastPushedHeading: Double?
    @State private var lastPushedCoordinate: CLLocationCoordinate2D?
    /// Throttled copy of the pose — the map content must not re-diff at 30 Hz.
    @State private var mapPose = DevicePose()
    /// Unbounded accumulation: assigning the normalized heading would spin the puck the long way around 360 -> 0.
    @State private var coneDegrees: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(poseManager: PoseManager, places: [Place], router: RouteManager,
         selected: Binding<Place?>, isExpanded: Binding<Bool>) {
        self.poseManager = poseManager
        self.places = places
        self.router = router
        self._selected = selected
        self._isExpanded = isExpanded
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // A cross-fade, not a morph: the two states are separate Map instances, so matchedGeometryEffect
            // could only snap between them at the cost of a frame.
            if isExpanded {
                expandedOverlay
                    .transition(.asymmetric(
                        insertion: reduceMotion ? .opacity
                            : .scale(scale: 0.96).combined(with: .opacity),
                        removal: .opacity))
            } else {
                collapsedDisc
                    .transition(.asymmetric(
                        insertion: reduceMotion ? .opacity
                            : .scale(scale: 0.96).combined(with: .opacity),
                        removal: reduceMotion ? .opacity
                            : .scale(scale: 0.92).combined(with: .opacity)))
            }
        }
        // A hard cut between two Map instances reads as a glitch, so Reduce Motion still cross-fades.
        .animation(Theme.Motion.gatedFade(Theme.Motion.gentle, reduceMotion: reduceMotion),
                   value: isExpanded)
        .onReceive(poseManager.$pose) { newPose in
            followPoseIfNeeded(newPose)
        }
        .onChange(of: isExpanded) { _, nowExpanded in
            if nowExpanded {
                // North-up, centered on the user when the big map opens.
                recenterExpandedCamera(animated: false)
            } else {
                // Resume following immediately on the next pose tick.
                lastPushedHeading = nil
                lastPushedCoordinate = nil
            }
        }
    }

    // MARK: Shared map content

    @MapContentBuilder
    private var routeLine: some MapContent {
        if let route = router.route, route.points.count > 1 {
            MapPolyline(coordinates: route.points)
                .stroke(Theme.accent,
                        style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
        }
    }

    @MapContentBuilder
    private func userAnnotation(coneRotationDegrees: Double) -> some MapContent {
        if let user = mapPose.coordinate {
            Annotation("", coordinate: user) {
                UserPuckView(coneRotationDegrees: coneRotationDegrees)
            }
            .annotationTitles(.hidden)
        }
    }

    // MARK: Collapsed disc

    private var collapsedDisc: some View {
        // A Button, not a tap gesture, so the disc acknowledges the press; the inner map already ignores hits.
        Button {
            Haptics.light()
            recenterExpandedCamera(animated: false)
            isExpanded = true
        } label: {
            ZStack(alignment: .topTrailing) {
                collapsedMap
                    .frame(width: 124, height: 124)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(Theme.glassStroke, lineWidth: 2))
                    .shadow(color: Theme.Elevation.medium.color,
                            radius: Theme.Elevation.medium.radius,
                            y: Theme.Elevation.medium.y)
                expandBadge
                    .offset(x: -10, y: 10)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(DiscPressStyle())
        .accessibilityLabel("Mini-map. Double tap to expand.")
    }

    private var collapsedMap: some View {
        Map(position: $collapsedCamera, interactionModes: []) {
            routeLine
            ForEach(places.filter(\.isLocated)) { place in
                Annotation("", coordinate: place.coordinate) {
                    CollapsedPlaceDot(place: place, isSelected: place.id == selected?.id)
                }
                .annotationTitles(.hidden)
            }
            // Camera heading == pose heading while collapsed, so the cone points screen-up: rotation 0.
            userAnnotation(coneRotationDegrees: 0)
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll, showsTraffic: false))
        .allowsHitTesting(false)
    }

    private var expandBadge: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Theme.textPrimary)
            .frame(width: 20, height: 20)
            .glassCircle(elevation: .low)
    }

    // MARK: Expanded overlay

    private var expandedOverlay: some View {
        ZStack {
            // Its own transition: riding the card's scale made the scrim pop in.
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { collapse() }
                .transition(.opacity)
            expandedCard
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var expandedCard: some View {
        expandedMap
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sheet, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.sheet, style: .continuous)
                    .strokeBorder(Theme.glassStroke, lineWidth: 1)
            )
            .overlay(alignment: .top) { expandedTopRow }
            .overlay(alignment: .bottomTrailing) { recenterButton }
            .overlay(alignment: .bottom) { routeStatusPill }
            .shadow(color: Theme.Elevation.high.color,
                    radius: Theme.Elevation.high.radius,
                    y: Theme.Elevation.high.y)
            .padding(10)
    }

    private var expandedMap: some View {
        // Pan/zoom only: the heading cone assumes north-up, so map rotation would point it the wrong way.
        Map(position: $expandedCamera, interactionModes: [.pan, .zoom]) {
            routeLine
            ForEach(places.filter(\.isLocated)) { place in
                Annotation("", coordinate: place.coordinate, anchor: .bottom) {
                    ExpandedPlaceMarker(place: place,
                                        isSelected: place.id == selected?.id) {
                        Haptics.light()
                        selected = place
                        withAnimation(Theme.Motion.gentle) {
                            isExpanded = false
                        }
                    }
                }
                .annotationTitles(.hidden)
            }
            // Expanded map is north-up, so the cone carries the live heading.
            userAnnotation(coneRotationDegrees: coneDegrees)
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll, showsTraffic: false))
    }

    private var expandedTopRow: some View {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: "map")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text("Around you")
                    .font(Theme.Typography.chipLabel)
                    .foregroundStyle(Theme.textPrimary)
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
            .hudPillChrome()

            Spacer()

            Button {
                collapse()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 34, height: 34)
                    .glassCircle(elevation: .low)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close map")
        }
        .padding(12)
    }

    private var recenterButton: some View {
        Button {
            Haptics.light()
            recenterExpandedCamera(animated: true)
        } label: {
            Image(systemName: "location.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 40, height: 40)
                .glassCircle(elevation: .low)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Recenter on my location")
        .padding(.trailing, 12)
        .padding(.bottom, router.route != nil ? 62 : 12)
        // The route pill sliding in used to snap this button up a row.
        .animation(Theme.Motion.standard, value: router.route != nil)
    }

    @ViewBuilder
    private var routeStatusPill: some View {
        if let route = router.route {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "figure.walk")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.accent)
                Text(route.destination.name)
                    .font(Theme.Typography.chipLabel)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(Format.distance(route.totalDistance))
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.textSecondary)
                Text("·")
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.textTertiary)
                Text(Format.duration(route.expectedTravelTime))
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .hudPillChrome(tone: .info)
            .padding(.horizontal, Theme.Space.l)
            .padding(.bottom, Theme.Space.m)
        }
    }

    // MARK: Camera plumbing

    /// One throttle for both the content snapshot and the follow camera: >2 degrees heading or >5 m movement.
    private func followPoseIfNeeded(_ pose: DevicePose) {
        guard let coordinate = pose.coordinate else { return }
        let headingMoved = lastPushedHeading.map {
            abs(Angles.shortestDelta(from: $0, to: pose.headingDegrees)) > 2
        } ?? true
        let locationMoved = lastPushedCoordinate.map {
            ARProjector.distanceMeters(from: $0, to: coordinate) > 5
        } ?? true
        guard headingMoved || locationMoved else { return }

        let isFirstFix = lastPushedCoordinate == nil
        lastPushedHeading = pose.headingDegrees
        lastPushedCoordinate = coordinate
        mapPose = pose
        coneDegrees += Angles.shortestDelta(from: coneDegrees, to: pose.headingDegrees)

        guard !isExpanded else { return }
        let position = MapCameraPosition.camera(
            MapCamera(centerCoordinate: coordinate, distance: 900,
                      heading: pose.headingDegrees, pitch: 0))
        if isFirstFix {
            collapsedCamera = position
        } else {
            withAnimation(.linear(duration: 0.25)) { collapsedCamera = position }
        }
    }

    private func recenterExpandedCamera(animated: Bool) {
        guard let coordinate = poseManager.pose.coordinate else { return }
        let position = MapCameraPosition.camera(
            MapCamera(centerCoordinate: coordinate, distance: 1600, heading: 0, pitch: 0))
        if animated {
            withAnimation(Theme.Motion.standard) {
                expandedCamera = position
            }
        } else {
            expandedCamera = position
        }
    }

    private func collapse() {
        Haptics.light()
        withAnimation(Theme.Motion.gentle) {
            isExpanded = false
        }
    }
}

// MARK: - Press feedback

private struct DiscPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(Theme.Motion.snap, value: configuration.isPressed)
    }
}

// MARK: - User puck (dot + heading cone)

private struct UserPuckView: View {
    var coneRotationDegrees: Double

    var body: some View {
        ZStack {
            HeadingConeShape()
                .fill(Theme.accent.opacity(0.35))
                .frame(width: 36, height: 36)
                .rotationEffect(.degrees(coneRotationDegrees))
                // Matches the collapsed camera push at 0.25 s; this is a map annotation, not an AR bubble.
                .animation(.linear(duration: 0.25), value: coneRotationDegrees)
            Circle()
                .fill(Theme.accent)
                .frame(width: 12, height: 12)
                .overlay(Circle().stroke(.white, lineWidth: 2))
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
        }
        .frame(width: 36, height: 36)
    }
}

/// Sector pointing screen-up (toward -90 degrees) from the center of its rect.
private struct HeadingConeShape: Shape {
    var spanDegrees: Double = 55

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let half = Angle(degrees: spanDegrees / 2)
        path.move(to: center)
        path.addArc(center: center, radius: radius,
                    startAngle: .degrees(-90) - half,
                    endAngle: .degrees(-90) + half,
                    clockwise: false)
        path.closeSubpath()
        return path
    }
}

// MARK: - Place markers

private struct CollapsedPlaceDot: View {
    let place: Place
    let isSelected: Bool

    var body: some View {
        Circle()
            .fill(place.category.tint)
            .frame(width: isSelected ? 14 : 10, height: isSelected ? 14 : 10)
            .overlay(Circle().stroke(.white, lineWidth: 1.5))
            .overlay {
                if isSelected {
                    Circle()
                        .stroke(Theme.accent, lineWidth: 2)
                        .frame(width: 20, height: 20)
                }
            }
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            .animation(Theme.Motion.snap, value: isSelected)
    }
}

private struct ExpandedPlaceMarker: View {
    let place: Place
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        VStack(spacing: 1.5) {
            CategoryBadge(category: place.category, size: 26, silhouette: .circle)
                .overlay(Circle().strokeBorder(.white.opacity(0.95), lineWidth: 1.5))
                .overlay {
                    if isSelected {
                        Circle()
                            .stroke(Theme.accent, lineWidth: 2)
                            .frame(width: 33, height: 33)
                    }
                }
            Circle()
                .fill(.white)
                .frame(width: 4.5, height: 4.5)
        }
        .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
        .scaleEffect(isSelected ? 1.15 : 1, anchor: .bottom)
        .animation(Theme.Motion.snap, value: isSelected)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .accessibilityLabel(place.name)
        .accessibilityAddTraits(.isButton)
    }
}
