import Foundation

// Shared network stubbing for every suite: install via StubURLProtocol.makeSession(), reset() in setUp.

/// One canned HTTP exchange; a non-nil error wins over status/body.
struct StubExchange {
    var status: Int = 200
    var headers: [String: String] = [:]
    var body: Data = Data()
    var error: Error? = nil
}

final class StubURLProtocol: URLProtocol {

    // State is static because URLSession instantiates the protocol itself; the lock covers loader-thread access.
    private static let lock = NSLock()
    private static var queue: [StubExchange] = []
    private static var log: [String] = []

    /// Session whose every request this stub serves — tests must never reach the real network.
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        queue = []
        log = []
    }

    static func enqueue(_ exchange: StubExchange) {
        lock.lock(); defer { lock.unlock() }
        queue.append(exchange)
    }

    static func enqueue(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        enqueue(StubExchange(status: status, headers: headers, body: body))
    }

    static func enqueue(error: Error) {
        enqueue(StubExchange(error: error))
    }

    static var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return log.count
    }

    /// Method + URL per served request, secret query values redacted so a failure message can never leak a key.
    static var recordedRequests: [String] {
        lock.lock(); defer { lock.unlock() }
        return log
    }

    private static func consume(_ request: URLRequest) -> StubExchange? {
        lock.lock(); defer { lock.unlock() }
        log.append("\(request.httpMethod ?? "GET") \(sanitize(request.url))")
        return queue.isEmpty ? nil : queue.removeFirst()
    }

    private static func sanitize(_ url: URL?) -> String {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "?" }
        components.queryItems = components.queryItems?.map {
            $0.name.lowercased() == "key" ? URLQueryItem(name: $0.name, value: "REDACTED") : $0
        }
        return components.string ?? "?"
    }

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let exchange = Self.consume(request) else {
            // Running the queue dry is a test bug; failing the load beats silently hitting the network.
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        if let error = exchange.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: exchange.status,
                                             httpVersion: "HTTP/1.1", headerFields: exchange.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !exchange.body.isEmpty {
            client?.urlProtocol(self, didLoad: exchange.body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Places API (New) fixtures

enum PlacesFixtures {

    /// The details lookup is a one-result Text Search, so the place sits inside a "places" envelope.
    static func detailsBody(id: String,
                            latitude: Double = 43.6533,
                            longitude: Double = -79.3831,
                            rating: Double? = nil,
                            userRatingCount: Int? = nil,
                            formattedAddress: String? = nil,
                            phone: String? = nil,
                            websiteUri: String? = nil,
                            priceLevel: String? = nil,
                            openNow: Bool? = nil,
                            photoName: String? = nil,
                            reviews: [[String: Any]] = []) -> Data {
        var payload: [String: Any] = ["id": id, "location": ["latitude": latitude, "longitude": longitude]]
        if let rating { payload["rating"] = rating }
        if let userRatingCount { payload["userRatingCount"] = userRatingCount }
        if let formattedAddress { payload["formattedAddress"] = formattedAddress }
        if let phone { payload["nationalPhoneNumber"] = phone }
        if let websiteUri { payload["websiteUri"] = websiteUri }
        if let priceLevel { payload["priceLevel"] = priceLevel }
        if let openNow { payload["currentOpeningHours"] = ["openNow": openNow] }
        if let photoName { payload["photos"] = [["name": photoName]] }
        if !reviews.isEmpty { payload["reviews"] = reviews }
        return try! JSONSerialization.data(withJSONObject: ["places": [payload]])
    }

    static func review(rating: Double? = nil, text: String? = nil, author: String? = nil) -> [String: Any] {
        var review: [String: Any] = [:]
        if let rating { review["rating"] = rating }
        if let text { review["text"] = ["text": text] }
        if let author { review["authorAttribution"] = ["displayName": author] }
        return review
    }

    static func errorBody(message: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["error": ["message": message, "status": "ERROR"]])
    }
}
