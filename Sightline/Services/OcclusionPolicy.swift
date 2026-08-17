import Foundation

/// Turns one raycast measurement into a hide/show verdict. Pure, so the whole rule is testable in the simulator.
enum OcclusionPolicy {

    /// A building this much nearer than the target counts as blocking.
    static let buildingNearFraction = 0.85
    /// Terrain only blocks when it's much nearer — a hill, not the road under our feet.
    static let terrainNearFraction = 0.50
    /// The target must be this far beyond the hit before we believe the hit isn't the target itself.
    static let minSeparationMeters = 10.0
    /// A centroid aim point sits deep inside its own footprint, so its facade is hit far short of the aim point.
    static let centroidSeparationMeters = 60.0

    /// True = occluded (hide the bubble). Every unknown resolves to false — fail open.
    /// `allowance` is how far short of the target its own facade may be hit; street-side anchors need only the default.
    static func isOccluded(targetDistance d: Double,
                           nearestBuildingHit building: Double?,
                           nearestTerrainHit terrain: Double?,
                           selfHitAllowanceMeters allowance: Double = minSeparationMeters) -> Bool {
        // A degenerate or missing range tells us nothing.
        guard d > 1 else { return false }
        // 0.85 * d lets the ray graze the target's own facade — a shop at 47 m hit at 45 m is not occluded.
        // The separation is the second guard against self-hits and mesh inflation.
        if let building, building < buildingNearFraction * d, d - building > allowance { return true }
        // Terrain is never the target's own facade, so it keeps the ordinary separation guard.
        // The ground plane is always "in front of us" at grazing angles; only a genuine hill qualifies.
        if let terrain, terrain < terrainNearFraction * d, d - terrain > minSeparationMeters { return true }
        // No hit at all means the ray cleared every local mesh — the CN-Tower-over-rooftops case is visible on purpose.
        return false
    }
}

#if DEBUG
extension OcclusionPolicy {
    /// One-shot assertions run from AppState.start() in DEBUG; this project has no test target.
    static func selfTest() {
        // House at 47 m, the ray grazes its own facade at 45 m.
        assert(isOccluded(targetDistance: 47, nearestBuildingHit: 45, nearestTerrainHit: nil) == false)
        // Target 300 m down the block, a row of houses at 40 m.
        assert(isOccluded(targetDistance: 300, nearestBuildingHit: 40, nearestTerrainHit: nil) == true)
        // CN Tower over the rooftops, ray clears everything.
        assert(isOccluded(targetDistance: 4200, nearestBuildingHit: nil, nearestTerrainHit: nil) == false)
        // Same tower, but the ray clips a near roof — something really is in the way.
        assert(isOccluded(targetDistance: 4200, nearestBuildingHit: 60, nearestTerrainHit: nil) == true)
        // Flat road running under the ray.
        assert(isOccluded(targetDistance: 300, nearestBuildingHit: nil, nearestTerrainHit: 280) == false)
        // A hill genuinely in the way.
        assert(isOccluded(targetDistance: 900, nearestBuildingHit: nil, nearestTerrainHit: 300) == true)
        // No geometry / not localized.
        assert(isOccluded(targetDistance: 120, nearestBuildingHit: nil, nearestTerrainHit: nil) == false)
        // Degenerate range.
        assert(isOccluded(targetDistance: 0.4, nearestBuildingHit: 0.1, nearestTerrainHit: nil) == false)
        // Close target, hit well inside the fraction but only 7 m nearer — the separation guard keeps it visible.
        assert(isOccluded(targetDistance: 15, nearestBuildingHit: 8, nearestTerrainHit: nil) == false)
        // A 100 m-deep mall aimed at its centroid: the 200 m hit is its own facade, so it must stay visible.
        assert(isOccluded(targetDistance: 250, nearestBuildingHit: 200, nearestTerrainHit: nil,
                          selfHitAllowanceMeters: centroidSeparationMeters) == false)
        // The same geometry for a street-side anchor really is something in the way.
        assert(isOccluded(targetDistance: 250, nearestBuildingHit: 200, nearestTerrainHit: nil) == true)
        // The wider allowance still catches a genuine block: a row of houses 260 m short of the centroid.
        assert(isOccluded(targetDistance: 300, nearestBuildingHit: 40, nearestTerrainHit: nil,
                          selfHitAllowanceMeters: centroidSeparationMeters) == true)
    }
}
#endif
