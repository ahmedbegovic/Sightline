import XCTest
import CoreLocation
@testable import Sightline

/// The scan's pure matching: what goes in the candidate list, and how model answers become places.
final class SceneMatcherTests: XCTestCase {

    // Union Station, Toronto, facing roughly south-west towards the CN Tower.
    private let user = CLLocationCoordinate2D(latitude: 43.6453, longitude: -79.3806)

    private func frame(heading: Double, pitch: Double = 0, located: Bool = true) -> ScanFrame {
        ScanFrame(image: nil, headingDegrees: heading, pitchDegrees: pitch,
                  location: located ? CLLocation(latitude: user.latitude, longitude: user.longitude) : nil,
                  horizontalFOV: 60)
    }

    private func place(_ name: String, bearing: Double, meters: Double, category: PlaceCategory = .landmark) -> Place {
        Place(id: name, name: name, category: category,
              coordinate: MapKitPlaces.destination(from: user, bearingDegrees: bearing, distanceMeters: meters))
    }

    private var tower: Place { place("CN Tower", bearing: 240, meters: 900) }
    private var stadium: Place { place("Rogers Centre", bearing: 225, meters: 1_100) }
    private var behind: Place { place("St. Lawrence Market", bearing: 90, meters: 700) }

    // MARK: - Candidate list

    /// No radius cap: 5 m or 5 km away, only the direction decides whether it is a candidate.
    func testInViewKeepsEverythingAheadAtAnyDistanceAndDropsWhatIsBehind() {
        let far = place("Far Tower", bearing: 238, meters: 20_000)
        let listed = SceneMatcher.inView([behind, far, stadium, tower], frame: frame(heading: 240), signs: [])
        XCTAssertEqual(listed.map(\.place.name), ["CN Tower", "Far Tower", "Rogers Centre"])
        XCTAssertEqual(listed[0].offset, 0, accuracy: 0.5)
    }

    func testSignMatchesSortFirstAndMayLieWiderOffAxis() {
        let cafe = place("Balzac's Coffee", bearing: 240 + 30 + 25, meters: 40, category: .cafe)
        let listed = SceneMatcher.inView([tower, cafe], frame: frame(heading: 240), signs: ["BALZAC'S COFFEE"])
        XCTAssertEqual(listed.first?.place.name, "Balzac's Coffee")
        XCTAssertTrue(listed.first?.signMatch == true)
    }

    func testNoLocationMeansNoCandidates() {
        XCTAssertTrue(SceneMatcher.inView([tower], frame: frame(heading: 240, located: false), signs: []).isEmpty)
    }

    func testPromptNumbersCandidatesWithDirection() {
        let listed = SceneMatcher.inView([tower, stadium], frame: frame(heading: 240), signs: [])
        let text = SceneMatcher.prompt(frame: frame(heading: 240, pitch: 12), signs: ["UNION"], listed: listed)
        XCTAssertTrue(text.contains("1. CN Tower (Landmark), 900 m away, at the centre"), text)
        XCTAssertTrue(text.contains("2. Rogers Centre"), text)
        XCTAssertTrue(text.contains("left of centre"), text)
        XCTAssertTrue(text.contains("tilted 12° up"), text)
        XCTAssertTrue(text.contains("\"UNION\""), text)
    }

    // MARK: - Resolving model answers

    private func sighted(_ candidate: Int, _ name: String, position: Double = 0.5, confidence: Int = 2) -> SceneMatcher.Sighted {
        .init(candidate: candidate, name: name, category: .landmark, position: position,
              summary: "A tall tower.", confidence: confidence)
    }

    func testCandidateNumberResolvesToTheLocatedPlaceWithASighting() throws {
        let f = frame(heading: 240, pitch: 20)
        let listed = SceneMatcher.inView([tower, stadium], frame: f, signs: [])
        let resolved = SceneMatcher.resolve([sighted(1, "CN Tower", position: 0.75)], listed: listed, frame: f)
        guard case .located(let place) = try XCTUnwrap(resolved.first) else { return XCTFail("expected located") }
        XCTAssertEqual(place.name, "CN Tower")
        // 0.75 across a 60° frame is 15° right of the heading; elevation is the pitch at capture.
        XCTAssertEqual(try XCTUnwrap(place.sighting).bearing, 255, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(place.sighting).elevation, 20, accuracy: 1e-9)
        XCTAssertEqual(place.summary, "A tall tower.")
    }

    /// A bearing only holds near the scan spot: walk away and a located place returns to its map position.
    func testSightingIsReleasedAfterWalkingAwayUnlessUnlocated() throws {
        let f = frame(heading: 240)
        let listed = SceneMatcher.inView([tower], frame: f, signs: [])
        guard case .located(var place)? = SceneMatcher.resolve([sighted(1, "CN Tower")], listed: listed, frame: f).first
        else { return XCTFail("expected located") }
        let here = CLLocation(latitude: user.latitude, longitude: user.longitude)
        let moved = MapKitPlaces.destination(from: user, bearingDegrees: 0, distanceMeters: 40)
        let there = CLLocation(latitude: moved.latitude, longitude: moved.longitude)
        XCTAssertNotNil(place.sighting(at: here))
        XCTAssertNil(place.sighting(at: there))
        place.isLocated = false
        XCTAssertNotNil(place.sighting(at: there))
    }

    /// Small models slip on indices more than on names: a name match wins over a wrong number.
    func testNameBeatsAWrongIndex() {
        let f = frame(heading: 240)
        let listed = SceneMatcher.inView([tower, stadium], frame: f, signs: [])
        let resolved = SceneMatcher.resolve([sighted(1, "Rogers Centre")], listed: listed, frame: f)
        guard case .located(let place)? = resolved.first else { return XCTFail("expected located") }
        XCTAssertEqual(place.name, "Rogers Centre")
    }

    /// Off-list names need high confidence — this is the guard against an invented tower.
    func testOffListNamesNeedHighConfidence() {
        let f = frame(heading: 240)
        let listed = SceneMatcher.inView([tower], frame: f, signs: [])
        XCTAssertTrue(SceneMatcher.resolve([sighted(0, "Mystery Spire", confidence: 1)], listed: listed, frame: f).isEmpty)
        let resolved = SceneMatcher.resolve([sighted(0, "Mystery Spire", confidence: 2)], listed: listed, frame: f)
        guard case .unlocated(let place)? = resolved.first else { return XCTFail("expected unlocated") }
        XCTAssertFalse(place.isLocated)
        XCTAssertNil(place.distance(from: CLLocation(latitude: user.latitude, longitude: user.longitude)))
        XCTAssertNotNil(place.sighting)
    }

    func testLowConfidenceIndexIsIgnored() {
        let f = frame(heading: 240)
        let listed = SceneMatcher.inView([tower], frame: f, signs: [])
        XCTAssertTrue(SceneMatcher.resolve([sighted(1, "", confidence: 0)], listed: listed, frame: f).isEmpty)
    }

    // MARK: - Fallback without a model

    func testFallbackPrefersSignsThenDeadAhead() {
        let f = frame(heading: 240)
        let shop = place("Union Market", bearing: 250, meters: 30, category: .shop)
        let withSign = SceneMatcher.inView([tower, shop], frame: f, signs: ["UNION MARKET"])
        XCTAssertEqual(SceneMatcher.fallback(withSign, frame: f, allowCentered: true).map(\.name), ["Union Market"])

        let noSign = SceneMatcher.inView([tower, stadium], frame: f, signs: [])
        XCTAssertEqual(SceneMatcher.fallback(noSign, frame: f, allowCentered: true).map(\.name), ["CN Tower"])
        // With a vision model that saw nothing, an unseen landmark is never guessed.
        XCTAssertTrue(SceneMatcher.fallback(noSign, frame: f, allowCentered: false).isEmpty)
    }

    // MARK: - Text

    func testNamesMatchIgnoresCaseAccentsAndPunctuationButNotShortFragments() {
        XCTAssertTrue(SceneMatcher.namesMatch("Café Démocratie", "CAFE DEMOCRATIE"))
        XCTAssertTrue(SceneMatcher.namesMatch("Tim Hortons", "TIM HORTONS"))
        XCTAssertTrue(SceneMatcher.namesMatch("CN Tower", "CN Tower / La Tour CN"))
        XCTAssertFalse(SceneMatcher.namesMatch("Bar Raval", "BAR"))
        XCTAssertFalse(SceneMatcher.namesMatch("Rogers Centre", "CN Tower"))
    }

    func testCleanSignsDropsNoiseAndDuplicates() {
        XCTAssertEqual(SceneMatcher.cleanSigns(["  TIM HORTONS ", "Tim Hortons", "12", "→", "OPEN", String(repeating: "x", count: 41)]),
                       ["TIM HORTONS", "OPEN"])
    }
}
