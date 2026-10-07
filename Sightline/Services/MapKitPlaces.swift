import Foundation
import CoreLocation
import MapKit

/// Free Apple place data: typed search, and the scan's candidate list of notable things along the camera heading.
/// Candidates are only hints for the vision model — a place is never shown because it is nearby, only because it was seen.
enum MapKitPlaces {

    // MARK: - Typed search

    static func search(_ query: String, near center: CLLocationCoordinate2D?) async throws -> [Place] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.pointOfInterest, .address]
        if let center {
            request.region = MKCoordinateRegion(center: center, latitudinalMeters: 10_000, longitudinalMeters: 10_000)
        }
        let response = try await MKLocalSearch(request: request).start()
        return Array(response.mapItems.compactMap(place(from:)).prefix(10))
    }

    // MARK: - Scan candidates

    /// Things a tourist points a camera at. Shops and restaurants are left out on purpose: they only enter a scan through sign text (OCR), which is what keeps small-business noise away.
    static let notableCategories: [MKPointOfInterestCategory] = [
        .landmark, .nationalMonument, .castle, .fortress, .museum, .planetarium, .aquarium, .zoo,
        .stadium, .baseball, .basketball, .soccer, .amusementPark, .fairground, .conventionCenter,
        .theater, .musicVenue, .movieTheater, .university, .library, .park, .nationalPark, .beach,
        .marina, .scenicView, .publicTransport, .airport, .visitorCenter, .hospital,
    ]

    /// Ring centres along the heading, in metres. The first ring sits on the user; the rest walk out to skyline range.
    // ponytail: rings follow the centre line only, so a far landmark at the frame edge can be missed; add side rings if field tests show it.
    static let ringDistances: [CLLocationDistance] = [0, 1_500, 4_000, 8_000, 14_000, 22_000]

    /// Notable places ahead plus anything near the user whose name matches sign text. Throws only if every lookup failed.
    static func candidates(around origin: CLLocationCoordinate2D,
                           headingDegrees heading: Double,
                           signs: [String]) async throws -> [Place] {
        let radius = min(MKLocalPointsOfInterestRequest.maxRadius, 2_500)
        let filter = MKPointOfInterestFilter(including: notableCategories)

        return try await withThrowingTaskGroup(of: [Place].self) { group in
            for distance in ringDistances {
                let center = destination(from: origin, bearingDegrees: heading, distanceMeters: distance)
                group.addTask {
                    let request = MKLocalPointsOfInterestRequest(center: center, radius: radius)
                    request.pointOfInterestFilter = filter
                    let places = try await MKLocalSearch(request: request).start().mapItems.compactMap(place(from:))
                    // The same count on every ring means MapKit is capping results and dense areas lose the target.
                    scanLog.debug("ring \(Int(distance)) m: \(places.count) places")
                    return places
                }
            }
            // The two longest sign lines are the likeliest business names; short fragments match everything.
            for sign in signs.sorted(by: { $0.count > $1.count }).prefix(2) {
                group.addTask {
                    let request = MKLocalSearch.Request()
                    request.naturalLanguageQuery = sign
                    request.resultTypes = .pointOfInterest
                    request.region = MKCoordinateRegion(center: origin, latitudinalMeters: 1_500, longitudinalMeters: 1_500)
                    let items = try await MKLocalSearch(request: request).start().mapItems
                    return items.compactMap(place(from:)).filter { SceneMatcher.matchesSign($0.name, signs: [sign]) }
                }
            }

            var found: [Place] = []
            var seen = Set<String>()
            var firstError: Error?
            while let next = await group.nextResult() {
                switch next {
                case .success(let places):
                    for place in places where seen.insert(place.id).inserted { found.append(place) }
                case .failure(let error):
                    if firstError == nil { firstError = error }
                }
            }
            if found.isEmpty, let firstError { throw firstError }
            return found
        }
    }

    /// Looks up a name the model recognised but the candidate list missed; accepted only if it lies roughly where the camera saw it.
    static func locate(_ name: String, near origin: CLLocationCoordinate2D, bearing: Double) async -> Place? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = name
        request.resultTypes = .pointOfInterest
        request.region = MKCoordinateRegion(center: origin, latitudinalMeters: 60_000, longitudinalMeters: 60_000)
        guard let items = try? await MKLocalSearch(request: request).start().mapItems else { return nil }
        return items.compactMap(place(from:)).first { candidate in
            let delta = Angles.shortestDelta(from: bearing, to: ARProjector.bearing(from: origin, to: candidate.coordinate))
            return abs(delta) <= SceneMatcher.lookupToleranceDegrees
        }
    }

    // MARK: - Mapping

    static func place(from item: MKMapItem) -> Place? {
        guard let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        let coordinate = item.location.coordinate
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        var place = Place(id: item.identifier?.rawValue ?? Place.stableID(name: name, coordinate: coordinate),
                          name: name,
                          category: category(for: item.pointOfInterestCategory),
                          coordinate: coordinate)
        place.phone = item.phoneNumber
        place.url = item.url
        place.address = item.address?.shortAddress ?? item.address?.fullAddress
        return place
    }

    static func category(for poi: MKPointOfInterestCategory?) -> PlaceCategory {
        switch poi {
        case .restaurant: return .restaurant
        case .cafe: return .cafe
        case .bakery: return .bakery
        case .nightlife, .brewery, .winery, .distillery: return .bar
        case .store: return .shop
        case .foodMarket: return .grocery
        case .hotel: return .hotel
        case .museum, .planetarium, .aquarium, .zoo: return .museum
        case .theater, .movieTheater, .musicVenue: return .theater
        case .park, .nationalPark, .beach, .marina, .hiking, .campground: return .park
        case .publicTransport, .airport, .airportTerminal: return .transit
        case .atm: return .atm
        case .bank: return .bank
        case .pharmacy, .hospital: return .pharmacy
        case .landmark, .nationalMonument, .castle, .fortress, .scenicView, .stadium, .baseball,
             .basketball, .soccer, .amusementPark, .fairground, .conventionCenter, .university,
             .library, .visitorCenter:
            return .landmark
        default: return .other
        }
    }

    /// Standard great-circle destination point.
    static func destination(from origin: CLLocationCoordinate2D,
                            bearingDegrees bearing: Double,
                            distanceMeters distance: CLLocationDistance) -> CLLocationCoordinate2D {
        guard distance > 0 else { return origin }
        let angular = distance / 6_371_000
        let theta = bearing * .pi / 180
        let lat1 = origin.latitude * .pi / 180
        let lon1 = origin.longitude * .pi / 180
        let lat2 = asin(sin(lat1) * cos(angular) + cos(lat1) * sin(angular) * cos(theta))
        let lon2 = lon1 + atan2(sin(theta) * sin(angular) * cos(lat1), cos(angular) - sin(lat1) * sin(lat2))
        let lon = (lon2 * 180 / .pi + 540).truncatingRemainder(dividingBy: 360) - 180
        return CLLocationCoordinate2D(latitude: lat2 * 180 / .pi, longitude: lon)
    }
}
