import Foundation
import CoreLocation

// MARK: - Backend selection

/// Which camera/pose stack is driving the scene. Decided once per session; only `.geoAR -> .fallback` is ever allowed.
enum SceneBackend: Equatable {
    case undecided
    case geoAR
    case fallback(FallbackReason)

    var isGeoAR: Bool { self == .geoAR }
}

/// Why the AR path is not running. The first six are decided up front; the rest are runtime demotions.
enum FallbackReason: Equatable {
    case simulator, sdkMissing, deviceUnsupported
    case cameraPermission, locationPermission, reducedAccuracy
    case garInitFailed, geospatialUnsupported, garConfigFailed
    case arSessionFailed, vpsUnavailable, notAuthorized, garUpdateFailing
}

// MARK: - Localization phase

/// AR-path localization phase. Bubbles are suppressed for everything except `.localized`.
enum GeoARPhase: Equatable {
    case inactive          // fallback backend is running
    case starting          // ARSession up, no GARFrame with an earth yet
    case localizing        // earth present but not tracking, or accuracy still poor
    case localized         // tracking + yaw/horizontal accuracy within budget
}

/// Hysteresis budget for `GeoARPhase`; without the enter/exit gap the pill flaps once per second at the boundary.
enum GeoARThresholds {
    /// Become `.localized` at or below this yaw accuracy, in degrees.
    static let yawAccuracyEnter: Double = 15
    /// Drop back to `.localizing` above this yaw accuracy.
    static let yawAccuracyExit: Double = 25
    /// Become `.localized` at or below this horizontal accuracy, in metres.
    static let horizontalAccuracyEnter: Double = 15
    /// Drop back to `.localizing` above this horizontal accuracy.
    static let horizontalAccuracyExit: Double = 25
    /// Grace period before a tracking hiccup demotes the phase.
    static let trackingLossGrace: TimeInterval = 2
}

// MARK: - Snapshot

/// One main-thread-safe readout of the AR path; contains no ARCore types so it compiles in the simulator.
struct GeoARSnapshot {
    var phase: GeoARPhase = .starting
    var location: CLLocation?
    var headingDegrees: Double = 0
    var pitchDegrees: Double = 0
    var geometryCount: Int = 0
}

// MARK: - Occlusion probing (types land in Stage 1 so the protocol conformance lives in one place)

/// One place to test for occlusion; plain values only.
struct OcclusionProbe: Sendable {
    let id: String
    let latitude: Double
    let longitude: Double
    /// Metres above local ground to aim at; the occlusion service issues one probe per ray tier.
    let aimHeightMeters: Double
}

/// Raw raycast measurement for one probe; policy lives elsewhere. Absence of a sample means "no answer".
struct OcclusionSample: Sendable {
    let id: String
    let targetDistanceMeters: Double
    let nearestBuildingHitMeters: Double?
    let nearestTerrainHitMeters: Double?
}

/// The narrow surface the occlusion service needs; `GeoARManager` conforms on device, a stub conforms elsewhere.
protocol OcclusionProbeSource: AnyObject {
    var isLocalizedForOcclusion: Bool { get }
    var localizedCoordinate: CLLocationCoordinate2D? { get }
    var hasStreetscapeGeometry: Bool { get }
    func sampleOcclusion(_ probes: [OcclusionProbe]) async -> [OcclusionSample]
}
