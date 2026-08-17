import XCTest
import CoreLocation
@testable import Sightline

final class PlacesNetworkTests: XCTestCase {

    private var service: GooglePlacesService!
    private let center = CLLocationCoordinate2D(latitude: 43.6532, longitude: -79.3832)

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        // Fresh instance per test: the details cache and stub session must not bleed across tests.
        service = GooglePlacesService(session: StubURLProtocol.makeSession())
    }

    // MARK: - Search decoding

    func testNearbySearchDecodesRealisticPayloadDefensively() async throws {
        let payload = PlacesFixtures.searchEnvelope([
            PlacesFixtures.entry(id: "ChIJcafe0001", name: "Blue Door Cafe",
                                 latitude: 43.6533, longitude: -79.3831,
                                 primaryType: "cafe", types: ["cafe", "coffee_shop", "point_of_interest"],
                                 rating: 4.6, userRatingCount: 213, businessStatus: "OPERATIONAL"),
            // Permanently closed places never surface, however well-formed.
            PlacesFixtures.entry(id: "ChIJgone0002", name: "Vanished Diner",
                                 latitude: 43.6535, longitude: -79.3833,
                                 primaryType: "restaurant", rating: 4.9, userRatingCount: 800,
                                 businessStatus: "CLOSED_PERMANENTLY"),
            // A malformed location shape drops only this entry, not the whole response.
            PlacesFixtures.entry(id: "ChIJbroken03", name: "Broken Row", primaryType: "cafe",
                                 extra: ["location": ["latitude": "junk", "longitude": "junk"]]),
            // Nameless entries cannot become bubbles.
            PlacesFixtures.entry(id: "ChIJnoname04", latitude: 43.6536, longitude: -79.3834,
                                 primaryType: "cafe"),
            // Non-walk-in types stay out of ambient scans.
            PlacesFixtures.entry(id: "ChIJdesk0005", name: "Acme Insurance",
                                 latitude: 43.6537, longitude: -79.3835,
                                 primaryType: "insurance_agency", types: ["insurance_agency"]),
            // Service-area listing: no premises to point a camera at.
            PlacesFixtures.entry(id: "ChIJvan0006", name: "Mobile Groomers",
                                 latitude: 43.6538, longitude: -79.3836,
                                 primaryType: "store", pureServiceAreaBusiness: true),
            // Missing id falls back to the synthesized stable id; missing rating stays zero, UNSPECIFIED status stays neutral.
            PlacesFixtures.entry(name: "Sweet Crumb", latitude: 43.6540, longitude: -79.3840,
                                 primaryType: "bakery", businessStatus: "BUSINESS_STATUS_UNSPECIFIED"),
        ])
        StubURLProtocol.enqueue(status: 200, body: payload)

        let places = try await service.nearbySearch(center: center, radiusMeters: 300, pageSize: 20)

        XCTAssertEqual(places.count, 2)
        XCTAssertEqual(StubURLProtocol.requestCount, 1)

        let cafe = try XCTUnwrap(places.first { $0.name == "Blue Door Cafe" })
        XCTAssertEqual(cafe.id, "ChIJcafe0001")
        XCTAssertEqual(cafe.category, .cafe)
        XCTAssertEqual(cafe.rating, 4.6, accuracy: 0.0001)
        XCTAssertEqual(cafe.reviewCount, 213)
        XCTAssertNil(cafe.details)

        let bakery = try XCTUnwrap(places.first { $0.name == "Sweet Crumb" })
        XCTAssertEqual(bakery.category, .bakery)
        XCTAssertTrue(bakery.id.hasPrefix("sweet crumb|"), bakery.id)
        XCTAssertEqual(bakery.rating, 0)
        XCTAssertEqual(bakery.reviewCount, 0)
    }

    func testBusinessStatusGateHonorsExplicitIntent() async throws {
        let closedTemporarily = PlacesFixtures.entry(id: "ChIJnap0001", name: "Napping Noodles",
                                                     latitude: 43.6532, longitude: -79.3832,
                                                     primaryType: "restaurant",
                                                     businessStatus: "CLOSED_TEMPORARILY")
        // Ambient scan: temporarily closed stays hidden.
        StubURLProtocol.enqueue(status: 200, body: PlacesFixtures.searchEnvelope([closedTemporarily]))
        let ambient = try await service.nearbySearch(center: center, radiusMeters: 300, pageSize: 10)
        XCTAssertTrue(ambient.isEmpty)

        // Explicit user search by name: temporarily closed comes back.
        StubURLProtocol.enqueue(status: 200, body: PlacesFixtures.searchEnvelope([closedTemporarily]))
        let searched = try await service.textSearch(query: "napping noodles", center: center,
                                                    radiusMeters: 1000, pageSize: 10, explicitIntent: true)
        XCTAssertEqual(searched.map(\.name), ["Napping Noodles"])
    }

    // MARK: - Retry policy

    func testSearchRetriesExactlyOnceOn429ThenSucceeds() async throws {
        StubURLProtocol.enqueue(status: 429, headers: ["Retry-After": "1"],
                                body: PlacesFixtures.errorBody(message: "Quota momentarily exceeded"))
        StubURLProtocol.enqueue(status: 200, body: PlacesFixtures.searchEnvelope([
            PlacesFixtures.entry(id: "ChIJok00001", name: "Second Try Tacos",
                                 latitude: 43.6532, longitude: -79.3832, primaryType: "restaurant"),
        ]))

        let places = try await service.textSearch(query: "tacos", center: center,
                                                  radiusMeters: 500, pageSize: 5)
        XCTAssertEqual(places.map(\.name), ["Second Try Tacos"])
        XCTAssertEqual(StubURLProtocol.requestCount, 2)
    }

    func testAccessDeniedThrowsWithoutRetry() async {
        StubURLProtocol.enqueue(status: 403, body: PlacesFixtures.errorBody(message: "Caller not permitted"))
        do {
            _ = try await service.textSearch(query: "atm", center: center, radiusMeters: 500, pageSize: 5)
            XCTFail("403 must throw")
        } catch let error as GooglePlacesService.RequestError {
            guard case .accessDenied(let status, let message) = error else {
                XCTFail("expected accessDenied, got \(error)")
                return
            }
            XCTAssertEqual(status, 403)
            XCTAssertEqual(message, "Caller not permitted")
        } catch {
            XCTFail("expected RequestError, got \(error)")
        }
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }

    func testSecondTransientFailureStopsRetrying() async {
        StubURLProtocol.enqueue(status: 503, headers: ["Retry-After": "0.1"], body: Data())
        StubURLProtocol.enqueue(status: 503, headers: ["Retry-After": "0.1"], body: Data())
        do {
            _ = try await service.textSearch(query: "cafe", center: center, radiusMeters: 500, pageSize: 5)
            XCTFail("second 503 must throw")
        } catch let error as GooglePlacesService.RequestError {
            guard case .serverError(let status, _) = error else {
                XCTFail("expected serverError, got \(error)")
                return
            }
            XCTAssertEqual(status, 503)
        } catch {
            XCTFail("expected RequestError, got \(error)")
        }
        XCTAssertEqual(StubURLProtocol.requestCount, 2)
    }

    // MARK: - Pure helpers

    func testRequestErrorClassification() {
        let cases: [(status: Int, expected: String)] = [
            (401, "accessDenied"), (403, "accessDenied"),
            (429, "rateLimited"),
            (500, "serverError"), (503, "serverError"), (599, "serverError"),
            (400, "badRequest"), (404, "badRequest"), (418, "badRequest"),
        ]
        for row in cases {
            let label: String
            switch GooglePlacesService.requestError(status: row.status, message: nil) {
            case .accessDenied: label = "accessDenied"
            case .rateLimited: label = "rateLimited"
            case .serverError: label = "serverError"
            case .badRequest: label = "badRequest"
            }
            XCTAssertEqual(label, row.expected, "status \(row.status)")
        }
    }

    func testRetryAfterClampWithoutSleeping() throws {
        // (Retry-After header, expected nanoseconds): the clamp keeps every wait inside 0.5-4 s.
        let cases: [(hint: String?, expected: UInt64)] = [
            (nil, 1_000_000_000),
            ("0.1", 500_000_000),
            ("2", 2_000_000_000),
            ("10", 4_000_000_000),
            ("soon", 1_000_000_000),
            // Double.init parses these as non-finite; without the finiteness guard NaN rides through the clamp and UInt64(NaN) traps.
            ("nan", 1_000_000_000),
            ("NaN", 1_000_000_000),
            ("inf", 1_000_000_000),
            ("-inf", 1_000_000_000),
            ("-3", 500_000_000),
        ]
        for row in cases {
            var headers: [String: String] = [:]
            if let hint = row.hint { headers["Retry-After"] = hint }
            let http = try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://stub.test")!,
                                                     statusCode: 429, httpVersion: "HTTP/1.1",
                                                     headerFields: headers))
            XCTAssertEqual(GooglePlacesService.retryDelayNanos(http), row.expected,
                           "hint \(row.hint ?? "nil")")
        }
    }

    // MARK: - Place details

    func testPlaceDetailsAttachesRichFieldsOn200() async throws {
        StubURLProtocol.enqueue(status: 200, body: PlacesFixtures.detailsBody(
            id: "ChIJdetails01",
            formattedAddress: "12 Queen St W, Toronto, ON M5H 2M9, Canada",
            phone: "(416) 555-0142",
            websiteUri: "https://bluedoor.example/menu",
            priceLevel: "PRICE_LEVEL_MODERATE",
            openNow: true,
            servesVegetarian: true,
            photoName: "places/ChIJdetails01/photos/p1",
            reviews: [
                PlacesFixtures.review(rating: 5, text: "Great coffee.", author: "Ava"),
                PlacesFixtures.review(rating: 4, text: "", author: "Bo"),
                PlacesFixtures.review(rating: 3.4, text: "Fine."),
            ]))

        let details = try await service.placeDetails(id: "ChIJdetails01")

        // Address keeps only the first two comma parts.
        XCTAssertEqual(details.address, "12 Queen St W, Toronto")
        XCTAssertEqual(details.phone, "(416) 555-0142")
        XCTAssertEqual(details.url?.host(), "bluedoor.example")
        XCTAssertEqual(details.priceLevel, 2)
        XCTAssertEqual(details.isOpenNow, true)
        XCTAssertEqual(details.servesVegetarian, true)
        XCTAssertEqual(details.photoResource, "places/ChIJdetails01/photos/p1")

        // Empty review text drops that entry only; review ids key off the place id and payload index.
        XCTAssertEqual(details.reviews.count, 2)
        XCTAssertEqual(details.reviews.first?.id, "ChIJdetails01#g0")
        XCTAssertEqual(details.reviews.first?.author, "Ava")
        XCTAssertEqual(details.reviews.first?.stars, 5)
        XCTAssertEqual(details.reviews.last?.id, "ChIJdetails01#g2")
        XCTAssertEqual(details.reviews.last?.author, "Google user")
        XCTAssertEqual(details.reviews.last?.stars, 3)

        // Rich state attaches via place.details; flat pass-throughs must follow.
        var place = Place(id: "ChIJdetails01", name: "Blue Door Cafe", category: .cafe,
                          coordinate: CLLocationCoordinate2D(latitude: 43.6533, longitude: -79.3831))
        place.details = details
        XCTAssertEqual(place.phone, "(416) 555-0142")
        XCTAssertEqual(place.isOpenNow, true)
        XCTAssertEqual(place.priceLabel, "$$")
    }

    func testPlaceDetailsSynthesizedIdFailsLocallyWithoutRequest() async {
        do {
            _ = try await service.placeDetails(id: "sweet crumb|43.654|-79.384")
            XCTFail("synthesized ids must fail locally")
        } catch {
            XCTAssertTrue(error is GooglePlacesService.APIError, "\(error)")
        }
        XCTAssertEqual(StubURLProtocol.requestCount, 0)
    }

    func testPlaceDetailsSecondCallServedFromCache() async throws {
        StubURLProtocol.enqueue(status: 200, body: PlacesFixtures.detailsBody(id: "ChIJcache01",
                                                                              phone: "(416) 555-0100"))
        let first = try await service.placeDetails(id: "ChIJcache01")
        // Nothing else queued: a second network hit would fail the load, so success proves the cache answered.
        let second = try await service.placeDetails(id: "ChIJcache01")
        XCTAssertEqual(first, second)
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }

    func testFailedDetailsFetchLeavesDiscoveryDataIntactAndIsNotCached() async throws {
        var place = Place(id: "ChIJfail001", name: "Corner Books", category: .shop,
                          coordinate: center)
        place.rating = 4.2
        place.reviewCount = 57

        // 404 is not transient, so there is exactly one request and no retry sleep.
        StubURLProtocol.enqueue(status: 404, body: PlacesFixtures.errorBody(message: "Place not found"))
        do {
            place.details = try await service.placeDetails(id: place.id)
            XCTFail("404 must throw")
        } catch {}

        XCTAssertNil(place.details)
        XCTAssertEqual(place.rating, 4.2)
        XCTAssertEqual(place.reviewCount, 57)
        XCTAssertEqual(place.reviews, [])
        XCTAssertNil(place.isOpenNow)
        XCTAssertEqual(StubURLProtocol.requestCount, 1)

        // Failures are never cached: the next open retries and can land.
        StubURLProtocol.enqueue(status: 200, body: PlacesFixtures.detailsBody(id: "ChIJfail001",
                                                                              openNow: false))
        place.details = try await service.placeDetails(id: place.id)
        XCTAssertEqual(place.isOpenNow, false)
        XCTAssertEqual(StubURLProtocol.requestCount, 2)
    }
}
