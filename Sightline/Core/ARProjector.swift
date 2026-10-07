import Foundation
import CoreGraphics
import CoreLocation

// MARK: - Bubble placement

/// Where (and how) a place bubble should be drawn for the current device pose.
struct BubblePlacement {
    /// Bubble center; computed even off screen so overlays can clamp it for edge indicators.
    var point: CGPoint
    /// Bubble size multiplier — larger for near places, smaller for far ones.
    var scale: CGFloat
    /// Great-circle distance from the user to the target, in meters; nil for a sighting that could not be placed on the map.
    var distance: CLLocationDistance?
    /// Signed degrees from screen center to the target; negative = target is to the left.
    var edgeAngle: Double
}

// MARK: - Projector

/// Stateless geometry mapping GPS coordinates into screen space for the AR HUD.
enum ARProjector {

    /// Horizontal camera field of view, in degrees; the assumed value until the AR path calibrates it.
    private(set) static var horizontalFOV: Double = 64
    /// Vertical camera field of view, in degrees; the assumed value until the AR path calibrates it.
    private(set) static var verticalFOV: Double = 80

    /// AR path only, main thread, once per session: replace the assumed lens model with the real one. Ignores absurd values.
    static func calibrate(horizontalFOV h: Double, verticalFOV v: Double) {
        guard h.isFinite, v.isFinite, (20...120).contains(h), (20...120).contains(v) else { return }
        horizontalFOV = h
        verticalFOV = v
    }

    /// Initial great-circle bearing, degrees clockwise from true north in `0..<360`.
    static func bearing(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let lat1 = from.latitude * degToRad
        let lat2 = to.latitude * degToRad
        let dLon = (to.longitude - from.longitude) * degToRad
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let degrees = atan2(y, x) * radToDeg
        // fmod can return a negative remainder; fold into 0..<360.
        let normalized = degrees.truncatingRemainder(dividingBy: 360)
        return normalized < 0 ? normalized + 360 : normalized
    }

    /// Haversine distance in meters; allocation-free, safe to call per frame.
    static func distanceMeters(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> CLLocationDistance {
        let lat1 = from.latitude * degToRad
        let lat2 = to.latitude * degToRad
        let dLat = (to.latitude - from.latitude) * degToRad
        let dLon = (to.longitude - from.longitude) * degToRad
        let sinLat = sin(dLat / 2)
        let sinLon = sin(dLon / 2)
        let a = sinLat * sinLat + cos(lat1) * cos(lat2) * sinLon * sinLon
        let c = 2 * atan2(sqrt(a), sqrt(max(0, 1 - a)))
        return earthRadiusMeters * c
    }

    // MARK: - On-screen hysteresis

    /// A place enters the FOV set at this margin beyond half-FOV…
    static let onScreenEnterMargin: Double = 6
    /// …and only leaves past this one. Without the gap, a bubble at the edge flickers between chip and arrow on heading noise.
    static let onScreenExitMargin: Double = 12

    static func isOnScreen(edgeAngle: Double, wasOnScreen: Bool) -> Bool {
        abs(edgeAngle) <= horizontalFOV / 2 + (wasOnScreen ? onScreenExitMargin : onScreenEnterMargin)
    }

    /// Screen y of the horizon: tilting up moves it down; clamped to a usable band.
    private static func horizonY(pose: DevicePose, screenSize: CGSize) -> CGFloat {
        let fraction = clamp(0.5 + pose.pitchDegrees / verticalFOV, 0.08, 0.92)
        return CGFloat(fraction) * screenSize.height
    }

    /// Bubble placement for `coordinate`; `nil` only without a location fix — point is computed even outside the FOV.
    static func bubblePlacement(for coordinate: CLLocationCoordinate2D,
                                pose: DevicePose,
                                screenSize: CGSize) -> BubblePlacement? {
        guard let user = pose.coordinate else { return nil }

        let distance = distanceMeters(from: user, to: coordinate)
        let delta = Angles.shortestDelta(from: pose.headingDegrees,
                                         to: bearing(from: user, to: coordinate))
        let x = screenX(forDelta: delta, screenSize: screenSize)

        let scale = bubbleScale(distance: distance)

        // Perspective placement: bubbles converge on the horizon as 1/distance (same elevated viewpoint as the route ribbon), so a bubble floats where the place is instead of in a fixed band.
        let horizon = horizonY(pose: pose, screenSize: screenSize)
        let focalPx = Double(screenSize.height) / (2 * tan(verticalFOV / 2 * degToRad))
        let drop = CGFloat(min(focalPx * cameraHeightMeters / max(distance, 12),
                               Double(screenSize.height) * 0.30))
        // Far landmarks ride above the horizon — the bubble points at a structure's visible top, not its doormat.
        let farLift = CGFloat(clamp((distance - 1200) / 8000, 0, 1)) * screenSize.height * 0.06
        let y = clamp(horizon + drop - farLift,
                      screenSize.height * 0.12,
                      screenSize.height * 0.80)

        return BubblePlacement(point: CGPoint(x: x, y: y),
                               scale: scale,
                               distance: distance,
                               edgeAngle: delta)
    }

    /// Placement for something a scan saw: the bearing and elevation captured at scan time against the current pose.
    /// No distance, ground plane or camera height involved, so it holds from a rooftop or an observation deck.
    static func bubblePlacement(for sighting: Sighting,
                                distance: CLLocationDistance?,
                                pose: DevicePose,
                                screenSize: CGSize) -> BubblePlacement {
        let delta = Angles.shortestDelta(from: pose.headingDegrees, to: sighting.bearing)
        let x = screenX(forDelta: delta, screenSize: screenSize)
        let rise = (sighting.elevation - pose.pitchDegrees) / verticalFOV
        let y = clamp(screenSize.height * (0.5 - CGFloat(rise)),
                      screenSize.height * 0.12,
                      screenSize.height * 0.80)
        return BubblePlacement(point: CGPoint(x: x, y: y),
                               scale: distance.map(bubbleScale(distance:)) ?? 0.9,
                               distance: distance,
                               edgeAngle: delta)
    }

    /// Depth-true size: 1.2 (<= 25 m) eases down to 0.6 (>= 2500 m) on a sqrt curve, strictly monotonic in distance.
    static func bubbleScale(distance: CLLocationDistance) -> CGFloat {
        let t = clamp((distance - 25) / (2500 - 25), 0, 1)
        return CGFloat(1.2 + (0.6 - 1.2) * sqrt(t))
    }

    /// Ground-plane projection for route ribbons from a raised ~9 m viewpoint (eye height flattens blocks into an unreadable slab); `nil` without a fix or when the target is >100° off heading; x clamped to `-0.6…1.6 × width`, y to 2× height.
    static func groundPoint(for coordinate: CLLocationCoordinate2D,
                            pose: DevicePose,
                            screenSize: CGSize) -> CGPoint? {
        guard let user = pose.coordinate else { return nil }

        let delta = Angles.shortestDelta(from: pose.headingDegrees,
                                         to: bearing(from: user, to: coordinate))
        guard abs(delta) <= 100 else { return nil }

        let distance = distanceMeters(from: user, to: coordinate)
        let focalPx = Double(screenSize.height) / (2 * tan(verticalFOV / 2 * degToRad))
        let yBelowHorizon = focalPx * cameraHeightMeters / max(distance, 0.7)

        let horizon = horizonY(pose: pose, screenSize: screenSize)
        let y = min(horizon + CGFloat(yBelowHorizon), screenSize.height * 2)
        let x = clamp(screenX(forDelta: delta, screenSize: screenSize),
                      -0.6 * screenSize.width,
                      1.6 * screenSize.width)

        return CGPoint(x: x, y: y)
    }
}

// MARK: - Private helpers

private let degToRad = Double.pi / 180
private let radToDeg = 180 / Double.pi
private let earthRadiusMeters: CLLocationDistance = 6_371_000
private let cameraHeightMeters = 9.0

/// Horizontal screen position for a heading delta (degrees off screen center).
private func screenX(forDelta delta: Double, screenSize: CGSize) -> CGFloat {
    screenSize.width / 2 + CGFloat(delta / ARProjector.horizontalFOV) * screenSize.width
}

private func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
    min(max(value, lower), upper)
}

private func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
    min(max(value, lower), upper)
}
