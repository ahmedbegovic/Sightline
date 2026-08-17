import Foundation
import CoreLocation

/// Where the current result set came from — long-range bubbles are only honest for a deliberate scan.
enum ResultsSource: Equatable { case scanCone, search, other }

/// Governs long-range results only. Landmarks get no fame exemption: surviving this still means facing the raycast.
enum LandmarkVisibilityPolicy {

    /// Nothing beyond this shows a bubble unless it came from a fresh, explicit scan.
    static let fallbackMaxBubbleMeters: CLLocationDistance = 1000
    /// Long-range results go stale — this is the "still floating over a dark street all night" fix.
    static let scanContextMaxAge: TimeInterval = 10 * 60
    /// Walk this far from where the scan was taken and its far landmarks no longer describe what's ahead.
    static let scanContextMaxDriftMeters: CLLocationDistance = 250

    struct Context {
        /// The AR path is up but has not localized: nothing on screen can be verified, so long-range claims are withheld.
        /// False on every fallback/simulator session by construction — that path is unchanged.
        var isGeoARAwaitingLocalization: Bool = false
        var resultsSource: ResultsSource = .other
        var scanOrigin: CLLocationCoordinate2D?
        var scanTimestamp: Date?
        var userCoordinate: CLLocationCoordinate2D?
        var now: Date = Date()
    }

    /// Ids to hide. Never hides near places; only governs long-range results.
    static func hiddenIDs(in places: [Place], context: Context) -> Set<String> {
        // No fix means no distance, and no distance means no verdict — fail open.
        guard let user = context.userCoordinate else { return [] }
        // A search is explicit intent: its bubbles are a compass to walk by, at any range (field test 2026-08-16 — a "4 results" pill with zero bubbles reads as broken).
        if context.resultsSource == .search { return [] }
        // Indoors the AR path cannot localize, so a bubble kilometres away would be a claim about a room.
        let hidesLongRange = context.isGeoARAwaitingLocalization
            || context.resultsSource != .scanCone
            || !isScanContextFresh(context, userCoordinate: user)
        guard hidesLongRange else { return [] }

        var hidden: Set<String> = []
        for place in places {
            // Allocation-free: this runs at 1 Hz for the life of a result set.
            let distance = ARProjector.distanceMeters(from: user, to: place.arCoordinate)
            // Near places are never touched here; occlusion may still hide them.
            if distance > fallbackMaxBubbleMeters { hidden.insert(place.id) }
        }
        return hidden
    }

    /// True when the set contains a long-range claim — the only thing this policy can ever hide, and the only reason to keep ticking.
    static func containsLongRange(_ places: [Place], userCoordinate: CLLocationCoordinate2D?) -> Bool {
        guard let user = userCoordinate else { return false }
        return places.contains {
            ARProjector.distanceMeters(from: user, to: $0.arCoordinate) > fallbackMaxBubbleMeters
        }
    }

    /// A scan describes what was ahead at one place and moment; outside that it is a stale claim.
    private static func isScanContextFresh(_ context: Context,
                                           userCoordinate: CLLocationCoordinate2D) -> Bool {
        guard let origin = context.scanOrigin, let timestamp = context.scanTimestamp else { return false }
        guard context.now.timeIntervalSince(timestamp) <= scanContextMaxAge else { return false }
        return ARProjector.distanceMeters(from: userCoordinate, to: origin) <= scanContextMaxDriftMeters
    }
}

#if DEBUG
extension LandmarkVisibilityPolicy {
    /// One-shot assertions run from AppState.start() in DEBUG; this project has no test target.
    static func selfTest() {
        let user = CLLocationCoordinate2D(latitude: 43.7700, longitude: -79.5100)
        let now = Date()

        func place(_ id: String, metresNorth: Double) -> Place {
            // ~111_320 m per degree of latitude is close enough for a threshold test.
            let coordinate = CLLocationCoordinate2D(latitude: 43.7700 + metresNorth / 111_320,
                                                   longitude: -79.5100)
            return Place(id: id, name: id, category: .landmark, coordinate: coordinate)
        }

        let near = place("near", metresNorth: 400)
        let far = place("far", metresNorth: 4200)
        let places = [near, far]

        // Fresh scan: the far landmark survives and goes on to face the raycast.
        let fresh = Context(resultsSource: .scanCone, scanOrigin: user, scanTimestamp: now,
                            userCoordinate: user, now: now)
        assert(hiddenIDs(in: places, context: fresh).isEmpty)

        // Search results keep their bubbles at any range — the user asked for exactly these places.
        let searched = Context(resultsSource: .search, scanOrigin: nil, scanTimestamp: nil,
                               userCoordinate: user, now: now)
        assert(hiddenIDs(in: places, context: searched).isEmpty)

        // The all-night case: same scan, eleven minutes later.
        let stale = Context(resultsSource: .scanCone, scanOrigin: user,
                            scanTimestamp: now.addingTimeInterval(-11 * 60),
                            userCoordinate: user, now: now)
        assert(hiddenIDs(in: places, context: stale) == ["far"])

        // Walked 300 m from where the scan was taken.
        let drifted = Context(resultsSource: .scanCone,
                              scanOrigin: CLLocationCoordinate2D(latitude: 43.7700 - 300 / 111_320,
                                                                 longitude: -79.5100),
                              scanTimestamp: now, userCoordinate: user, now: now)
        assert(hiddenIDs(in: places, context: drifted) == ["far"])

        // Ambient results with no scan context at all.
        let ambient = Context(resultsSource: .other, userCoordinate: user, now: now)
        assert(hiddenIDs(in: places, context: ambient) == ["far"])

        // No location fix: fail open rather than blank the screen.
        let noFix = Context(resultsSource: .other, userCoordinate: nil, now: now)
        assert(hiddenIDs(in: places, context: noFix).isEmpty)

        // The couch case: AR path up but not localized, so the far landmark is withheld even for a fresh scan.
        let indoors = Context(isGeoARAwaitingLocalization: true, resultsSource: .scanCone,
                              scanOrigin: user, scanTimestamp: now, userCoordinate: user, now: now)
        assert(hiddenIDs(in: places, context: indoors) == ["far"])
        // Near results are never touched by the indoor rule — they exist at street level.
        assert(hiddenIDs(in: [near], context: indoors).isEmpty)
        // Localization landing after the scan releases the same landmark: the rule is context-derived, so catch-up is free.
        assert(hiddenIDs(in: places, context: fresh).isEmpty)

        assert(containsLongRange(places, userCoordinate: user))
        assert(containsLongRange([near], userCoordinate: user) == false)
        assert(containsLongRange(places, userCoordinate: nil) == false)
    }
}
#endif
