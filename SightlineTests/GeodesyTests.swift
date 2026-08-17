import XCTest
import CoreLocation
@testable import Sightline

// MARK: - Angle math

final class AnglesTests: XCTestCase {

    func testNormalizedFoldsIntoZeroUpTo360() {
        let rows: [(input: Double, expected: Double)] = [
            (0, 0), (360, 0), (720, 0), (-360, 0),
            (-10, 350), (725, 5), (359.5, 359.5), (-0.5, 359.5),
        ]
        for row in rows {
            XCTAssertEqual(Angles.normalized(row.input), row.expected, accuracy: 1e-9, "\(row.input)")
        }
    }

    func testShortestDeltaTakesTheShortArcWithSign() {
        // Negative means "to" is to the left of "from".
        let rows: [(from: Double, to: Double, expected: Double)] = [
            (350, 10, 20), (10, 350, -20),
            (0, 180, 180), (180, 0, -180),
            (0, 181, -179), (90, 90, 0), (0, 540, 180),
            (359, 1, 2), (1, 359, -2),
        ]
        for row in rows {
            XCTAssertEqual(Angles.shortestDelta(from: row.from, to: row.to), row.expected,
                           accuracy: 1e-9, "\(row.from) -> \(row.to)")
        }
    }

    func testEMAWrapsAcrossNorth() {
        // Halfway from 350 to 10 is 0, never the long way around through 180.
        XCTAssertEqual(Angles.ema(current: 350, target: 10, alpha: 0.5), 0, accuracy: 1e-9)
        XCTAssertEqual(Angles.ema(current: 10, target: 350, alpha: 0.5), 0, accuracy: 1e-9)
        XCTAssertEqual(Angles.ema(current: 42, target: 137, alpha: 0), 42, accuracy: 1e-9)
        XCTAssertEqual(Angles.ema(current: 42, target: 137, alpha: 1), 137, accuracy: 1e-9)
    }

    func testAdaptiveAlphaBoundsAndRamp() {
        XCTAssertLessThan(Angles.noiseDegrees, Angles.motionDegrees)
        XCTAssertLessThan(Angles.minAlpha, Angles.maxAlpha)
        XCTAssertEqual(Angles.adaptiveAlpha(forDelta: 0), Angles.minAlpha)
        // The thresholds themselves belong to their plateaus, not the ramp.
        XCTAssertEqual(Angles.adaptiveAlpha(forDelta: Angles.noiseDegrees), Angles.minAlpha)
        XCTAssertEqual(Angles.adaptiveAlpha(forDelta: Angles.motionDegrees), Angles.maxAlpha)
        // Sign never matters: smoothing reacts to magnitude only.
        XCTAssertEqual(Angles.adaptiveAlpha(forDelta: -5), Angles.maxAlpha)
        let mid = (Angles.noiseDegrees + Angles.motionDegrees) / 2
        XCTAssertEqual(Angles.adaptiveAlpha(forDelta: mid),
                       (Angles.minAlpha + Angles.maxAlpha) / 2, accuracy: 1e-9)
        XCTAssertLessThan(Angles.adaptiveAlpha(forDelta: 0.6), Angles.adaptiveAlpha(forDelta: 1.8))
    }
}

// MARK: - Projector geodesy

final class ARProjectorGeodesyTests: XCTestCase {

    private let origin = CLLocationCoordinate2D(latitude: 43.7700, longitude: -79.5100)

    func testBearingRecoversTheLaidOutCourse() {
        for course in [0.0, 45, 90, 135, 180, 225, 270, 315, 359] {
            let target = destination(from: origin, bearing: course, meters: 800)
            let recovered = ARProjector.bearing(from: origin, to: target)
            XCTAssertEqual(recovered, course, accuracy: 0.05, "course \(course)")
            XCTAssertGreaterThanOrEqual(recovered, 0)
            XCTAssertLessThan(recovered, 360)
        }
    }

    func testDistanceMatchesTheConstructionAndCoreLocation() {
        for meters in [120.0, 800, 2500, 25_000] {
            let target = destination(from: origin, bearing: 45, meters: meters)
            let haversine = ARProjector.distanceMeters(from: origin, to: target)
            XCTAssertEqual(haversine, meters, accuracy: 0.5, "spherical round trip \(meters)")
            let ellipsoidal = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
                .distance(from: CLLocation(latitude: target.latitude, longitude: target.longitude))
            // CoreLocation is ellipsoidal; half-percent agreement keeps both models honest.
            XCTAssertEqual(haversine, ellipsoidal, accuracy: max(1, meters * 0.005), "vs CoreLocation \(meters)")
        }
    }

    func testZeroDistance() {
        XCTAssertEqual(ARProjector.distanceMeters(from: origin, to: origin), 0, accuracy: 1e-9)
    }

    func testBubbleOpacityRamp() {
        XCTAssertEqual(ARProjector.bubbleOpacity(forPitch: -90), 0)
        XCTAssertEqual(ARProjector.bubbleOpacity(forPitch: ARProjector.bubbleFadeOutPitch), 0)
        let mid = (ARProjector.bubbleFadeOutPitch + ARProjector.bubbleFadeInPitch) / 2
        XCTAssertEqual(ARProjector.bubbleOpacity(forPitch: mid), 0.5, accuracy: 1e-9)
        XCTAssertEqual(ARProjector.bubbleOpacity(forPitch: ARProjector.bubbleFadeInPitch), 1)
        XCTAssertEqual(ARProjector.bubbleOpacity(forPitch: 45), 1)
        // A NaN pitch (sensor glitch) must fail visible, not blank the HUD.
        XCTAssertEqual(ARProjector.bubbleOpacity(forPitch: .nan), 1)
    }

    func testOnScreenHysteresis() {
        // FOV and margins are read live: the AR path may calibrate the lens before tests run.
        let half = ARProjector.horizontalFOV / 2
        let enter = ARProjector.onScreenEnterMargin
        let exit = ARProjector.onScreenExitMargin
        // Without the enter/exit gap an edge bubble flickers between chip and arrow on heading noise.
        XCTAssertLessThan(enter, exit)
        XCTAssertTrue(ARProjector.isOnScreen(edgeAngle: half + enter, wasOnScreen: false))
        XCTAssertFalse(ARProjector.isOnScreen(edgeAngle: half + enter + 0.5, wasOnScreen: false))
        // The band between the margins is sticky: visible stays visible.
        XCTAssertTrue(ARProjector.isOnScreen(edgeAngle: half + enter + 0.5, wasOnScreen: true))
        XCTAssertTrue(ARProjector.isOnScreen(edgeAngle: half + exit, wasOnScreen: true))
        XCTAssertFalse(ARProjector.isOnScreen(edgeAngle: half + exit + 0.5, wasOnScreen: true))
        // Symmetric on the left edge.
        XCTAssertTrue(ARProjector.isOnScreen(edgeAngle: -(half + exit), wasOnScreen: true))
        XCTAssertFalse(ARProjector.isOnScreen(edgeAngle: -(half + enter + 0.5), wasOnScreen: false))
    }
}

// Great-circle destination on the app's sphere (R = 6371 km) — the tests' independent geometry oracle.
private func destination(from origin: CLLocationCoordinate2D,
                         bearing: Double, meters: Double) -> CLLocationCoordinate2D {
    let radius = 6_371_000.0
    let angular = meters / radius
    let theta = bearing * .pi / 180
    let lat1 = origin.latitude * .pi / 180
    let lon1 = origin.longitude * .pi / 180
    let lat2 = asin(sin(lat1) * cos(angular) + cos(lat1) * sin(angular) * cos(theta))
    let lon2 = lon1 + atan2(sin(theta) * sin(angular) * cos(lat1),
                            cos(angular) - sin(lat1) * sin(lat2))
    return CLLocationCoordinate2D(latitude: lat2 * 180 / .pi, longitude: lon2 * 180 / .pi)
}
