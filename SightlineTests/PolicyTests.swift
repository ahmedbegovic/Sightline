import XCTest
import CoreLocation
@testable import Sightline

// MARK: - Ambient venue gate

final class VenueCategoryPolicyTests: XCTestCase {

    func testAllowlistedPrimaryTypePasses() {
        XCTAssertTrue(VenueCategoryPolicy.isAmbientVenue(primaryType: "cafe", types: nil))
        XCTAssertTrue(VenueCategoryPolicy.isAmbientVenue(primaryType: "bus_stop", types: nil))
        XCTAssertTrue(VenueCategoryPolicy.isAmbientVenue(primaryType: "hospital", types: nil))
    }

    func testVenueTypeAnywhereInTypesArrayPasses() {
        XCTAssertTrue(VenueCategoryPolicy.isAmbientVenue(primaryType: "point_of_interest",
                                                         types: ["establishment", "cafe"]))
        XCTAssertTrue(VenueCategoryPolicy.isAmbientVenue(primaryType: nil, types: ["museum"]))
    }

    // Ambient scans are curated: a place Google left untyped must not float a bubble.
    func testUntypedPlacesFailTheGate() {
        XCTAssertFalse(VenueCategoryPolicy.isAmbientVenue(primaryType: nil, types: nil))
        XCTAssertFalse(VenueCategoryPolicy.isAmbientVenue(primaryType: nil, types: []))
        XCTAssertFalse(VenueCategoryPolicy.isAmbientVenue(primaryType: "", types: ["establishment"]))
    }

    // Errand stops (money, fuel, mail) stay searchable but never ambient — documented 2026-08-16 decision.
    func testSearchOnlyErrandTypesStayOut() {
        for type in ["atm", "bank", "credit_union", "gas_station", "post_office"] {
            XCTAssertFalse(VenueCategoryPolicy.isAmbientVenue(primaryType: type, types: [type]), type)
        }
    }

    func testServicesAndHomeLodgingStayOut() {
        for type in ["beauty_salon", "hair_salon", "gym", "school", "plumber",
                     "real_estate_agency", "lodging", "bed_and_breakfast", "guest_house"] {
            XCTAssertFalse(VenueCategoryPolicy.isAmbientVenue(primaryType: type, types: [type]), type)
        }
    }

    // A real hotel carries "lodging" alongside "hotel"; only the bare home-lodging profile is excluded.
    func testRealHotelPassesEvenWithLodgingPresent() {
        XCTAssertTrue(VenueCategoryPolicy.isAmbientVenue(primaryType: "lodging",
                                                         types: ["lodging", "hotel"]))
    }

    func testSuffixFamilies() {
        XCTAssertTrue(VenueCategoryPolicy.isAmbientVenue(primaryType: "thai_restaurant", types: nil))
        XCTAssertTrue(VenueCategoryPolicy.isAmbientVenue(primaryType: "electronics_store", types: nil))
        // "_shop" is deliberately not a family — it would re-admit barber_shop et al.
        XCTAssertFalse(VenueCategoryPolicy.isAmbientVenue(primaryType: "barber_shop", types: ["barber_shop"]))
    }
}

// MARK: - Scan failure classification

final class ScanFailurePolicyTests: XCTestCase {

    func testClassifyTable() {
        let rows: [(error: any Error, expected: ScanFailure, label: String)] = [
            (GooglePlacesService.RequestError.accessDenied(status: 401, message: nil), .accessDenied, "401"),
            (GooglePlacesService.RequestError.accessDenied(status: 403, message: "key rejected"), .accessDenied, "403"),
            (GooglePlacesService.RequestError.rateLimited(status: 429, message: nil), .serviceBusy, "429"),
            (GooglePlacesService.RequestError.serverError(status: 500, message: nil), .serviceBusy, "500"),
            (GooglePlacesService.RequestError.serverError(status: 599, message: nil), .serviceBusy, "599"),
            (GooglePlacesService.RequestError.badRequest(status: 400, message: nil), .other, "400"),
            (GooglePlacesService.RequestError.badRequest(status: 404, message: nil), .other, "404"),
            (CancellationError(), .other, "structured cancellation"),
            (URLError(.cancelled), .other, "URL cancellation"),
            (URLError(.badServerResponse), .other, "bad server response is not connectivity"),
            (URLError(.badURL), .other, "bad URL"),
            (GooglePlacesService.APIError(message: "Places API error 403"), .other,
             "stringly APIError must never claim connectivity"),
            (NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet), .offline,
             "NSError in the URL domain classifies like the bridged struct"),
            (NSError(domain: "SightlineTests", code: 7), .other, "foreign domain"),
        ]
        for row in rows {
            XCTAssertEqual(ScanFailurePolicy.classify(row.error), row.expected, row.label)
        }
    }

    // Every connectivity code the policy owns must read as offline, not as a generic failure.
    func testAllConnectivityCodesClassifyOffline() {
        let codes: [URLError.Code] = [
            .notConnectedToInternet, .networkConnectionLost, .timedOut,
            .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
            .dataNotAllowed, .internationalRoamingOff, .callIsActive,
            .cannotLoadFromNetwork, .secureConnectionFailed,
        ]
        for code in codes {
            XCTAssertEqual(ScanFailurePolicy.classify(URLError(code)), .offline, "\(code)")
        }
    }

    func testSensorFailureBoundaries() {
        // Injected `now` keeps staleness math off the real clock.
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func fix(accuracy: CLLocationDistance, age: TimeInterval) -> CLLocation {
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: 43.7700, longitude: -79.5100),
                       altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: 5,
                       timestamp: now.addingTimeInterval(-age))
        }
        let rows: [(accuracy: CLLocationDistance, age: TimeInterval, compassBad: Bool,
                    expected: ScanFailure?, label: String)] = [
            (12, 1, false, nil, "healthy fix"),
            (0, 0, false, nil, "zero accuracy is a perfect fix, not the sentinel"),
            (-1, 1, false, .poorSensors, "CoreLocation invalid-fix sentinel"),
            (ScanFailurePolicy.maxHorizontalAccuracy, 0, false, nil, "accuracy boundary itself is usable"),
            (ScanFailurePolicy.maxHorizontalAccuracy + 0.5, 0, false, .poorSensors, "just past the accuracy boundary"),
            (200, 1, false, .poorSensors, "hopeless accuracy"),
            (12, ScanFailurePolicy.maxLocationAge, false, nil, "staleness boundary itself is usable"),
            (12, ScanFailurePolicy.maxLocationAge + 0.5, false, .poorSensors, "just past the staleness boundary"),
            (12, 120, false, .poorSensors, "stale fix"),
            (12, 1, true, .poorSensors, "degraded compass alone fails the gate"),
            (ScanFailurePolicy.maxHorizontalAccuracy, ScanFailurePolicy.maxLocationAge, false, nil,
             "both boundaries at once still pass"),
        ]
        for row in rows {
            XCTAssertEqual(ScanFailurePolicy.sensorFailure(location: fix(accuracy: row.accuracy, age: row.age),
                                                           compassUnreliable: row.compassBad,
                                                           now: now),
                           row.expected, row.label)
        }
    }

    // Pins the documented policy values: ~a city block of accuracy, half a minute of staleness.
    func testThresholdConstantsMatchTheDocumentedGate() {
        XCTAssertEqual(ScanFailurePolicy.maxHorizontalAccuracy, 65)
        XCTAssertEqual(ScanFailurePolicy.maxLocationAge, 30)
    }
}

// MARK: - Cone scoring & same-name curation

// Relies on coneScored / collapseSameName / passesAmbientQuality being internal in PlacesService (see handoff).
final class ConeCurationTests: XCTestCase {

    private let origin = CLLocationCoordinate2D(latitude: 43.7700, longitude: -79.5100)
    private let heading = 0.0
    private let radius: CLLocationDistance = 300
    private var halfCone: Double { PlacesService.scanConeDegrees / 2 }

    private func place(_ name: String, id: String, bearing: Double, meters: Double,
                       category: PlaceCategory = .restaurant,
                       rating: Double = 4.5, reviews: Int = 50) -> Place {
        var built = Place(id: id, name: name, category: category,
                          coordinate: destination(from: origin, bearing: bearing, meters: meters))
        built.rating = rating
        built.reviewCount = reviews
        return built
    }

    private func scored(_ candidates: [Place]) -> [(place: Place, score: Double)] {
        PlacesService.shared.coneScored(candidates, from: origin, headingDegrees: heading,
                                        coneDegrees: PlacesService.scanConeDegrees, radius: radius)
    }

    func testScoreFormulaAndOrdering() {
        let candidates = [
            place("Edge", id: "edge", bearing: 34, meters: 100),
            place("Ahead Far", id: "far", bearing: 0, meters: 270),
            place("Off Axis", id: "off", bearing: 24, meters: 60),
            place("Ahead Near", id: "near", bearing: 0, meters: 60),
            place("Outside", id: "outside", bearing: 40, meters: 60),
            place("Behind", id: "behind", bearing: 180, meters: 60),
        ]
        let result = scored(candidates)
        // Ascending score = best first; the 40° and 180° candidates never make the cone.
        XCTAssertEqual(result.map { $0.place.id }, ["near", "far", "off", "edge"])
        // Recompute each score with the app's own geometry primitives: the published weights are 0.6 angle, 0.4 distance.
        for entry in result {
            let bearing = ARProjector.bearing(from: origin, to: entry.place.arCoordinate)
            let delta = abs(Angles.shortestDelta(from: heading, to: bearing))
            let distance = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
                .distance(from: CLLocation(latitude: entry.place.arCoordinate.latitude,
                                           longitude: entry.place.arCoordinate.longitude))
            let expected = (delta / halfCone) * 0.6 + (distance / radius) * 0.4
            XCTAssertEqual(entry.score, expected, accuracy: 1e-6, entry.place.name)
        }
    }

    // The 1.5x angle weight means a dead-ahead place at the radius edge still beats a near off-axis one.
    func testAngleOutweighsDistance() {
        let wellAimedFar = place("Aimed Far", id: "aimedfar", bearing: 0, meters: 290)
        let offAxisNear = place("Off Axis Near", id: "offnear", bearing: 30, meters: 60)
        let result = scored([offAxisNear, wellAimedFar])
        XCTAssertEqual(result.map { $0.place.id }, ["aimedfar", "offnear"])
    }

    // The gate is halfCone + 4°: slack for anchor offsets, but not a widening of the product cone.
    func testConeGateHonorsTheFourDegreeSlack() {
        let justInside = place("Just Inside", id: "in", bearing: halfCone + 3.5, meters: 100)
        let justOutside = place("Just Outside", id: "out", bearing: halfCone + 5, meters: 100)
        XCTAssertEqual(scored([justInside, justOutside]).map { $0.place.id }, ["in"])
    }

    func testCollapseKeepsTheFirstOfAnOrderedTwinPair() {
        // Input contract: ordered best-first, and matching is case-insensitive.
        var winner = place("Aroma Espresso Bar", id: "w", bearing: 0, meters: 80, category: .cafe)
        winner.details = PlaceDetails(address: "1 Main St",
                                      reviews: [Review(id: "r1", author: "A", stars: 5, text: "Great")])
        let twin = place("aroma espresso bar", id: "t", bearing: 3, meters: 120, category: .cafe)
        let kept = PlacesService.shared.collapseSameName([winner, twin])
        XCTAssertEqual(kept.map(\.id), ["w"])
        // Rich state rides along: details attach via place.details and survive curation untouched.
        XCTAssertEqual(kept.first?.address, "1 Main St")
        XCTAssertEqual(kept.first?.reviews.count, 1)
    }

    func testSameNameBeyond150MetersIsTwoVenues() {
        let a = place("Tim Hortons", id: "a", bearing: 0, meters: 50)
        let b = place("Tim Hortons", id: "b", bearing: 0, meters: 260)
        XCTAssertEqual(PlacesService.shared.collapseSameName([a, b]).count, 2)
    }

    func testCollapseMeasuresStreetSideAnchorsNotCentroids() {
        var a = place("Mall Anchor", id: "a", bearing: 0, meters: 100)
        a.anchorCoordinate = destination(from: origin, bearing: 0, meters: 150)
        var b = place("Mall Anchor", id: "b", bearing: 0, meters: 400)
        b.anchorCoordinate = destination(from: origin, bearing: 0, meters: 160)
        // Centroids sit 300 m apart; entrances 10 m apart — the entrance distance must decide.
        XCTAssertEqual(PlacesService.shared.collapseSameName([a, b]).map(\.id), ["a"])
    }

    // Pipeline order: collapse runs on cone-gated results, so an out-of-cone twin can never evict the aimed listing.
    func testCollapseRunsAfterConeGating() {
        let aimed = place("Corner Cafe", id: "aimed", bearing: 10, meters: 100,
                          category: .cafe, rating: 3.9, reviews: 12)
        let twin = place("Corner Cafe", id: "twin", bearing: 60, meters: 90,
                         category: .cafe, rating: 4.8, reviews: 900)
        let curated = PlacesService.shared.collapseSameName(scored([aimed, twin]).map { $0.place })
        XCTAssertEqual(curated.map(\.id), ["aimed"])
    }

    // Documented intent: the collapse input is cone-score-ordered, so aim beats review count for in-cone twins.
    func testBetterAimedTwinWinsTheCollapseRegardlessOfReviews() {
        let aimed = place("Twin Peaks Coffee", id: "aimed", bearing: 2, meters: 60,
                          category: .cafe, rating: 3.8, reviews: 8)
        let offAxis = place("Twin Peaks Coffee", id: "offaxis", bearing: 25, meters: 90,
                            category: .cafe, rating: 4.9, reviews: 1200)
        // Deliberately fed worst-first to prove the scoring pass reorders before the collapse.
        let curated = PlacesService.shared.collapseSameName(scored([offAxis, aimed]).map { $0.place })
        XCTAssertEqual(curated.map(\.id), ["aimed"])
    }

    // "Keep the reviewed listing" happens via the quality gate: the unrated twin dies before collapse can prefer it.
    func testAmbientQualityGateDropsTheUnratedTwinBeforeCollapse() {
        let reviewed = place("Corner Shop", id: "reviewed", bearing: 6, meters: 90,
                             category: .shop, rating: 4.4, reviews: 210)
        let unrated = place("Corner Shop", id: "unrated", bearing: 2, meters: 60,
                            category: .shop, rating: 0, reviews: 0)
        let gated = [reviewed, unrated].filter(PlacesService.passesAmbientQuality)
        let curated = PlacesService.shared.collapseSameName(scored(gated).map { $0.place })
        // The unrated twin aimed and ranked better, but never survived the gate.
        XCTAssertEqual(curated.map(\.id), ["reviewed"])
    }

    func testAmbientQualityGateTable() {
        let rows: [(category: PlaceCategory, rating: Double, reviews: Int, passes: Bool, label: String)] = [
            (.shop, 0, 0, false, "unrated shop is noise"),
            (.shop, 5.0, 0, false, "a rating without reviews is unearned"),
            (.shop, 3.4, 40, false, "below the 3.5 floor"),
            (.shop, 3.5, 1, true, "the floor itself passes"),
            (.grocery, 0, 0, false, "unrated grocery"),
            (.other, 3.2, 500, false, "well-reviewed junk category still fails"),
            (.other, 4.0, 3, true, "decent generic place passes"),
            (.restaurant, 0, 0, true, "gate is retail-only: restaurants exempt"),
            (.landmark, 0, 0, true, "landmarks exempt"),
            (.transit, 0, 0, true, "transit exempt"),
        ]
        for row in rows {
            let probe = place("Probe", id: "probe", bearing: 0, meters: 50,
                              category: row.category, rating: row.rating, reviews: row.reviews)
            XCTAssertEqual(PlacesService.passesAmbientQuality(probe), row.passes, row.label)
        }
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
