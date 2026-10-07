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

    private func place(_ id: String = "apple-id-1", name: String = "Blue Door Cafe") -> Place {
        Place(id: id, name: name, category: .cafe, coordinate: center)
    }

    // MARK: - Retry policy

    func testDetailsRetriesExactlyOnceOn429ThenSucceeds() async throws {
        StubURLProtocol.enqueue(status: 429, headers: ["Retry-After": "1"],
                                body: PlacesFixtures.errorBody(message: "Quota momentarily exceeded"))
        StubURLProtocol.enqueue(status: 200, body: PlacesFixtures.detailsBody(id: "ChIJok00001", rating: 4.4))

        let details = try await service.details(for: place())
        XCTAssertEqual(details.rating, 4.4, accuracy: 0.0001)
        XCTAssertEqual(StubURLProtocol.requestCount, 2)
    }

    func testAccessDeniedThrowsWithoutRetry() async {
        StubURLProtocol.enqueue(status: 403, body: PlacesFixtures.errorBody(message: "Caller not permitted"))
        do {
            _ = try await service.details(for: place())
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
            _ = try await service.details(for: place())
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

    func testDetailsMapsRichFieldsOn200() async throws {
        StubURLProtocol.enqueue(status: 200, body: PlacesFixtures.detailsBody(
            id: "ChIJdetails01",
            rating: 4.6, userRatingCount: 213,
            formattedAddress: "12 Queen St W, Toronto, ON M5H 2M9, Canada",
            phone: "(416) 555-0142",
            websiteUri: "https://bluedoor.example/menu",
            priceLevel: "PRICE_LEVEL_MODERATE",
            openNow: true,
            photoName: "places/ChIJdetails01/photos/p1",
            reviews: [
                PlacesFixtures.review(rating: 5, text: "Great coffee.", author: "Ava"),
                PlacesFixtures.review(rating: 4, text: "", author: "Bo"),
                PlacesFixtures.review(rating: 3.4, text: "Fine."),
            ]))

        let details = try await service.details(for: place())

        XCTAssertEqual(details.rating, 4.6, accuracy: 0.0001)
        XCTAssertEqual(details.reviewCount, 213)
        // Address keeps only the first two comma parts.
        XCTAssertEqual(details.address, "12 Queen St W, Toronto")
        XCTAssertEqual(details.phone, "(416) 555-0142")
        XCTAssertEqual(details.url?.host(), "bluedoor.example")
        XCTAssertEqual(details.priceLevel, 2)
        XCTAssertEqual(details.isOpenNow, true)
        XCTAssertEqual(details.photoResource, "places/ChIJdetails01/photos/p1")

        // Empty review text drops that entry only; review ids key off the Google id and payload index.
        XCTAssertEqual(details.reviews.count, 2)
        XCTAssertEqual(details.reviews.first?.id, "ChIJdetails01#g0")
        XCTAssertEqual(details.reviews.last?.id, "ChIJdetails01#g2")
        XCTAssertEqual(details.reviews.last?.author, "Google user")
        XCTAssertEqual(details.reviews.last?.stars, 3)

        var enriched = place()
        enriched.details = details
        XCTAssertEqual(enriched.rating, 4.6, accuracy: 0.0001)
        XCTAssertEqual(enriched.priceLabel, "$$")
    }

    /// Same name, other side of town: that is a different place, not this one's reviews.
    func testFarAwayNameMatchIsRejected() async {
        StubURLProtocol.enqueue(status: 200, body: PlacesFixtures.detailsBody(
            id: "ChIJfar00001", latitude: 43.70, longitude: -79.40, rating: 4.9))
        do {
            _ = try await service.details(for: place())
            XCTFail("a listing kilometres away must not attach")
        } catch {
            XCTAssertTrue(error is GooglePlacesService.APIError, "\(error)")
        }
    }

    func testUnlocatedSightingNeverCallsGoogle() async {
        var sighting = place()
        sighting.isLocated = false
        do {
            _ = try await service.details(for: sighting)
            XCTFail("an unlocated sighting has nothing to match against")
        } catch {}
        XCTAssertEqual(StubURLProtocol.requestCount, 0)
    }

    func testSecondCallServedFromCacheAndFailuresAreNotCached() async throws {
        StubURLProtocol.enqueue(status: 404, body: PlacesFixtures.errorBody(message: "Not found"))
        do {
            _ = try await service.details(for: place())
            XCTFail("404 must throw")
        } catch {}

        StubURLProtocol.enqueue(status: 200, body: PlacesFixtures.detailsBody(id: "ChIJcache01", phone: "(416) 555-0100"))
        let first = try await service.details(for: place())
        // Nothing else queued: a third network hit would fail, so success proves the cache answered.
        let second = try await service.details(for: place())
        XCTAssertEqual(first, second)
        XCTAssertEqual(StubURLProtocol.requestCount, 2)
    }
}
