import XCTest
import CoreLocation
@testable import Sightline

// MARK: - LandmarkVisibilityPolicy

final class LandmarkVisibilityPolicyTests: XCTestCase {

    private let user = CLLocationCoordinate2D(latitude: 43.7700, longitude: -79.5100)
    // Integer-second reference dates keep age arithmetic exact at the freshness boundary.
    private let now = Date(timeIntervalSinceReferenceDate: 777_600_000)

    // ~111,320 m per degree of latitude; constructed distances stay within 0.2% of geodesic truth here.
    private func coordinate(metersNorth: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: 43.7700 + metersNorth / 111_320, longitude: -79.5100)
    }

    private func place(_ id: String, metersNorth: Double) -> Place {
        Place(id: id, name: id, category: .landmark, coordinate: coordinate(metersNorth: metersNorth))
    }

    // Margins well clear of the 1000 m cap absorb the flat-earth conversion error.
    private var near: Place { place("near", metersNorth: 400) }
    private var far: Place { place("far", metersNorth: 4200) }

    private func freshScan() -> LandmarkVisibilityPolicy.Context {
        .init(resultsSource: .scanCone, scanOrigin: user, scanTimestamp: now,
              userCoordinate: user, now: now)
    }

    // MARK: Search invariant

    func testSearchResultsAreNeverHiddenRegardlessOfRange() {
        let extreme = place("extreme", metersNorth: 25_000)
        let places = [near, far, extreme]
        // Hard product invariant: typed search is explicit intent, so no hostile context may hide its results.
        let hostileContexts: [LandmarkVisibilityPolicy.Context] = [
            .init(resultsSource: .search, userCoordinate: user, now: now),
            .init(resultsSource: .search, scanOrigin: user,
                  scanTimestamp: now.addingTimeInterval(-3600), userCoordinate: user, now: now),
            .init(resultsSource: .search, scanOrigin: coordinate(metersNorth: -5000),
                  scanTimestamp: now, userCoordinate: user, now: now),
            .init(isGeoARAwaitingLocalization: true, resultsSource: .search,
                  scanOrigin: user, scanTimestamp: now, userCoordinate: user, now: now),
        ]
        for context in hostileContexts {
            XCTAssertTrue(LandmarkVisibilityPolicy.hiddenIDs(in: places, context: context).isEmpty,
                          "search results must survive every context")
        }
    }

    // MARK: Scan freshness

    func testFreshScanKeepsLongRangeLandmarks() {
        XCTAssertTrue(LandmarkVisibilityPolicy.hiddenIDs(in: [near, far], context: freshScan()).isEmpty)
    }

    func testStaleScanHidesOnlyLongRange() {
        var context = freshScan()
        context.scanTimestamp = now.addingTimeInterval(-11 * 60)
        XCTAssertEqual(LandmarkVisibilityPolicy.hiddenIDs(in: [near, far], context: context), ["far"])
    }

    func testScanAgeBoundaryIsInclusive() {
        // Exactly at scanContextMaxAge the scan still counts as fresh; one second past, it does not.
        var atLimit = freshScan()
        atLimit.scanTimestamp = now.addingTimeInterval(-LandmarkVisibilityPolicy.scanContextMaxAge)
        XCTAssertTrue(LandmarkVisibilityPolicy.hiddenIDs(in: [near, far], context: atLimit).isEmpty)

        var pastLimit = freshScan()
        pastLimit.scanTimestamp = now.addingTimeInterval(-(LandmarkVisibilityPolicy.scanContextMaxAge + 1))
        XCTAssertEqual(LandmarkVisibilityPolicy.hiddenIDs(in: [near, far], context: pastLimit), ["far"])
    }

    func testDriftBeyondScanOriginHidesLongRange() {
        // 200 m of drift is inside the 250 m allowance; 300 m is beyond it.
        var withinDrift = freshScan()
        withinDrift.scanOrigin = coordinate(metersNorth: -200)
        XCTAssertTrue(LandmarkVisibilityPolicy.hiddenIDs(in: [near, far], context: withinDrift).isEmpty)

        var drifted = freshScan()
        drifted.scanOrigin = coordinate(metersNorth: -300)
        XCTAssertEqual(LandmarkVisibilityPolicy.hiddenIDs(in: [near, far], context: drifted), ["far"])
    }

    func testMissingScanContextIsNeverFresh() {
        var noOrigin = freshScan()
        noOrigin.scanOrigin = nil
        XCTAssertEqual(LandmarkVisibilityPolicy.hiddenIDs(in: [near, far], context: noOrigin), ["far"])

        var noTimestamp = freshScan()
        noTimestamp.scanTimestamp = nil
        XCTAssertEqual(LandmarkVisibilityPolicy.hiddenIDs(in: [near, far], context: noTimestamp), ["far"])
    }

    // MARK: Result-set origin

    func testAmbientResultsHideLongRangeEvenWithFreshContext() {
        // Only a deliberate scan earns long-range trust; ambient results never do, however fresh.
        let context = LandmarkVisibilityPolicy.Context(resultsSource: .other, scanOrigin: user,
                                                       scanTimestamp: now, userCoordinate: user, now: now)
        XCTAssertEqual(LandmarkVisibilityPolicy.hiddenIDs(in: [near, far], context: context), ["far"])
    }

    func testAwaitingLocalizationWithholdsLongRangeOnFreshScan() {
        var context = freshScan()
        context.isGeoARAwaitingLocalization = true
        XCTAssertEqual(LandmarkVisibilityPolicy.hiddenIDs(in: [near, far], context: context), ["far"])
        // Near places live at street level and are never touched by the indoor rule.
        XCTAssertTrue(LandmarkVisibilityPolicy.hiddenIDs(in: [near], context: context).isEmpty)
    }

    // MARK: Fail-open and range cap

    func testMissingUserCoordinateFailsOpen() {
        let context = LandmarkVisibilityPolicy.Context(resultsSource: .other, userCoordinate: nil, now: now)
        XCTAssertTrue(LandmarkVisibilityPolicy.hiddenIDs(in: [near, far], context: context).isEmpty)
    }

    func testRangeCapOnlyHidesBeyondFallbackMax() {
        // 950 m and 1050 m bracket the 1000 m cap with margin for geodesic error.
        let inside = place("inside-cap", metersNorth: 950)
        let outside = place("outside-cap", metersNorth: 1050)
        let context = LandmarkVisibilityPolicy.Context(resultsSource: .other, userCoordinate: user, now: now)
        XCTAssertEqual(LandmarkVisibilityPolicy.hiddenIDs(in: [inside, outside], context: context),
                       ["outside-cap"])
    }

    func testContainsLongRange() {
        XCTAssertTrue(LandmarkVisibilityPolicy.containsLongRange([near, far], userCoordinate: user))
        XCTAssertFalse(LandmarkVisibilityPolicy.containsLongRange([near], userCoordinate: user))
        XCTAssertFalse(LandmarkVisibilityPolicy.containsLongRange([near, far], userCoordinate: nil))
    }
}

// MARK: - OcclusionPolicy

final class OcclusionPolicyTests: XCTestCase {

    func testTuningConstantsMatchReviewedRules() {
        // The reviewed occlusion contract is these four numbers; changing one is a product decision, not a refactor.
        XCTAssertEqual(OcclusionPolicy.buildingNearFraction, 0.85)
        XCTAssertEqual(OcclusionPolicy.terrainNearFraction, 0.50)
        XCTAssertEqual(OcclusionPolicy.minSeparationMeters, 10.0)
        XCTAssertEqual(OcclusionPolicy.centroidSeparationMeters, 60.0)
    }

    private struct Case {
        let name: String
        let target: Double
        let building: Double?
        let terrain: Double?
        var allowance: Double = OcclusionPolicy.minSeparationMeters
        let occluded: Bool
    }

    func testVerdictTable() {
        let cases: [Case] = [
            // 0.85 rule: a ray grazing the target's own facade is not occlusion.
            Case(name: "self-graze facade", target: 47, building: 45, terrain: nil, occluded: false),
            Case(name: "row of houses blocks distant shop", target: 300, building: 40, terrain: nil, occluded: true),
            Case(name: "near roof clips tall target", target: 4200, building: 60, terrain: nil, occluded: true),
            // Building exactly at 0.85 * d must not count as nearer.
            Case(name: "fraction boundary exact", target: 100, building: 85, terrain: nil, occluded: false),
            Case(name: "fraction just inside", target: 100, building: 84, terrain: nil, occluded: true),
            // Separation guard: the hit must be strictly more than the allowance short of the target.
            Case(name: "separation exactly at allowance", target: 50, building: 40, terrain: nil, occluded: false),
            Case(name: "separation just past allowance", target: 50, building: 39, terrain: nil, occluded: true),
            Case(name: "close target inside fraction but not separated", target: 15, building: 8, terrain: nil, occluded: false),
            // Fail open whenever geometry is missing or degenerate.
            Case(name: "no geometry far", target: 4200, building: nil, terrain: nil, occluded: false),
            Case(name: "no geometry near", target: 120, building: nil, terrain: nil, occluded: false),
            Case(name: "degenerate range", target: 0.4, building: 0.1, terrain: nil, occluded: false),
            Case(name: "range exactly one meter", target: 1.0, building: 0.1, terrain: nil, occluded: false),
            // Terrain uses the stricter 0.50 fraction: the road under the ray never blocks.
            Case(name: "flat road under ray", target: 300, building: nil, terrain: 280, occluded: false),
            Case(name: "hill genuinely in the way", target: 900, building: nil, terrain: 300, occluded: true),
            Case(name: "building clear but terrain blocks", target: 900, building: 880, terrain: 300, occluded: true),
            // 60 m centroid allowance: a deep footprint's own facade hit must not hide it.
            Case(name: "centroid self-hit allowed", target: 250, building: 200, terrain: nil,
                 allowance: OcclusionPolicy.centroidSeparationMeters, occluded: false),
            Case(name: "street anchor same geometry is blocked", target: 250, building: 200, terrain: nil, occluded: true),
            Case(name: "centroid still blocked by far row", target: 300, building: 40, terrain: nil,
                 allowance: OcclusionPolicy.centroidSeparationMeters, occluded: true),
            // The allowance widens only the building self-hit guard, never the terrain one.
            Case(name: "terrain ignores centroid allowance", target: 100, building: nil, terrain: 45,
                 allowance: OcclusionPolicy.centroidSeparationMeters, occluded: true),
        ]
        for c in cases {
            XCTAssertEqual(OcclusionPolicy.isOccluded(targetDistance: c.target,
                                                      nearestBuildingHit: c.building,
                                                      nearestTerrainHit: c.terrain,
                                                      selfHitAllowanceMeters: c.allowance),
                           c.occluded, c.name)
        }
    }

    func testDefaultAllowanceIsStreetAnchorSeparation() {
        // Omitting the allowance must behave exactly like passing minSeparationMeters.
        XCTAssertTrue(OcclusionPolicy.isOccluded(targetDistance: 250, nearestBuildingHit: 200,
                                                 nearestTerrainHit: nil))
        XCTAssertEqual(OcclusionPolicy.isOccluded(targetDistance: 250, nearestBuildingHit: 200,
                                                  nearestTerrainHit: nil),
                       OcclusionPolicy.isOccluded(targetDistance: 250, nearestBuildingHit: 200,
                                                  nearestTerrainHit: nil,
                                                  selfHitAllowanceMeters: OcclusionPolicy.minSeparationMeters))
    }
}
