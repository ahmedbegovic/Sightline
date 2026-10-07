import Foundation
import CoreLocation

/// Google Places API (New), used only when a card or the guide opens: ratings, reviews, hours, photo.
/// Discovery is MapKit + the camera, so a scan never costs a Google call.
final class GooglePlacesService {

    static let shared = GooglePlacesService()

    struct APIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// HTTP failure classes, thrown only after the single retry; message is Google's own text when present.
    enum RequestError: LocalizedError {
        case accessDenied(status: Int, message: String?)
        case rateLimited(status: Int, message: String?)
        case serverError(status: Int, message: String?)
        case badRequest(status: Int, message: String?)

        var errorDescription: String? {
            switch self {
            case .accessDenied(let status, let message),
                 .rateLimited(let status, let message),
                 .serverError(let status, let message),
                 .badRequest(let status, let message):
                return message ?? "Places API error \(status)"
            }
        }
    }

    /// A Google listing further than this from the MapKit position is a different place with the same name.
    static let maxMatchDistanceMeters: CLLocationDistance = 1_000

    private let session: URLSession
    private let photoCache = NSCache<NSString, NSData>()
    private let detailsStore = DetailsStore()

    // Injectable session is a test seam only; production always uses the configured default.
    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 8
            config.timeoutIntervalForResource = 15
            self.session = URLSession(configuration: config)
        }
        photoCache.totalCostLimit = 24 * 1024 * 1024
    }

    // MARK: - Public API

    /// One Text Search call with the rich field mask: finds the listing by name near the coordinate and returns its fields. Cached per place id.
    func details(for place: Place) async throws -> PlaceDetails {
        guard place.isLocated else { throw APIError(message: "No position to match a listing against") }
        let request = try detailsRequest(name: place.name, near: place.coordinate)
        let session = self.session
        let coordinate = place.coordinate
        return try await detailsStore.details(for: place.id) {
            try await Self.fetchDetails(request: request, session: session, near: coordinate)
        }
    }

    /// Fetches (and caches) photo bytes; the media endpoint needs the key + bundle-id headers, so `AsyncImage` with a plain URL cannot be used.
    func photoData(resource: String, maxWidthPx: Int) async throws -> Data {
        let cacheKey = "\(resource)#\(maxWidthPx)" as NSString
        if let cached = photoCache.object(forKey: cacheKey) { return cached as Data }

        var components = URLComponents(string: "https://places.googleapis.com/v1/\(resource)/media")!
        components.queryItems = [URLQueryItem(name: "maxWidthPx", value: String(maxWidthPx))]
        guard let url = components.url else { throw APIError(message: "Bad photo resource") }

        var request = URLRequest(url: url)
        request.setValue(Secrets.googleAPIKey, forHTTPHeaderField: "X-Goog-Api-Key")
        request.setValue(Self.bundleID, forHTTPHeaderField: "X-Ios-Bundle-Identifier")

        let data = try await Self.send(request, session: session)
        guard !data.isEmpty else { throw APIError(message: "Photo fetch failed") }
        photoCache.setObject(data as NSData, forKey: cacheKey, cost: data.count)
        return data
    }

    // MARK: - Request plumbing

    private static let bundleID = Bundle.main.bundleIdentifier ?? "com.ahmedbegovic.Sightline"

    /// The API wants a bare language code ("de"), not a full locale identifier ("de_DE").
    private static let languageCode = Locale.current.language.languageCode?.identifier ?? "en"

    /// reviews bill this call at Enterprise + Atmosphere, which is why it runs per tapped place, never per scan.
    private static let detailFieldMask = [
        "places.id", "places.location", "places.rating", "places.userRatingCount",
        "places.formattedAddress", "places.nationalPhoneNumber", "places.websiteUri", "places.priceLevel",
        "places.currentOpeningHours.openNow", "places.reviews", "places.photos",
    ].joined(separator: ",")

    private func detailsRequest(name: String, near coordinate: CLLocationCoordinate2D) throws -> URLRequest {
        guard let url = URL(string: "https://places.googleapis.com/v1/places:searchText") else {
            throw APIError(message: "Bad endpoint")
        }
        let body: [String: Any] = [
            "textQuery": name,
            "pageSize": 1,
            "languageCode": Self.languageCode,
            "locationBias": ["circle": [
                "center": ["latitude": coordinate.latitude, "longitude": coordinate.longitude],
                "radius": 500,
            ]],
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Secrets.googleAPIKey, forHTTPHeaderField: "X-Goog-Api-Key")
        request.setValue(Self.bundleID, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        request.setValue(Self.detailFieldMask, forHTTPHeaderField: "X-Goog-FieldMask")
        return request
    }

    /// Static (no self capture) so the store's @Sendable fetch closure only carries Sendable state.
    private static func fetchDetails(request: URLRequest, session: URLSession,
                                     near coordinate: CLLocationCoordinate2D) async throws -> PlaceDetails {
        let data = try await send(request, session: session)
        let envelope = try JSONDecoder().decode(SearchEnvelope.self, from: data)
        guard let match = envelope.places?.first,
              let lat = match.location?.latitude, let lon = match.location?.longitude,
              ARProjector.distanceMeters(from: coordinate, to: CLLocationCoordinate2D(latitude: lat, longitude: lon))
                <= maxMatchDistanceMeters
        else { throw APIError(message: "No matching Google listing") }
        return details(from: match, id: match.id ?? "g")
    }

    /// One retry for transient classes only (429/5xx); auth and shape errors will not heal on their own.
    private static func send(_ request: URLRequest, session: URLSession) async throws -> Data {
        var retried = false
        while true {
            try Task.checkCancellation()
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw APIError(message: "No response from Places API")
            }
            if http.statusCode == 200 { return data }
            let transient = http.statusCode == 429 || (500...599).contains(http.statusCode)
            if transient, !retried {
                retried = true
                try await Task.sleep(nanoseconds: retryDelayNanos(http))
                continue
            }
            let message = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error.message
            throw requestError(status: http.statusCode, message: message)
        }
    }

    /// Honors Retry-After when Google sends one, clamped so a card still fills inside the UI's patience window.
    // Internal (not private) so the clamp is unit-testable without real sleeps.
    static func retryDelayNanos(_ http: HTTPURLResponse) -> UInt64 {
        let hinted = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
        // Double.init accepts "nan"/"inf", min/max propagate NaN, and UInt64(NaN) traps — a non-finite hint must fall back to the default before the clamp.
        let base = (hinted?.isFinite == true) ? hinted! : 1
        let seconds = min(max(base, 0.5), 4)
        return UInt64(seconds * 1_000_000_000)
    }

    // Internal (not private) so the status-to-case mapping is unit-testable as a pure function.
    static func requestError(status: Int, message: String?) -> RequestError {
        switch status {
        case 401, 403: return .accessDenied(status: status, message: message)
        case 429: return .rateLimited(status: status, message: message)
        case 500...599: return .serverError(status: status, message: message)
        default: return .badRequest(status: status, message: message)
        }
    }

    // MARK: - Details plumbing

    /// Per-id cache with in-flight dedupe. The fetch task is unstructured on purpose: a dismissed card cancelling its await must not kill the request for another awaiter.
    private actor DetailsStore {
        private var cached: [String: PlaceDetails] = [:]
        private var inFlight: [String: Task<PlaceDetails, Error>] = [:]

        func details(for id: String,
                     fetch: @escaping @Sendable () async throws -> PlaceDetails) async throws -> PlaceDetails {
            if let hit = cached[id] { return hit }
            if let running = inFlight[id] { return try await running.value }
            let task = Task { try await fetch() }
            inFlight[id] = task
            do {
                let details = try await task.value
                cached[id] = details
                inFlight[id] = nil
                return details
            } catch {
                // Failures are never cached — the next card or guide open retries.
                inFlight[id] = nil
                throw error
            }
        }
    }

    // MARK: - Response mapping

    /// Review ids key off the Google id so identity stays stable across refetches.
    private static func details(from g: GPlace, id: String) -> PlaceDetails {
        var details = PlaceDetails()
        details.rating = g.rating ?? 0
        details.reviewCount = g.userRatingCount ?? 0
        details.address = shortAddress(from: g.formattedAddress)
        details.phone = g.nationalPhoneNumber
        details.url = g.websiteUri.flatMap(URL.init(string:))
        details.priceLevel = priceLevel(from: g.priceLevel)
        details.isOpenNow = g.currentOpeningHours?.openNow
        details.photoResource = g.photos?.first?.name
        details.reviews = (g.reviews ?? []).prefix(3).enumerated().compactMap { index, review in
            guard let text = review.text?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            let clipped = text.count > 220
                ? String(text.prefix(220)).trimmingCharacters(in: .whitespaces) + "…"
                : text
            return Review(id: "\(id)#g\(index)",
                          author: review.authorAttribution?.displayName ?? "Google user",
                          stars: min(5, max(1, Int((review.rating ?? 5).rounded()))),
                          text: clipped)
        }
        return details
    }

    // 0 = unknown/free; never invent a price.
    private static func priceLevel(from raw: String?) -> Int {
        switch raw {
        case "PRICE_LEVEL_INEXPENSIVE": return 1
        case "PRICE_LEVEL_MODERATE": return 2
        case "PRICE_LEVEL_EXPENSIVE": return 3
        case "PRICE_LEVEL_VERY_EXPENSIVE": return 4
        default: return 0
        }
    }

    private static func shortAddress(from formatted: String?) -> String? {
        guard let formatted else { return nil }
        let parts = formatted.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty else { return nil }
        return parts.prefix(2).joined(separator: ", ")
    }

    // MARK: - DTOs

    private struct SearchEnvelope: Decodable { let places: [GPlace]? }

    private struct ErrorEnvelope: Decodable {
        struct Payload: Decodable { let message: String }
        let error: Payload
    }

    private struct GPlace: Decodable {
        struct LocalizedText: Decodable { let text: String? }
        struct LatLng: Decodable { let latitude: Double?; let longitude: Double? }
        struct Hours: Decodable { let openNow: Bool? }
        struct Photo: Decodable { let name: String? }
        struct GReview: Decodable {
            struct Attribution: Decodable { let displayName: String? }
            let rating: Double?
            let text: LocalizedText?
            let authorAttribution: Attribution?
        }

        let id: String?
        let location: LatLng?
        let formattedAddress: String?
        let rating: Double?
        let userRatingCount: Int?
        let priceLevel: String?
        let nationalPhoneNumber: String?
        let websiteUri: String?
        let currentOpeningHours: Hours?
        let reviews: [GReview]?
        let photos: [Photo]?
    }
}
