import Foundation
import CoreLocation

/// Thin Google Places API (New) client — the app's only place-data source; every failure throws and surfaces as a scan/search error.
final class GooglePlacesService {

    static let shared = GooglePlacesService()

    struct APIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// HTTP failure classes for search requests, thrown only after the single retry; upstream copy branches on the case, message is Google's own text when present.
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
            // Hard total-duration cap so a trickling connection fails as an honest error instead of hanging the scan.
            config.timeoutIntervalForResource = 15
            self.session = URLSession(configuration: config)
        }
        photoCache.totalCostLimit = 24 * 1024 * 1024
    }

    // MARK: - Public API

    /// Free-text search ("tacos", "ATM") biased to a circle around the user; `explicitIntent` is true only for user-typed queries, not the ambient far-landmark text pass.
    func textSearch(query: String,
                    center: CLLocationCoordinate2D,
                    radiusMeters: Double,
                    pageSize: Int,
                    explicitIntent: Bool = false) async throws -> [Place] {
        let body: [String: Any] = [
            "textQuery": query,
            "locationBias": circle(center, radiusMeters),
            "pageSize": min(max(pageSize, 1), 20),
        ]
        return try await search(path: "places:searchText", body: body, explicitIntent: explicitIntent)
    }

    /// All POIs inside a circle, nearest first (for the scan cone); ambient scans are venue-gated, unlike explicit search.
    func nearbySearch(center: CLLocationCoordinate2D,
                      radiusMeters: Double,
                      pageSize: Int) async throws -> [Place] {
        let body: [String: Any] = [
            "locationRestriction": circle(center, radiusMeters),
            "rankPreference": "DISTANCE",
            "maxResultCount": min(max(pageSize, 1), 20),
        ]
        return try await search(path: "places:searchNearby", body: body, ambientVenuesOnly: true)
    }

    /// Popularity-ranked attractions inside a hard circle (the far-landmark pass); type-gated by Google itself, so the ambient venue gate is bypassed.
    func attractionSearch(center: CLLocationCoordinate2D,
                          radiusMeters: Double,
                          pageSize: Int) async throws -> [Place] {
        let body: [String: Any] = [
            "locationRestriction": circle(center, radiusMeters),
            "includedTypes": Self.attractionTypes,
            "rankPreference": "POPULARITY",
            "maxResultCount": min(max(pageSize, 1), 20),
        ]
        return try await search(path: "places:searchNearby", body: body)
    }

    /// What deserves a long-range bubble: things a person points a camera at. Amusement parks are here because Canada's Wonderland never matched a "famous landmarks" text search (field test 2026-08-16).
    private static let attractionTypes = [
        "tourist_attraction", "amusement_park", "historical_landmark", "monument",
        "cultural_landmark", "observation_deck", "museum", "zoo", "aquarium",
        "planetarium", "stadium", "national_park",
    ]

    /// Rich fields for one place, fetched on first demand and cached per id; on failure the caller keeps showing discovery data.
    func placeDetails(id: String) async throws -> PlaceDetails {
        // Synthesized fallback ids (name|lat|lon) are not Google resource names; fail locally instead of burning a 404.
        guard !id.contains("|") else { throw APIError(message: "Not a Google place id") }
        let request = try detailsRequest(id: id)
        let session = self.session
        return try await detailsStore.details(for: id) {
            try await Self.fetchDetails(request: request, session: session, id: id)
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

        var retried = false
        while true {
            try Task.checkCancellation()
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200, !data.isEmpty {
                photoCache.setObject(data as NSData, forKey: cacheKey, cost: data.count)
                return data
            }
            // Same transient-retry policy as search; photos are cosmetic, so the final failure stays a plain APIError.
            if status == 429 || (500...599).contains(status), !retried,
               let http = response as? HTTPURLResponse {
                retried = true
                try await Task.sleep(nanoseconds: Self.retryDelayNanos(http))
                continue
            }
            throw APIError(message: "Photo fetch failed")
        }
    }

    // MARK: - Request plumbing

    private static let bundleID = Bundle.main.bundleIdentifier ?? "com.ahmedbegovic.Sightline"

    /// The API wants a bare language code ("de"), not a full locale identifier ("de_DE").
    private static let languageCode = Locale.current.language.languageCode?.identifier ?? "en"

    /// Discovery mask: only what bubbles, ranking and the gates read at scan time. rating/userRatingCount are the priciest entries and set the whole call's SKU (Enterprise) — the ambient quality gate needs them per result, so they cannot move to placeDetails.
    private static let discoveryFieldMask = [
        "places.id", "places.displayName", "places.location", "places.types",
        "places.primaryType", "places.rating", "places.userRatingCount",
        // Street-visibility signals; entrances/navigationPoints shipped 2026-08-06 so every one of these is decoded defensively.
        "places.businessStatus", "places.pureServiceAreaBusiness", "places.containingPlaces",
        "places.entrances", "places.navigationPoints",
    ].joined(separator: ",")

    /// Details mask (no "places." prefix on the GET endpoint): reviews and servesVegetarianFood bill this call at Enterprise + Atmosphere, which is why it runs per tapped place, never per scan.
    private static let detailFieldMask = [
        "id", "formattedAddress", "nationalPhoneNumber", "websiteUri", "priceLevel",
        "currentOpeningHours.openNow", "servesVegetarianFood", "reviews", "photos",
    ].joined(separator: ",")

    private func circle(_ center: CLLocationCoordinate2D, _ radius: Double) -> [String: Any] {
        [
            "circle": [
                "center": ["latitude": center.latitude, "longitude": center.longitude],
                "radius": min(max(radius, 1), 50_000),
            ],
        ]
    }

    private func search(path: String,
                        body: [String: Any],
                        ambientVenuesOnly: Bool = false,
                        explicitIntent: Bool = false) async throws -> [Place] {
        guard let url = URL(string: "https://places.googleapis.com/v1/\(path)") else {
            throw APIError(message: "Bad endpoint")
        }
        var payload = body
        payload["languageCode"] = Self.languageCode
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Secrets.googleAPIKey, forHTTPHeaderField: "X-Goog-Api-Key")
        request.setValue(Self.bundleID, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        request.setValue(Self.discoveryFieldMask, forHTTPHeaderField: "X-Goog-FieldMask")

        var retried = false
        while true {
            try Task.checkCancellation()
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw APIError(message: "No response from Places API")
            }
            if http.statusCode == 200 {
                let envelope = try JSONDecoder().decode(SearchEnvelope.self, from: data)
                return (envelope.places ?? [])
                    .compactMap(\.value)
                    .filter { Self.isStreetVisible($0, explicitIntent: explicitIntent) }
                    .filter { !ambientVenuesOnly || VenueCategoryPolicy.isAmbientVenue(primaryType: $0.primaryType, types: $0.types) }
                    .compactMap { place(from: $0) }
            }
            // One retry for transient classes only; auth and shape errors will not heal on their own.
            let transient = http.statusCode == 429 || (500...599).contains(http.statusCode)
            if transient, !retried {
                retried = true
                try await Task.sleep(nanoseconds: Self.retryDelayNanos(http))
                continue
            }
            let message = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error.message
            throw Self.requestError(status: http.statusCode, message: message)
        }
    }

    /// Honors Retry-After when Google sends one, clamped so a scan still fails inside the UI's patience window.
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

    /// Per-id cache with in-flight dedupe. The fetch task is unstructured on purpose: a dismissed card cancelling its await must not kill the request for another awaiter, and a landed result stays warm for the next open.
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
                // Failures are never cached — the next card or assistant open retries.
                inFlight[id] = nil
                throw error
            }
        }
    }

    private func detailsRequest(id: String) throws -> URLRequest {
        guard let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://places.googleapis.com/v1/places/\(escaped)?languageCode=\(Self.languageCode)") else {
            throw APIError(message: "Bad place id")
        }
        var request = URLRequest(url: url)
        request.setValue(Secrets.googleAPIKey, forHTTPHeaderField: "X-Goog-Api-Key")
        request.setValue(Self.bundleID, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        request.setValue(Self.detailFieldMask, forHTTPHeaderField: "X-Goog-FieldMask")
        return request
    }

    /// Static (no self capture) so the store's @Sendable fetch closure only carries Sendable state.
    private static func fetchDetails(request: URLRequest,
                                     session: URLSession,
                                     id: String) async throws -> PlaceDetails {
        var retried = false
        while true {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw APIError(message: "No response from Places API")
            }
            if http.statusCode == 200 {
                // The details endpoint returns one bare place object — same DTO as a search entry.
                return details(from: try JSONDecoder().decode(GPlace.self, from: data), id: id)
            }
            // Same one-retry transient policy as search.
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

    // MARK: - Street-visibility filter

    /// The one hard filter cascade — service-area businesses, non-operational places, and anything inside another venue; fails open.
    private static func isStreetVisible(_ g: GPlace, explicitIntent: Bool) -> Bool {
        // No premises to point a camera at, so service-area listings drop even for explicit search.
        if g.pureServiceAreaBusiness == true { return false }
        // UNSPECIFIED means "unknown", not "closed", so it stays neutral like a missing field.
        if let status = g.businessStatus, !status.isEmpty,
           status != "OPERATIONAL", status != "BUSINESS_STATUS_UNSPECIFIED" {
            // A user who searched by name gets a temporarily closed place back; permanent closures stay dropped everywhere.
            if !(explicitIntent && status == "CLOSED_TEMPORARILY") { return false }
        }
        // Mall-contained places hide from ambient scans only; explicit intent shows them wherever they are.
        if !explicitIntent, let containing = g.containingPlaces?.value, !containing.isEmpty { return false }
        return true
    }

    /// Street-side anchor: first WALK navigation point, else first entrance, else nil (caller keeps the raw location).
    private static func anchor(for g: GPlace) -> CLLocationCoordinate2D? {
        let walkPoint = (g.navigationPoints?.value ?? [])
            .first { ($0.travelModes ?? []).contains("WALK") }
        if let coordinate = coordinate(from: walkPoint?.location) { return coordinate }
        return coordinate(from: (g.entrances?.value ?? []).first?.location)
    }

    private static func coordinate(from latLng: GPlace.LatLng?) -> CLLocationCoordinate2D? {
        guard let lat = latLng?.latitude, let lon = latLng?.longitude else { return nil }
        let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        return CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil
    }

    // MARK: - Response mapping

    private func place(from g: GPlace) -> Place? {
        guard let name = g.displayName?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty,
              let lat = g.location?.latitude,
              let lon = g.location?.longitude else { return nil }
        let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }

        // Prefer Google's canonical place_id: stable across scans and immune to same-name coordinate-cell collisions.
        var place = Place(id: (g.id?.isEmpty == false ? g.id! : Place.stableID(name: name, coordinate: coordinate)),
                          name: name,
                          category: category(for: g, name: name),
                          coordinate: coordinate)
        place.anchorCoordinate = Self.anchor(for: g)
        place.rating = g.rating ?? 0
        place.reviewCount = g.userRatingCount ?? 0
        return place
    }

    /// Rich-field payload from a details response; review ids key off the place id so identity stays stable across refetches.
    private static func details(from g: GPlace, id: String) -> PlaceDetails {
        var details = PlaceDetails()
        details.address = shortAddress(from: g.formattedAddress)
        details.phone = g.nationalPhoneNumber
        details.url = g.websiteUri.flatMap(URL.init(string:))
        details.priceLevel = priceLevel(from: g.priceLevel)
        details.isOpenNow = g.currentOpeningHours?.openNow
        details.servesVegetarian = g.servesVegetarianFood
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

    // 0 = unknown/free; never invent a price for live data.
    private static func priceLevel(from raw: String?) -> Int {
        switch raw {
        case "PRICE_LEVEL_INEXPENSIVE": return 1
        case "PRICE_LEVEL_MODERATE": return 2
        case "PRICE_LEVEL_EXPENSIVE": return 3
        case "PRICE_LEVEL_VERY_EXPENSIVE": return 4
        default: return 0
        }
    }

    /// Google type strings → app categories: `primaryType` wins, then first mappable `types` entry, then a keyword pass on the name.
    private func category(for g: GPlace, name: String) -> PlaceCategory {
        if let primary = g.primaryType, let mapped = Self.mapType(primary) {
            return mapped
        }
        for type in g.types ?? [] {
            if let mapped = Self.mapType(type) { return mapped }
        }
        return Self.keywordCategory(forName: name)
    }

    // Internal (not private) so the category mapping is unit-testable as a pure function.
    static func mapType(_ type: String) -> PlaceCategory? {
        switch type {
        case "cafe", "coffee_shop", "tea_house", "cafeteria", "juice_shop": return .cafe
        case "bakery", "donut_shop", "bagel_shop", "dessert_shop", "confectionery": return .bakery
        case "bar", "pub", "wine_bar", "night_club", "brewery": return .bar
        case "ice_cream_shop": return .iceCream
        case "supermarket", "grocery_store", "food_market", "butcher_shop", "convenience_store": return .grocery
        case "hotel", "lodging", "motel", "hostel", "bed_and_breakfast", "resort_hotel", "inn",
             "extended_stay_hotel": return .hotel
        case "tourist_attraction", "historical_landmark", "monument", "historical_place",
             "observation_deck", "cultural_landmark", "plaza", "zoo", "amusement_park",
             "stadium", "tourist_information_center", "visitor_center": return .landmark
        // Worship buildings read as landmarks, matching the name-keyword pass for church/temple/basilica.
        case "church", "place_of_worship", "synagogue", "mosque", "hindu_temple": return .landmark
        case "museum", "art_gallery", "planetarium", "aquarium": return .museum
        case "movie_theater", "performing_arts_theater", "concert_hall", "opera_house",
             "amphitheatre", "theater": return .theater
        case "park", "national_park", "state_park", "garden", "botanical_garden", "dog_park",
             "hiking_area", "beach", "marina": return .park
        case "subway_station", "train_station", "transit_station", "bus_station", "bus_stop",
             "light_rail_station", "transit_depot", "airport", "ferry_terminal",
             "taxi_stand": return .transit
        case "atm": return .atm
        case "bank", "credit_union": return .bank
        case "pharmacy", "drugstore": return .pharmacy
        // Closest health category until Models gains a .hospital case; .other would let the ambient rating gate hide low-rated ERs.
        case "hospital": return .pharmacy
        default:
            if type == "restaurant" || type.hasSuffix("_restaurant")
                || type == "meal_takeaway" || type == "meal_delivery"
                || type == "food_court" || type == "sandwich_shop" || type == "diner" {
                return .restaurant
            }
            if type == "store" || type.hasSuffix("_store") || type == "shopping_mall"
                || type == "market" || type == "gift_shop" {
                return .shop
            }
            return nil
        }
    }

    private static func keywordCategory(forName name: String) -> PlaceCategory {
        let lowered = name.lowercased()
        func hasAny(_ keywords: [String]) -> Bool {
            keywords.contains { lowered.contains($0) }
        }
        if hasAny(["taco", "pizza", "grill", "kitchen", "sushi", "kebab", "bbq",
                   "burger", "thai", "ramen", "diner", "restaurant"]) { return .restaurant }
        if hasAny(["coffee", "cafe", "espresso", "roaster"]) { return .cafe }
        if hasAny(["ice cream", "gelato", "creamery"]) { return .iceCream }
        if hasAny(["bar", "pub", "tavern", "lounge"]) { return .bar }
        if hasAny(["theatre", "theater", "cinema"]) { return .theater }
        if hasAny(["hotel", "inn", "suites"]) { return .hotel }
        if hasAny(["tower", "bridge", "cathedral", "monument", "memorial",
                   "pier", "square", "temple", "church", "basilica", "obelisk",
                   "castle", "palace"]) { return .landmark }
        if hasAny(["museum", "gallery"]) { return .museum }
        if hasAny(["station", "bart", "metro", "subway"]) { return .transit }
        if hasAny(["atm"]) { return .atm }
        if hasAny(["bank"]) { return .bank }
        if hasAny(["pharmacy", "drug"]) { return .pharmacy }
        if hasAny(["market", "grocer"]) { return .grocery }
        return .other
    }

    private static func shortAddress(from formatted: String?) -> String? {
        guard let formatted else { return nil }
        let parts = formatted.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty else { return nil }
        return parts.prefix(2).joined(separator: ", ")
    }

    // MARK: - DTOs

    /// Per-place leniency: one entry with an unexpected shape drops only itself instead of failing the whole search.
    private struct SearchEnvelope: Decodable { let places: [Defensive<GPlace>]? }

    /// Decodes to nil instead of throwing when a payload's shape is unexpected — a freshly shipped field must never sink a whole response.
    private struct Defensive<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }

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
        struct ContainingPlace: Decodable { let id: String? }
        struct Entrance: Decodable { let location: LatLng? }
        struct NavigationPoint: Decodable {
            let location: LatLng?
            let travelModes: [String]?
        }

        let id: String?
        let displayName: LocalizedText?
        let location: LatLng?
        let types: [String]?
        let primaryType: String?
        let formattedAddress: String?
        let rating: Double?
        let userRatingCount: Int?
        let priceLevel: String?
        let nationalPhoneNumber: String?
        let websiteUri: String?
        let currentOpeningHours: Hours?
        let servesVegetarianFood: Bool?
        let reviews: [GReview]?
        let photos: [Photo]?

        // Street-visibility signals — every one may be absent, and a surprising shape decodes to nil rather than throwing.
        let businessStatus: String?
        let pureServiceAreaBusiness: Bool?
        let containingPlaces: Defensive<[ContainingPlace]>?
        let entrances: Defensive<[Entrance]>?
        let navigationPoints: Defensive<[NavigationPoint]>?
    }
}
