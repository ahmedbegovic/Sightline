import XCTest
import CoreLocation
@testable import Sightline

final class StreetViewTests: XCTestCase {

    private let coordinate = CLLocationCoordinate2D(latitude: 43.6426, longitude: -79.3871)

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    // Fresh actor per call site = empty verdict cache.
    private func makeService() -> StreetViewVisibilityService {
        StreetViewVisibilityService(session: StubURLProtocol.makeSession())
    }

    func testMetadataStatusMapsToTriStateVerdict() async {
        // Expected nil means the id must be absent from the returned dictionary, never a cached answer.
        let rows: [(label: String, exchange: StubExchange, expected: Bool?)] = [
            ("OK", StubExchange(status: 200, body: StreetViewFixtures.metadata(status: "OK")), false),
            ("ZERO_RESULTS", StubExchange(status: 200, body: StreetViewFixtures.metadata(status: "ZERO_RESULTS")), true),
            ("REQUEST_DENIED", StubExchange(status: 200, body: StreetViewFixtures.metadata(status: "REQUEST_DENIED")), nil),
            ("OVER_QUERY_LIMIT", StubExchange(status: 200, body: StreetViewFixtures.metadata(status: "OVER_QUERY_LIMIT")), nil),
            ("missing status", StubExchange(status: 200, body: StreetViewFixtures.metadata(status: nil)), nil),
            ("HTTP 500", StubExchange(status: 500, body: StreetViewFixtures.metadata(status: "OK")), nil),
            ("undecodable body", StubExchange(status: 200, body: Data("<html>".utf8)), nil),
            ("transport error", StubExchange(error: URLError(.notConnectedToInternet)), nil),
        ]
        for row in rows {
            StubURLProtocol.reset()
            StubURLProtocol.enqueue(row.exchange)
            let service = makeService()
            let verdicts = await service.verdicts(for: [StreetViewProbe(id: "p1", coordinate: coordinate)])
            XCTAssertEqual(verdicts["p1"], row.expected, row.label)
            XCTAssertEqual(StubURLProtocol.requestCount, 1, row.label)
        }
    }

    func testErrorVerdictIsNotCachedAndReprobes() async {
        let service = makeService()
        let probe = StreetViewProbe(id: "p1", coordinate: coordinate)

        StubURLProtocol.enqueue(status: 200, body: StreetViewFixtures.metadata(status: "REQUEST_DENIED"))
        let first = await service.verdicts(for: [probe])
        XCTAssertNil(first["p1"])

        // The error must not stick: the next scan issues a fresh request and can land a real verdict.
        StubURLProtocol.enqueue(status: 200, body: StreetViewFixtures.metadata(status: "OK"))
        let second = await service.verdicts(for: [probe])
        XCTAssertEqual(second["p1"], false)
        XCTAssertEqual(StubURLProtocol.requestCount, 2)
    }

    func testRealVerdictIsCachedAcrossCalls() async {
        let service = makeService()
        let probe = StreetViewProbe(id: "p1", coordinate: coordinate)

        StubURLProtocol.enqueue(status: 200, body: StreetViewFixtures.metadata(status: "ZERO_RESULTS"))
        let first = await service.verdicts(for: [probe])
        XCTAssertEqual(first["p1"], true)

        // Nothing queued: a second network probe would fail its load and the verdict would go missing.
        let second = await service.verdicts(for: [probe])
        XCTAssertEqual(second["p1"], true)
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }

    func testBatchOfProbesResolvesEveryId() async {
        let service = makeService()
        let probes = (1...3).map {
            StreetViewProbe(id: "p\($0)",
                            coordinate: CLLocationCoordinate2D(latitude: 43.64 + Double($0) * 0.001,
                                                               longitude: -79.38))
        }
        // Identical responses keep the assertion independent of concurrent request ordering.
        for _ in probes {
            StubURLProtocol.enqueue(status: 200, body: StreetViewFixtures.metadata(status: "ZERO_RESULTS"))
        }
        let verdicts = await service.verdicts(for: probes)
        XCTAssertEqual(verdicts, ["p1": true, "p2": true, "p3": true])
        XCTAssertEqual(StubURLProtocol.requestCount, 3)
    }
}
