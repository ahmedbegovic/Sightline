import XCTest
import CoreLocation
@testable import Sightline

// MARK: - TransitStopIdentity.identity

final class TransitStopIdentityNameTests: XCTestCase {

    func testIdentityNormalizesEquivalentStopNames() {
        let cases: [(name: String, expected: String?)] = [
            ("Jane St / Springside Rd", "jane|springside"),
            ("Jane Street at Springside Rd (North Side)", "jane|springside"),
            ("Springside Rd / Jane St - Platform 2", "jane|springside"),
            ("Springside Rd & Jane St Northbound", "jane|springside"),
            ("Jane St and Springside Rd", "jane|springside"),
            ("King St / Queen St [Eastbound]", "king|queen"),
            ("Weston Rd & Lawrence Ave Stop #1234", "lawrence|weston"),
            ("Jane St North Side / Springside Rd", "jane|springside"),
            // "at" splits as a whole word only; street names containing it must survive intact.
            ("Athens Rd / Cathay St", "athens|cathay"),
            // Direction words match as whole tokens, so compound names like Northside keep their identity.
            ("Northside Ave / Springside Rd", "northside|springside"),
            // Multi-token street names keep their non-noise tokens joined.
            ("St Clair Ave / Old Weston Rd", "clair|old-weston"),
            // No cross street means no identity; these must never be merged by name.
            ("Union Station", nil),
            ("Main St", nil),
        ]
        for c in cases {
            XCTAssertEqual(TransitStopIdentity.identity(forName: c.name), c.expected, c.name)
        }
    }

    func testIdentityIsOrderIndependent() {
        XCTAssertEqual(TransitStopIdentity.identity(forName: "Keele St / Dundas St"),
                       TransitStopIdentity.identity(forName: "Dundas St at Keele St"))
        XCTAssertEqual(TransitStopIdentity.identity(forName: "Keele St / Dundas St"), "dundas|keele")
    }

    func testIdentityFoldsDiacritics() {
        XCTAssertEqual(TransitStopIdentity.identity(forName: "Bélair Rd / Église Ave"), "belair|eglise")
    }
}

// MARK: - TransitStopIdentity.deduped

final class TransitStopDedupTests: XCTestCase {

    private let origin = CLLocationCoordinate2D(latitude: 43.7700, longitude: -79.5100)

    private func coordinate(metersNorth: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: 43.7700 + metersNorth / 111_320, longitude: -79.5100)
    }

    private func stop(_ id: String, _ name: String, metersNorth: Double,
                      category: PlaceCategory = .transit) -> Place {
        Place(id: id, name: name, category: category, coordinate: coordinate(metersNorth: metersNorth))
    }

    func testDuplicatePairCollapsesToNearestRegardlessOfInputOrder() {
        let near = stop("near", "Jane St / Springside Rd", metersNorth: 74)
        let farSide = stop("farSide", "Springside Rd at Jane St (South Side)", metersNorth: 84)
        // The survivor is chosen by distance from the user, never by list position.
        XCTAssertEqual(TransitStopIdentity.deduped([farSide, near], origin: origin).map(\.id), ["near"])
        XCTAssertEqual(TransitStopIdentity.deduped([near, farSide], origin: origin).map(\.id), ["near"])
    }

    func testSameIdentityBeyondMergeRadiusBothSurvive() {
        // Same corner name 400 m apart is two genuinely different intersections.
        let a = stop("a", "Jane St / Springside Rd", metersNorth: 74)
        let b = stop("b", "Springside Rd / Jane St", metersNorth: 474)
        XCTAssertEqual(TransitStopIdentity.deduped([a, b], origin: origin).count, 2)
    }

    func testDifferentIdentitiesCloseTogetherBothSurvive() {
        let a = stop("a", "Jane St / Springside Rd", metersNorth: 74)
        let b = stop("b", "Jane St / Weston Rd", metersNorth: 84)
        XCTAssertEqual(TransitStopIdentity.deduped([a, b], origin: origin).count, 2)
    }

    func testIdentitylessTransitNamesNeverMerge() {
        // Two "Union Station" entrances are distinct places, not duplicate stops.
        let a = stop("a", "Union Station", metersNorth: 0)
        let b = stop("b", "Union Station", metersNorth: 5)
        XCTAssertEqual(TransitStopIdentity.deduped([a, b], origin: origin).count, 2)
    }

    func testNonTransitPlacesPassThrough() {
        // A restaurant named "A / B" must never enter transit-stop clustering.
        let a = stop("a", "Fish / Chips", metersNorth: 0, category: .restaurant)
        let b = stop("b", "Chips / Fish", metersNorth: 5, category: .restaurant)
        XCTAssertEqual(TransitStopIdentity.deduped([a, b], origin: origin).count, 2)
    }

    func testThreeStopsCollapseIntoTwoClusters() {
        let a = stop("a", "Jane St / Springside Rd", metersNorth: 74)
        let b = stop("b", "Springside Rd at Jane St", metersNorth: 84)
        // Same identity again but 226 m from the first cluster: a separate real stop.
        let c = stop("c", "Jane St / Springside Rd", metersNorth: 300)
        XCTAssertEqual(Set(TransitStopIdentity.deduped([a, b, c], origin: origin).map(\.id)), ["a", "c"])
    }

    func testDedupPreservesInputOrderOfSurvivors() {
        let first = stop("first", "Jane St / Springside Rd", metersNorth: 74)
        let restaurant = stop("mid", "Corner Grill", metersNorth: 10, category: .restaurant)
        let dup = stop("dup", "Springside Rd / Jane St", metersNorth: 84)
        let result = TransitStopIdentity.deduped([first, restaurant, dup], origin: origin)
        XCTAssertEqual(result.map(\.id), ["first", "mid"])
    }
}

// MARK: - PlacesService.collapseSameName

// collapseSameName is pure and stateless, so calling it on the singleton never leaves the process.
final class SameNameCollapseTests: XCTestCase {

    private let service = PlacesService.shared

    private func coordinate(metersNorth: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: 43.7700 + metersNorth / 111_320, longitude: -79.5100)
    }

    private func cafe(_ id: String, name: String, metersNorth: Double,
                      anchorMetersNorth: Double? = nil) -> Place {
        Place(id: id, name: name, category: .cafe,
              coordinate: coordinate(metersNorth: metersNorth),
              anchorCoordinate: anchorMetersNorth.map { coordinate(metersNorth: $0) })
    }

    func testSameNameTwoHundredMetersApartBothSurvive() {
        // Beyond the 150 m twin radius these are two real branches; both bubbles must float.
        let a = cafe("a", name: "Aroma Espresso Bar", metersNorth: 0)
        let b = cafe("b", name: "Aroma Espresso Bar", metersNorth: 200)
        XCTAssertEqual(service.collapseSameName([a, b]).map(\.id), ["a", "b"])
    }

    func testSameNameWithinRadiusCollapsesToFirst() {
        // Input is ordered best-first, so the first listing of the pair is the survivor.
        let best = cafe("best", name: "Aroma Espresso Bar", metersNorth: 0)
        let counter = cafe("counter", name: "Aroma Espresso Bar", metersNorth: 100)
        XCTAssertEqual(service.collapseSameName([best, counter]).map(\.id), ["best"])
        XCTAssertEqual(service.collapseSameName([counter, best]).map(\.id), ["counter"])
    }

    func testNameMatchIsCaseInsensitive() {
        let a = cafe("a", name: "The Corner Cafe", metersNorth: 0)
        let b = cafe("b", name: "the corner CAFE", metersNorth: 50)
        XCTAssertEqual(service.collapseSameName([a, b]).map(\.id), ["a"])
    }

    func testCollapseMeasuresStreetAnchorsNotCentroids() {
        let a = cafe("a", name: "Galleria Food Court", metersNorth: 0)
        // Centroid 400 m away but the published entrance is 60 m from the first listing: same venue.
        let sameDoor = cafe("sameDoor", name: "Galleria Food Court", metersNorth: 400,
                            anchorMetersNorth: 60)
        XCTAssertEqual(service.collapseSameName([a, sameDoor]).map(\.id), ["a"])

        // Centroid nearby but the entrance 400 m away: a different branch, kept.
        let farDoor = cafe("farDoor", name: "Galleria Food Court", metersNorth: 60,
                           anchorMetersNorth: 400)
        XCTAssertEqual(service.collapseSameName([a, farDoor]).map(\.id), ["a", "farDoor"])
    }

    func testDifferentNamesNeverCollapse() {
        let a = cafe("a", name: "Aroma Espresso Bar", metersNorth: 0)
        let b = cafe("b", name: "Balzac's Coffee", metersNorth: 5)
        XCTAssertEqual(service.collapseSameName([a, b]).count, 2)
    }
}
