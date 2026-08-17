import Foundation
import CoreLocation
import SwiftUI

// MARK: - Device pose

/// Where the user is and which way the camera is pointing.
struct DevicePose {
    var location: CLLocation?
    /// Compass heading in degrees, 0 = true north, increasing clockwise.
    var headingDegrees: Double = 0
    /// Camera tilt in degrees, 0 = level with the horizon, positive = tilted up.
    var pitchDegrees: Double = 0

    var coordinate: CLLocationCoordinate2D? { location?.coordinate }
}

// MARK: - Categories

/// CaseIterable is load-bearing: Prewarm derives its symbol list from it so a new category never rots the warm-up.
enum PlaceCategory: CaseIterable {
    case restaurant, cafe, bakery, bar, iceCream, shop, grocery, hotel,
         landmark, museum, theater, park, transit, atm, bank, pharmacy, other

    var displayName: String {
        switch self {
        case .restaurant: return "Restaurant"
        case .cafe: return "Café"
        case .bakery: return "Bakery"
        case .bar: return "Bar"
        case .iceCream: return "Ice Cream"
        case .shop: return "Shop"
        case .grocery: return "Grocery"
        case .hotel: return "Hotel"
        case .landmark: return "Landmark"
        case .museum: return "Museum"
        case .theater: return "Theater"
        case .park: return "Park"
        case .transit: return "Transit"
        case .atm: return "ATM"
        case .bank: return "Bank"
        case .pharmacy: return "Pharmacy"
        case .other: return "Place"
        }
    }

    var symbolName: String {
        switch self {
        case .restaurant: return "fork.knife"
        case .cafe: return "cup.and.saucer.fill"
        case .bakery: return "birthday.cake.fill"
        case .bar: return "wineglass.fill"
        case .iceCream: return "snowflake"
        case .shop: return "bag.fill"
        case .grocery: return "cart.fill"
        case .hotel: return "bed.double.fill"
        case .landmark: return "building.columns.fill"
        case .museum: return "photo.artframe"
        case .theater: return "theatermasks.fill"
        case .park: return "tree.fill"
        case .transit: return "tram.fill"
        case .atm: return "banknote.fill"
        case .bank: return "building.2.fill"
        case .pharmacy: return "cross.case.fill"
        case .other: return "mappin.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .restaurant: return .orange
        case .cafe, .bakery: return Color(red: 0.80, green: 0.60, blue: 0.38)
        case .bar: return .purple
        case .iceCream: return .pink
        case .shop, .grocery: return .teal
        case .hotel: return .indigo
        // Warm gold, not neon yellow — yellow on glass reads as a warning.
        case .landmark, .museum: return Theme.landmark
        // A category tint must never be the color that means "error".
        case .theater: return Color(red: 0.85, green: 0.35, blue: 0.60)
        case .park: return .green
        case .transit: return .cyan
        case .atm, .bank: return .mint
        case .pharmacy: return Color(red: 0.92, green: 0.36, blue: 0.42)
        // Accent means "selected"; a generic pin must not claim it.
        case .other: return Color(red: 0.58, green: 0.64, blue: 0.74)
        }
    }

    /// True for categories where "menu / dietary" assistant answers make sense.
    var servesFood: Bool {
        switch self {
        case .restaurant, .cafe, .bakery, .bar, .iceCream: return true
        default: return false
        }
    }
}

/// Coarse grouping the assistant routes on: quick questions, model persona, and heuristic answers all switch on this.
enum PlaceGuideKind {
    case eatery, landmark, museum, theater, park, hotel, retail, transit, essential, generic
}

extension PlaceCategory {
    /// No `default`: a new category must be given a guide kind rather than silently inheriting the generic voice.
    var guideKind: PlaceGuideKind {
        switch self {
        case .restaurant, .cafe, .bakery, .bar, .iceCream: return .eatery
        case .landmark: return .landmark
        case .museum: return .museum
        case .theater: return .theater
        case .park: return .park
        case .hotel: return .hotel
        case .shop, .grocery: return .retail
        case .transit: return .transit
        case .atm, .bank, .pharmacy: return .essential
        case .other: return .generic
        }
    }
}

// MARK: - Reviews & places

struct Review: Identifiable, Hashable {
    let id: String
    let author: String
    let stars: Int          // 1...5
    let text: String
}

/// Rich listing payload fetched per id on demand (detail card / assistant open) — never part of discovery responses.
struct PlaceDetails: Hashable {
    var address: String?
    var phone: String?
    var url: URL?
    var priceLevel: Int = 0          // 0 = unknown, else 1...4
    var reviews: [Review] = []
    /// Live open/closed status from Google; nil when unknown.
    var isOpenNow: Bool?
    /// Google's servesVegetarianFood attribute; nil when unknown.
    var servesVegetarian: Bool?
    /// Google photo resource name, fetched via `GooglePlacesService.photoData`.
    var photoResource: String?
}

struct Place: Identifiable {
    let id: String
    var name: String
    var category: PlaceCategory
    var coordinate: CLLocationCoordinate2D
    /// Street-side anchor (walk navigation point or entrance) when Google published one; nil = fall back to `coordinate`.
    var anchorCoordinate: CLLocationCoordinate2D?
    /// Set when this place was found by the long-range landmark scan.
    var isFarLandmark: Bool = false
    /// Street View has no outdoor pano near this place — probably not visible from the street, so it ranks last.
    var streetVisibilityUnlikely: Bool = false

    // Discovery-time Google values; zero when unpublished. In the scan mask because bubbles and the ambient quality gate need them.
    var rating: Double = 0
    var reviewCount: Int = 0

    /// Rich fields, attached when `GooglePlacesService.placeDetails` answers; nil = not loaded (or load failed — UI shows discovery data).
    var details: PlaceDetails?

    // Flat pass-throughs so pre-existing UI reads stay unchanged; each is nil/empty until details load.
    var address: String? { details?.address }
    var phone: String? { details?.phone }
    var url: URL? { details?.url }
    var priceLevel: Int { details?.priceLevel ?? 0 }
    var reviews: [Review] { details?.reviews ?? [] }
    var isOpenNow: Bool? { details?.isOpenNow }
    var servesVegetarian: Bool? { details?.servesVegetarian }
    var photoResource: String? { details?.photoResource }

    var priceLabel: String { priceLevel <= 0 ? "" : String(repeating: "$", count: min(4, priceLevel)) }

    /// Coordinate to aim the AR bubble and the walking route at — the street-side anchor when known.
    var arCoordinate: CLLocationCoordinate2D { anchorCoordinate ?? coordinate }

    func distance(from location: CLLocation?) -> CLLocationDistance? {
        guard let location else { return nil }
        return location.distance(from: CLLocation(latitude: coordinate.latitude,
                                                  longitude: coordinate.longitude))
    }
}

extension Place: Hashable {
    // Content-aware equality so SwiftUI re-renders when fresher data arrives for the same id; hashing stays id-based.
    static func == (lhs: Place, rhs: Place) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.category == rhs.category
            && lhs.coordinate.latitude == rhs.coordinate.latitude
            && lhs.coordinate.longitude == rhs.coordinate.longitude
            && lhs.anchorCoordinate?.latitude == rhs.anchorCoordinate?.latitude
            && lhs.anchorCoordinate?.longitude == rhs.anchorCoordinate?.longitude
            && lhs.streetVisibilityUnlikely == rhs.streetVisibilityUnlikely
            && lhs.isFarLandmark == rhs.isFarLandmark
            && lhs.rating == rhs.rating
            && lhs.reviewCount == rhs.reviewCount
            && lhs.details == rhs.details
    }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension Place {
    /// Stable id from name + coordinate — String.hashValue is randomized per launch, so ids must come from here.
    static func stableID(name: String, coordinate: CLLocationCoordinate2D) -> String {
        let lat = (coordinate.latitude * 10_000).rounded() / 10_000
        let lon = (coordinate.longitude * 10_000).rounded() / 10_000
        return "\(name.lowercased())|\(lat)|\(lon)"
    }
}

// MARK: - Scanning

enum ScanState: Equatable {
    case idle
    case scanning
    case found
    /// The request succeeded and genuinely returned nothing. Never set for a failure.
    case empty
    /// Results landed, but the AR path cannot place long-range claims yet — the user has to step outside.
    case needsOutdoors
    case failed(ScanFailure)
}

/// Why a scan or search produced no usable result set. Copy and iconography live at the render site.
enum ScanFailure: Equatable {
    case noLocationFix
    /// A fix exists but its metadata is too poor to trust — stale or inaccurate location, or an unusable compass.
    case poorSensors
    case offline
    /// Google rejected the key or bundle restriction — retrying won't help until configuration changes.
    case accessDenied
    /// Places is rate-limiting or failing server-side; a retry in a moment is genuinely worth suggesting.
    case serviceBusy
    case other
}

// MARK: - Navigation

struct RouteStep {
    let instruction: String
}

struct ActiveRoute {
    let destination: Place
    /// Densified walking path (a point every few meters).
    let points: [CLLocationCoordinate2D]
    let totalDistance: CLLocationDistance
    let expectedTravelTime: TimeInterval
    let steps: [RouteStep]
}

struct RouteProgress {
    let remainingDistance: CLLocationDistance
    let remainingTime: TimeInterval
    let nextInstruction: String?
    let hasArrived: Bool
    /// Path points from the user's position onward, for drawing the guide line.
    let lookahead: [CLLocationCoordinate2D]
}

// MARK: - Assistant

struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, assistant }
    let id = UUID()
    let role: Role
    var text: String
}
