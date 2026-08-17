import XCTest
import CoreLocation
@testable import Sightline

// The suite rides RouteManager's DEBUG-only installTestRoute seam; test builds always compile Debug.
#if DEBUG

@MainActor
final class RouteManagerTests: XCTestCase {

    private let metersPerDegreeLat = 111_320.0

    private func coordinate(metersNorth: Double, metersEast: Double = 0) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: 43.7700 + metersNorth / metersPerDegreeLat,
            longitude: -79.5100 + metersEast / (metersPerDegreeLat * cos(43.7700 * .pi / 180)))
    }

    private func location(metersNorth: Double, metersEast: Double = 0) -> CLLocation {
        let c = coordinate(metersNorth: metersNorth, metersEast: metersEast)
        return CLLocation(latitude: c.latitude, longitude: c.longitude)
    }

    private func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    // 500 m straight walk north, densified by the production pipeline inside the seam — MapKit never runs.
    private func makeManager(steps: [RouteStep] = [], stepDenseIndices: [Int] = []) -> RouteManager {
        let manager = RouteManager()
        let destination = Place(id: "dest", name: "Destination", category: .cafe,
                                coordinate: coordinate(metersNorth: 500))
        manager.installTestRoute(destination: destination,
                                 rawPoints: [coordinate(metersNorth: 0), coordinate(metersNorth: 500)],
                                 expectedTravelTime: 600,
                                 steps: steps,
                                 stepDenseIndices: stepDenseIndices)
        return manager
    }

    // MARK: - Arrival requires BOTH conditions

    func testTrueArrivalNearEndpoint() {
        let manager = makeManager()
        // 5 m short of the door: remaining < 15 and endpoint gap <= 25.
        let progress = manager.progress(from: location(metersNorth: 495))
        XCTAssertEqual(progress?.hasArrived, true)
        // Arrival silences turn instructions.
        XCTAssertNil(progress?.nextInstruction)
    }

    func testParallelStreetIsNotArrival() {
        let manager = makeManager()
        // The parallel-street trap: nearest polyline point is the endpoint, so remaining collapses to ~0,
        // but the user is 80 m from the actual door — polyline progress alone must not declare arrival.
        let progress = manager.progress(from: location(metersNorth: 500, metersEast: 80))
        XCTAssertNotNil(progress)
        XCTAssertLessThan(progress?.remainingDistance ?? .infinity, 15)
        XCTAssertEqual(progress?.hasArrived, false)
    }

    func testEndpointProximityAloneIsNotArrival() {
        let manager = makeManager()
        // 20 m short on-path: endpoint gap passes (<= 25 m) but remaining fails (not < 15 m).
        let progress = manager.progress(from: location(metersNorth: 480))
        XCTAssertEqual(progress?.hasArrived, false)
        XCTAssertGreaterThanOrEqual(progress?.remainingDistance ?? 0, 15)
        XCTAssertLessThan(progress?.remainingDistance ?? .infinity, 30)
    }

    // MARK: - Progress math

    func testRemainingDistanceAndTimeScaleWithPosition() {
        let manager = makeManager()
        let progress = manager.progress(from: location(metersNorth: 400))
        XCTAssertEqual(progress?.remainingDistance ?? 0, 100, accuracy: 8)
        // expectedTravelTime 600 s over ~500 m: 100 m left is ~120 s.
        XCTAssertEqual(progress?.remainingTime ?? 0, 120, accuracy: 12)
        XCTAssertEqual(progress?.hasArrived, false)
    }

    func testLookaheadStartsAtUserAndEndsAtDestination() throws {
        let manager = makeManager()
        let progress = try XCTUnwrap(manager.progress(from: location(metersNorth: 400)))
        let first = try XCTUnwrap(progress.lookahead.first)
        let last = try XCTUnwrap(progress.lookahead.last)
        // The guide line is drawn from the user's snapped point to the exact endpoint.
        XCTAssertLessThan(distance(first, coordinate(metersNorth: 400)), 5)
        XCTAssertLessThan(distance(last, coordinate(metersNorth: 500)), 1)
        // ~100 m of 4 m spacing remains: the tail must be the remainder, not the whole path.
        XCTAssertTrue((20...32).contains(progress.lookahead.count),
                      "unexpected lookahead count \(progress.lookahead.count)")
    }

    // MARK: - Refresh-interval caching

    func testProgressServesCachedResultWithinRefreshInterval() throws {
        let manager = makeManager()
        let t0 = ProcessInfo.processInfo.systemUptime
        let first = manager.progress(from: location(metersNorth: 400))
        let second = manager.progress(from: location(metersNorth: 300))
        let elapsed = ProcessInfo.processInfo.systemUptime - t0
        // The 8 Hz cache is keyed on uptime; only assert when both calls provably landed in one window.
        try XCTSkipIf(elapsed >= 0.125, "runner stalled across the refresh window; cache unobservable")
        XCTAssertEqual(second?.remainingDistance, first?.remainingDistance)
        XCTAssertEqual(second?.hasArrived, first?.hasArrived)
    }

    func testProgressRecomputesAfterRefreshInterval() async throws {
        let manager = makeManager()
        let first = manager.progress(from: location(metersNorth: 400))
        XCTAssertEqual(first?.remainingDistance ?? 0, 100, accuracy: 8)
        // The interval is wall-uptime inside the manager, so crossing it needs a real (short) sleep.
        try await Task.sleep(nanoseconds: 200_000_000)
        let second = manager.progress(from: location(metersNorth: 300))
        XCTAssertEqual(second?.remainingDistance ?? 0, 200, accuracy: 8)
    }

    // MARK: - Instructions

    func testNextInstructionPicksFirstStepAheadOfUser() {
        let steps = [RouteStep(instruction: "Turn left onto Springside Rd"),
                     RouteStep(instruction: "Continue onto Jane St")]
        let manager = makeManager(steps: steps, stepDenseIndices: [75, 110])
        // At ~100 m along (dense index ~25) both steps are ahead; announce the first.
        let progress = manager.progress(from: location(metersNorth: 100))
        XCTAssertEqual(progress?.nextInstruction, "Turn left onto Springside Rd")
    }

    func testStepsAlreadyPassedAreNotAnnounced() {
        let steps = [RouteStep(instruction: "Turn left onto Springside Rd"),
                     RouteStep(instruction: "Continue onto Jane St")]
        let manager = makeManager(steps: steps, stepDenseIndices: [25, 110])
        // At ~200 m along (dense index ~50) the 25-index step is behind the user.
        let progress = manager.progress(from: location(metersNorth: 200))
        XCTAssertEqual(progress?.nextInstruction, "Continue onto Jane St")
    }

    // MARK: - Lifecycle

    func testStopClearsRouteAndProgress() {
        let manager = makeManager()
        XCTAssertNotNil(manager.progress(from: location(metersNorth: 400)))
        manager.stop()
        XCTAssertNil(manager.route)
        XCTAssertNil(manager.lastError)
        XCTAssertNil(manager.progress(from: location(metersNorth: 400)))
    }

    func testProgressIsNilWithoutRoute() {
        let manager = RouteManager()
        XCTAssertNil(manager.progress(from: location(metersNorth: 0)))
    }
}

#endif
