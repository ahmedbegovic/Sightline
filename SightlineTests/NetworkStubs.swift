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

    /// One search-result entry; omitted parameters omit the field entirely, `extra` overrides/adds raw keys.
    static func entry(id: String? = nil,
                      name: String? = nil,
                      latitude: Double? = nil,
                      longitude: Double? = nil,
                      primaryType: String? = nil,
                      types: [String]? = nil,
                      rating: Double? = nil,
                      userRatingCount: Int? = nil,
                      businessStatus: String? = nil,
                      pureServiceAreaBusiness: Bool? = nil,
                      extra: [String: Any] = [:]) -> [String: Any] {
        var entry: [String: Any] = [:]
        if let id { entry["id"] = id }
        if let name { entry["displayName"] = ["text": name, "languageCode": "en"] }
        if let latitude, let longitude {
            entry["location"] = ["latitude": latitude, "longitude": longitude]
        }
        if let primaryType { entry["primaryType"] = primaryType }
        if let types { entry["types"] = types }
        if let rating { entry["rating"] = rating }
        if let userRatingCount { entry["userRatingCount"] = userRatingCount }
        if let businessStatus { entry["businessStatus"] = businessStatus }
        if let pureServiceAreaBusiness { entry["pureServiceAreaBusiness"] = pureServiceAreaBusiness }
        for (key, value) in extra { entry[key] = value }
        return entry
    }

    static func searchEnvelope(_ entries: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["places": entries])
    }

    /// The details GET returns one bare place object, not an envelope.
    static func detailsBody(id: String,
                            formattedAddress: String? = nil,
                            phone: String? = nil,
                            websiteUri: String? = nil,
                            priceLevel: String? = nil,
                            openNow: Bool? = nil,
                            servesVegetarian: Bool? = nil,
                            photoName: String? = nil,
                            reviews: [[String: Any]] = []) -> Data {
        var payload: [String: Any] = ["id": id]
        if let formattedAddress { payload["formattedAddress"] = formattedAddress }
        if let phone { payload["nationalPhoneNumber"] = phone }
        if let websiteUri { payload["websiteUri"] = websiteUri }
        if let priceLevel { payload["priceLevel"] = priceLevel }
        if let openNow { payload["currentOpeningHours"] = ["openNow": openNow] }
        if let servesVegetarian { payload["servesVegetarianFood"] = servesVegetarian }
        if let photoName { payload["photos"] = [["name": photoName]] }
        if !reviews.isEmpty { payload["reviews"] = reviews }
        return try! JSONSerialization.data(withJSONObject: payload)
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

// MARK: - Street View metadata fixtures

enum StreetViewFixtures {

    /// nil status yields a body without a "status" key (the decode-to-nil path).
    static func metadata(status: String?) -> Data {
        var payload: [String: Any] = ["copyright": "(c) Google"]
        if let status { payload["status"] = status }
        return try! JSONSerialization.data(withJSONObject: payload)
    }
}

// MARK: - Gemini SSE fixtures

enum GeminiFixtures {

    /// SSE stream body: one data: line per text chunk, grounding metadata on the flagged chunk, [DONE] terminator.
    static func sse(texts: [String], groundedAt: Int? = nil) -> Data {
        var lines: [String] = []
        for (index, text) in texts.enumerated() {
            var candidate: [String: Any] = ["content": ["parts": [["text": text]]]]
            if index == groundedAt {
                candidate["groundingMetadata"] = ["groundingChunks": [[String: Any]()]]
            }
            let chunk = try! JSONSerialization.data(withJSONObject: ["candidates": [candidate]])
            lines.append("data: " + String(decoding: chunk, as: UTF8.self))
        }
        lines.append("data: [DONE]")
        return Data((lines.joined(separator: "\n\n") + "\n").utf8)
    }

    /// Non-200 Gemini responses are one JSON body, not SSE.
    static func errorBody(message: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["error": ["message": message]])
    }
}
