import Foundation
import CoreLocation

/// Place discovery (search, scan cone, far landmarks) — Google Places API (New) only; a failure surfaces as an error, never as substitute data.
final class PlacesService {

    static let shared = PlacesService()

    /// How wide "what's ahead of me" is. A product choice, deliberately decoupled from the camera's real FOV.
    static let scanConeDegrees: Double = 64

    private init() {}

    // MARK: - Search

    func searchNearby(query: String,
                      around center: CLLocationCoordinate2D,
                      radius: CLLocationDistance) async throws -> [Place] {
        // explicitIntent: a typed query must return the place even if temporarily closed or inside a mall.
        let found = try await GooglePlacesService.shared.textSearch(
            query: query, center: center, radiusMeters: radius, pageSize: 10, explicitIntent: true)
        return Array(TransitStopIdentity.deduped(dedup(found), origin: center).prefix(10))
    }

    // MARK: - Scan cone

    func scanCone(from origin: CLLocationCoordinate2D,
                  headingDegrees: Double,
                  coneDegrees: Double) async throws -> [Place] {
        async let nearOutcome = nearPass(from: origin,
                                         headingDegrees: headingDegrees,
                                         coneDegrees: coneDegrees)
        async let farOutcome = farLandmarkPass(from: origin,
                                               headingDegrees: headingDegrees)
        let (near, far) = await (nearOutcome, farOutcome)

        let nearPlaces = (try? near.get()) ?? []
        let farPlaces = (try? far.get()) ?? []

        // Nothing to show and a pass genuinely failed: report the failure, never a false "nothing found".
        if nearPlaces.isEmpty, farPlaces.isEmpty {
            if case .failure(let error) = near { throw error }
            if case .failure(let error) = far { throw error }
        }

        var merged = nearPlaces
        var seen = Set(merged.map(\.id))
        for landmark in farPlaces where !seen.contains(landmark.id) {
            seen.insert(landmark.id)
            merged.append(landmark)
        }
        return TransitStopIdentity.deduped(merged, origin: origin)
    }

    // MARK: - Near pass

    /// Scan radius: 150 m kept scans in one street but missed restaurants across a suburban parking lot (field test 2026-08-16); DISTANCE ranking still fills the page nearest-first.
    private static let scanRadius: CLLocationDistance = 300

    private func nearPass(from origin: CLLocationCoordinate2D,
                          headingDegrees: Double,
                          coneDegrees: Double) async -> Result<[Place], Error> {
        // One distance-ranked page caps at the 20 nearest in ANY direction, so dense side streets starve the cone; forward circles recover places dead ahead (documented free credit makes the extra calls cheap).
        let mid = destination(from: origin, bearingDegrees: headingDegrees, distanceMeters: 130)
        let far = destination(from: origin, bearingDegrees: headingDegrees, distanceMeters: 220)
        // Each circle stays inside scanRadius of the user, so the merged set keeps today's range cap.
        async let userOutcome = sampledNearby(center: origin, radiusMeters: Self.scanRadius)
        async let midOutcome = sampledNearby(center: mid, radiusMeters: 140)
        async let farOutcome = sampledNearby(center: far, radiusMeters: 80)
        let outcomes = await [userOutcome, midOutcome, farOutcome]

        var found: [Place] = []
        var firstError: Error?
        for outcome in outcomes {
            switch outcome {
            case .success(let places): found += places
            case .failure(let error): if firstError == nil { firstError = error }
            }
        }
        // One circle down is a degraded scan; all down is a real failure (mirrors the far-landmark pass).
        if found.isEmpty, let firstError { return .failure(firstError) }
        // A cancelled scan must surface as cancelled, never as a thinner partial result set.
        if Task.isCancelled { return .failure(CancellationError()) }

        // The venue gate can empty a residential scan; that's an honest "nothing here", never a cue to relax the filter.
        let scored = coneScored(dedup(found).filter(Self.passesAmbientQuality), from: origin,
                                headingDegrees: headingDegrees, coneDegrees: coneDegrees,
                                radius: Self.scanRadius)
        // Collapse AFTER cone scoring so a twin outside the cone can never evict the listing the user is aiming at.
        let curated = collapseSameName(scored.map(\.place))
        return .success(Array(curated.prefix(6)))
    }

    private func sampledNearby(center: CLLocationCoordinate2D,
                               radiusMeters: Double) async -> Result<[Place], Error> {
        do {
            return .success(try await GooglePlacesService.shared.nearbySearch(
                center: center, radiusMeters: radiusMeters, pageSize: 20))
        } catch {
            return .failure(error)
        }
    }

    // Internal (not private) so the curation pipeline is unit-testable as pure functions.
    /// Ambient-only quality gate for generic retail: an unrated or poorly rated shop on a residential street is noise, not discovery (field-tested against 2.1-star twin banks and unrated junk shops). Accepted tradeoff: suppresses brand-new/unrated venues. Search still returns everything.
    static func passesAmbientQuality(_ place: Place) -> Bool {
        switch place.category {
        case .shop, .grocery, .other:
            return place.reviewCount > 0 && place.rating >= 3.5
        default:
            return true
        }
    }

    /// Two listings for one brand in one plaza (a branch plus its walk-up counter) must not float as twin bubbles. Input is ordered best-first, so the first of a pair wins. Accepted tradeoff: may merge genuinely distinct chain branches within 150 m.
    func collapseSameName(_ places: [Place]) -> [Place] {
        var kept: [Place] = []
        for candidate in places {
            let name = candidate.name.lowercased()
            let isTwin = kept.contains { existing in
                existing.name.lowercased() == name
                    && distanceMeters(from: existing.arCoordinate, to: candidate.arCoordinate) <= 150
            }
            if !isTwin { kept.append(candidate) }
        }
        return kept
    }

    func coneScored(_ candidates: [Place],
                            from origin: CLLocationCoordinate2D,
                            headingDegrees: Double,
                            coneDegrees: Double,
                            radius: CLLocationDistance) -> [(place: Place, score: Double)] {
        let halfCone = max(coneDegrees / 2, 1)
        return candidates
            .compactMap { candidate in
                // Aim at the street-side anchor: a mall-facing entrance sits in a different part of the cone than the venue centroid.
                let bearing = ARProjector.bearing(from: origin, to: candidate.arCoordinate)
                let delta = abs(Angles.shortestDelta(from: headingDegrees, to: bearing))
                guard delta <= halfCone + 4 else { return nil }
                let distance = distanceMeters(from: origin, to: candidate.arCoordinate)
                let score = (delta / halfCone) * 0.6 + (distance / radius) * 0.4
                return (candidate, score)
            }
            .sorted { $0.score < $1.score }
    }

    // MARK: - Far-landmark pass

    private func farLandmarkPass(from origin: CLLocationCoordinate2D,
                                 headingDegrees: Double) async -> Result<[Place], Error> {
        do {
            let ahead = destination(from: origin, bearingDegrees: headingDegrees, distanceMeters: 2500)

            // Two far sources in parallel: type-gated attractions in a hard circle ahead (an amusement park never matches a "famous landmarks" text search), plus the text pass whose location bias leaks far enough to catch CN-Tower-class outliers.
            async let typedTask = GooglePlacesService.shared.attractionSearch(
                center: ahead, radiusMeters: 6000, pageSize: 15)
            async let famousTask = GooglePlacesService.shared.textSearch(
                query: "famous landmarks", center: ahead, radiusMeters: 6000, pageSize: 15)

            var candidates: [Place] = []
            var firstError: Error?
            do { candidates += try await typedTask } catch { firstError = error }
            do { candidates += try await famousTask } catch { if firstError == nil { firstError = error } }
            // One source down is a degraded scan; both down is a real failure.
            if candidates.isEmpty, let firstError { throw firstError }

            let found = coneGatedFar(dedup(candidates), origin: origin, headingDegrees: headingDegrees)

            // Delta first, then distance: a genuinely-ahead near landmark must beat a 25 km outlier at the same angle.
            // Bucketed, because two continuous deltas never compare equal and the distance key would never be reached.
            let landmarks = found
                .sorted {
                    let (a, b) = (Self.angleBucket($0.delta), Self.angleBucket($1.delta))
                    return a != b ? a < b : $0.distance < $1.distance
                }
                .prefix(3)
                .map { candidate -> Place in
                    var landmark = candidate.place
                    landmark.isFarLandmark = true
                    if landmark.category != .museum { landmark.category = .landmark }
                    return landmark
                }
            return .success(Array(landmarks))
        } catch {
            return .failure(error)
        }
    }

    /// Half-degree buckets: landmarks this close in bearing count as "the same direction" and rank by proximity instead.
    private static func angleBucket(_ delta: Double) -> Double {
        (delta * 2).rounded(.down) / 2
    }

    /// Keeps only candidates genuinely ahead and in the honest far band. Floor at 350 m: a huge venue's centroid (standing at an amusement park's gate) must not fall between the near radius and the old 500 m floor.
    private func coneGatedFar(_ places: [Place],
                              origin: CLLocationCoordinate2D,
                              headingDegrees: Double) -> [(place: Place, delta: Double, distance: CLLocationDistance)] {
        places.compactMap { candidate in
            let bearing = ARProjector.bearing(from: origin, to: candidate.arCoordinate)
            let delta = abs(Angles.shortestDelta(from: headingDegrees, to: bearing))
            guard delta <= 20 else { return nil }
            let distance = distanceMeters(from: origin, to: candidate.arCoordinate)
            guard distance >= 350, distance <= 25_000 else { return nil }
            return (candidate, delta, distance)
        }
    }

    private func dedup(_ places: [Place]) -> [Place] {
        var seen = Set<String>()
        return places.filter { seen.insert($0.id).inserted }
    }

    // MARK: - Geodesy

    private func distanceMeters(from a: CLLocationCoordinate2D,
                                to b: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    /// Standard great-circle destination point.
    private func destination(from origin: CLLocationCoordinate2D,
                             bearingDegrees bearing: Double,
                             distanceMeters distance: CLLocationDistance) -> CLLocationCoordinate2D {
        let earthRadius = 6_371_000.0
        let angular = distance / earthRadius
        let theta = bearing * .pi / 180
        let lat1 = origin.latitude * .pi / 180
        let lon1 = origin.longitude * .pi / 180

        let lat2 = asin(sin(lat1) * cos(angular) + cos(lat1) * sin(angular) * cos(theta))
        let lon2 = lon1 + atan2(sin(theta) * sin(angular) * cos(lat1),
                                cos(angular) - sin(lat1) * sin(lat2))
        var lonDegrees = lon2 * 180 / .pi
        lonDegrees = (lonDegrees + 540).truncatingRemainder(dividingBy: 360) - 180
        return CLLocationCoordinate2D(latitude: lat2 * 180 / .pi, longitude: lonDegrees)
    }
}
