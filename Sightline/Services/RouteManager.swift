import Foundation
import Combine
import CoreLocation
import MapKit

/// Calculates walking routes and answers per-frame progress queries for the AR guidance overlay.
@MainActor
final class RouteManager: ObservableObject {
    @Published private(set) var route: ActiveRoute?
    @Published private(set) var isCalculating: Bool = false
    @Published private(set) var lastError: String?

    // MARK: - Private state

    /// Cumulative meters along the densified path, aligned with `route.points`.
    private var cumulativeDistances: [CLLocationDistance] = []
    /// Densified-path index for each entry in `route.steps`.
    private var stepIndices: [Int] = []
    /// Cache for the windowed nearest-point search in `progress(from:)`.
    private var lastNearestIndex: Int?
    /// Serves repeat per-frame callers between recomputes; cleared on (re)route and stop.
    private var cachedProgress: RouteProgress?
    private var cachedProgressAt: TimeInterval = 0
    /// Nearest index backing `cachedLookahead`, so the tail array is only re-copied when it moves.
    private var cachedLookaheadIndex: Int?
    private var cachedLookahead: [CLLocationCoordinate2D] = []
    /// Debounce for automatic rerouting.
    private var lastRerouteAt: Date?
    /// Invalidates in-flight calculations when a newer one starts (or on stop).
    private var generation = 0

    private static let densifySpacing: CLLocationDistance = 4
    /// Location moves at ~1 Hz, so recomputing progress faster than ~8 Hz only burns CPU.
    private static let progressRefreshInterval: TimeInterval = 0.125

    // MARK: - Navigation lifecycle

    func startNavigation(to place: Place, from origin: CLLocationCoordinate2D) async {
        generation += 1
        let gen = generation
        isCalculating = true
        lastError = nil

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        // Route to the street-side anchor when Google published one — walking directions to a venue centroid can land inside the block.
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: place.arCoordinate))
        request.transportType = .walking
        request.requestsAlternateRoutes = false

        do {
            let response = try await MKDirections(request: request).calculate()
            guard gen == generation else { return }
            isCalculating = false

            guard let mkRoute = response.routes.first else {
                lastError = "No walking route found."
                return
            }

            let raw = mkRoute.polyline.routeCoordinates
            let (dense, cumulative) = Self.densify(raw, maxSpacing: Self.densifySpacing)
            guard dense.count > 1 else {
                lastError = "No walking route found."
                return
            }

            var steps: [RouteStep] = []
            var indices: [Int] = []
            for step in mkRoute.steps where !step.instructions.isEmpty {
                let stepCoords = step.polyline.routeCoordinates
                guard !stepCoords.isEmpty else { continue }
                let midpoint = stepCoords[stepCoords.count / 2]
                steps.append(RouteStep(instruction: step.instructions))
                indices.append(Self.nearestIndex(to: midpoint, in: dense))
            }

            cumulativeDistances = cumulative
            stepIndices = indices
            lastNearestIndex = nil
            invalidateProgressCache()
            route = ActiveRoute(destination: place,
                                points: dense,
                                totalDistance: mkRoute.distance,
                                expectedTravelTime: mkRoute.expectedTravelTime,
                                steps: steps)
        } catch {
            guard gen == generation else { return }
            isCalculating = false
            if let mkError = error as? MKError, mkError.code == .directionsNotFound {
                lastError = "No walking route found."
            } else {
                lastError = "Route lookup failed — check your connection."
            }
        }
    }

    func stop() {
        generation += 1
        isCalculating = false
        route = nil
        lastError = nil
        cumulativeDistances = []
        stepIndices = []
        lastNearestIndex = nil
        invalidateProgressCache()
        lastRerouteAt = nil
    }

    private func invalidateProgressCache() {
        cachedProgress = nil
        cachedProgressAt = 0
        cachedLookaheadIndex = nil
        cachedLookahead = []
    }

    // MARK: - Per-frame progress

    /// Safe to call per frame: recomputes at most every `progressRefreshInterval`, serving the cached result in between.
    func progress(from location: CLLocation) -> RouteProgress? {
        guard let route,
              route.points.count > 1,
              cumulativeDistances.count == route.points.count else { return nil }

        let now = ProcessInfo.processInfo.systemUptime
        if let cached = cachedProgress, now - cachedProgressAt < Self.progressRefreshInterval {
            return cached
        }

        let points = route.points
        let coord = location.coordinate
        let metersPerDegree = 111_320.0
        let cosLat = cos(coord.latitude * .pi / 180)

        let searchRange: Range<Int>
        if let last = lastNearestIndex {
            searchRange = max(0, last - 40)..<min(points.count, last + 41)
        } else {
            searchRange = 0..<points.count
        }

        var best = searchRange.lowerBound
        var bestScore = Double.greatestFiniteMagnitude
        for i in searchRange {
            let dLat = (points[i].latitude - coord.latitude) * metersPerDegree
            let dLon = (points[i].longitude - coord.longitude) * metersPerDegree * cosLat
            let score = dLat * dLat + dLon * dLon
            if score < bestScore {
                bestScore = score
                best = i
            }
        }
        lastNearestIndex = best
        let offPathDistance = bestScore.squareRoot()

        let remaining = max(0, route.totalDistance - cumulativeDistances[best])
        let remainingTime = route.totalDistance > 0
            ? route.expectedTravelTime * remaining / route.totalDistance
            : 0
        // Polyline progress alone can hit zero from a parallel street; arrival also requires true proximity to the endpoint.
        let endpoint = points[points.count - 1]
        let endpointGap = location.distance(from: CLLocation(latitude: endpoint.latitude,
                                                             longitude: endpoint.longitude))
        let arrived = remaining < 15 && endpointGap <= 25

        var instruction: String?
        if !arrived {
            for (i, idx) in stepIndices.enumerated() where idx > best + 3 {
                instruction = route.steps[i].instruction
                break
            }
        }

        // Off the path by more than 50 m -> recalculate from here (debounced).
        if offPathDistance > 50, !isCalculating {
            let now = Date()
            if lastRerouteAt.map({ now.timeIntervalSince($0) > 20 }) ?? true {
                lastRerouteAt = now
                let destination = route.destination
                Task { [weak self] in
                    await self?.startNavigation(to: destination, from: coord)
                }
            }
        }

        if cachedLookaheadIndex != best {
            cachedLookahead = Array(points[best...])
            cachedLookaheadIndex = best
        }
        let result = RouteProgress(remainingDistance: remaining,
                                   remainingTime: remainingTime,
                                   nextInstruction: instruction,
                                   hasArrived: arrived,
                                   lookahead: cachedLookahead)
        cachedProgress = result
        cachedProgressAt = now
        return result
    }

    // MARK: - Geometry helpers

    /// Interpolates so consecutive points are at most `maxSpacing` meters apart, returning cumulative distances alongside.
    private static func densify(_ raw: [CLLocationCoordinate2D],
                                maxSpacing: CLLocationDistance)
        -> (points: [CLLocationCoordinate2D], cumulative: [CLLocationDistance]) {
        guard raw.count > 1 else { return (raw, raw.map { _ in 0 }) }

        var points: [CLLocationCoordinate2D] = [raw[0]]
        var cumulative: [CLLocationDistance] = [0]
        var total: CLLocationDistance = 0

        for i in 1..<raw.count {
            let a = raw[i - 1]
            let b = raw[i]
            let segment = CLLocation(latitude: a.latitude, longitude: a.longitude)
                .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
            guard segment > 0.01 else { continue }

            let divisions = max(1, Int(ceil(segment / maxSpacing)))
            let stepLength = segment / Double(divisions)
            for k in 1...divisions {
                let t = Double(k) / Double(divisions)
                let coordinate = (k == divisions) ? b : CLLocationCoordinate2D(
                    latitude: a.latitude + (b.latitude - a.latitude) * t,
                    longitude: a.longitude + (b.longitude - a.longitude) * t)
                total += stepLength
                points.append(coordinate)
                cumulative.append(total)
            }
        }
        return (points, cumulative)
    }

    /// Full-scan nearest index (used once per route build, not per frame).
    private static func nearestIndex(to coordinate: CLLocationCoordinate2D,
                                     in points: [CLLocationCoordinate2D]) -> Int {
        guard !points.isEmpty else { return 0 }
        let cosLat = cos(coordinate.latitude * .pi / 180)
        var best = 0
        var bestScore = Double.greatestFiniteMagnitude
        for (i, p) in points.enumerated() {
            let dLat = p.latitude - coordinate.latitude
            let dLon = (p.longitude - coordinate.longitude) * cosLat
            let score = dLat * dLat + dLon * dLon
            if score < bestScore {
                bestScore = score
                best = i
            }
        }
        return best
    }
}

// MARK: - MKMultiPoint coordinates

fileprivate extension MKMultiPoint {
    var routeCoordinates: [CLLocationCoordinate2D] {
        guard pointCount > 0 else { return [] }
        var coords = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(),
                                              count: pointCount)
        getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
        return coords
    }
}

#if DEBUG
extension RouteManager {
    /// Test seam: installs a synthetic route through the production densify pipeline; MapKit is never touched.
    /// Arms the reroute debounce so an off-path test fix cannot fire a live MKDirections request.
    func installTestRoute(destination: Place,
                          rawPoints: [CLLocationCoordinate2D],
                          expectedTravelTime: TimeInterval = 600,
                          steps: [RouteStep] = [],
                          stepDenseIndices: [Int] = []) {
        let (dense, cumulative) = Self.densify(rawPoints, maxSpacing: Self.densifySpacing)
        cumulativeDistances = cumulative
        stepIndices = stepDenseIndices
        lastNearestIndex = nil
        invalidateProgressCache()
        lastRerouteAt = Date()
        route = ActiveRoute(destination: destination,
                            points: dense,
                            totalDistance: cumulative.last ?? 0,
                            expectedTravelTime: expectedTravelTime,
                            steps: steps)
    }
}
#endif
