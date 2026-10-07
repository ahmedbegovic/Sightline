import Foundation
import CoreLocation
import SwiftUI
import CoreGraphics

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
}

// MARK: - Reviews & places

struct Review: Identifiable, Hashable {
    let id: String
    let author: String
    let stars: Int          // 1...5
    let text: String
}

/// Google listing fields, looked up by name + coordinate only when a card or the guide opens — never per scan.
struct PlaceDetails: Hashable {
    var rating: Double = 0
    var reviewCount: Int = 0
    var address: String?
    var phone: String?
    var url: URL?
    var priceLevel: Int = 0          // 0 = unknown, else 1...4
    var reviews: [Review] = []
    /// Live open/closed status from Google; nil when unknown.
    var isOpenNow: Bool?
    /// Google photo resource name, fetched via `GooglePlacesService.photoData`.
    var photoResource: String?
}

/// Where the camera was pointing when the scan saw this thing. Height- and distance-independent, so the bubble stays on the object.
struct Sighting: Hashable {
    /// Degrees clockwise from true north.
    let bearing: Double
    /// Degrees above the horizon (negative = below, e.g. looking down from a tower).
    let elevation: Double
    /// Where the scan was taken; a bearing only holds near this point.
    var origin: CLLocation? = nil

    /// A step sideways swings a near bearing fast (10 m at 30 m is ~18°), so past this a located place goes back to its map position.
    static let driftMeters: CLLocationDistance = 15
}

struct Place: Identifiable {
    let id: String
    var name: String
    var category: PlaceCategory
    /// Real map position when `isLocated`; otherwise the user's position at scan time (never shown as a distance).
    var coordinate: CLLocationCoordinate2D
    /// False when the scan recognised something MapKit could not place — no distance, route or map pin.
    var isLocated = true
    /// Set for scan results: the bubble is drawn where the camera saw it, not where the map says it is.
    var sighting: Sighting?
    /// One-line description from the scan model.
    var summary: String?
    /// The camera frame the scan used; shown on the card and handed to the guide.
    var snapshot: CGImage?
    var phone: String?
    var url: URL?
    var address: String?

    /// Google fields, attached on demand; nil = not loaded (or not found).
    var details: PlaceDetails?

    var rating: Double { details?.rating ?? 0 }
    var reviewCount: Int { details?.reviewCount ?? 0 }
    var priceLevel: Int { details?.priceLevel ?? 0 }
    var reviews: [Review] { details?.reviews ?? [] }
    var isOpenNow: Bool? { details?.isOpenNow }
    var photoResource: String? { details?.photoResource }

    var priceLabel: String { priceLevel <= 0 ? "" : String(repeating: "$", count: min(4, priceLevel)) }

    /// The sighting to draw from `location`: kept for unlocated places, dropped for located ones once the user walks away from the scan spot.
    func sighting(at location: CLLocation?) -> Sighting? {
        guard let sighting else { return nil }
        guard isLocated, let origin = sighting.origin, let location else { return sighting }
        return location.distance(from: origin) <= Sighting.driftMeters ? sighting : nil
    }

    func distance(from location: CLLocation?) -> CLLocationDistance? {
        guard isLocated, let location else { return nil }
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
            && lhs.isLocated == rhs.isLocated
            && lhs.sighting == rhs.sighting
            && lhs.summary == rhs.summary
            && lhs.snapshot === rhs.snapshot
            && lhs.phone == rhs.phone
            && lhs.url == rhs.url
            && lhs.address == rhs.address
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
    case failed(ScanFailure)
}

/// Why a scan or search produced no usable result set. Copy and iconography live at the render site.
enum ScanFailure: Equatable {
    /// No camera frame to look at (permission denied, session interrupted).
    case noCamera
    case offline
    /// MapKit is throttling; a retry in a moment is genuinely worth suggesting.
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
