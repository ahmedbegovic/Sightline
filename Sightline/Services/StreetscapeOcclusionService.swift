import Foundation
import Combine
import CoreLocation
import UIKit

/// Schedules raycast probes against the AR path and publishes which places are hidden behind something.
/// Every cache here is in memory and session-scoped — no occlusion-derived data is ever persisted.
@MainActor
final class StreetscapeOcclusionService: ObservableObject {

    /// Place ids currently judged occluded. In-memory only, never persisted.
    @Published private(set) var occludedIDs: Set<String> = []

    // MARK: - Tuning

    /// The scheduler wakes this often; an evaluation only runs when one of the triggers below is met.
    private static let tickInterval: TimeInterval = 1
    /// Re-evaluate at least this often even when standing still.
    private static let evaluationInterval: TimeInterval = 3
    /// Or immediately after moving this far, because a step sideways changes what a wall hides.
    private static let movementThresholdMeters: CLLocationDistance = 10
    /// Streetscape meshes stream in over several seconds; hiding needs two agreeing verdicts, showing needs one.
    private static let occludedStreakToHide = 2
    /// Base ray at storefront height — kerbs and parked cars sit below even this.
    private static let baseAimHeightMeters: Double = 2
    /// Mid ray above kerbs, cars and hedges.
    private static let midAimHeightMeters: Double = 8
    /// Top ray for ordinary places; a roofline clearing this genuinely hides the whole building.
    private static let topAimHeightMeters: Double = 15
    /// Landmark-class places are assumed tall — their top ray aims well above the local roofline.
    private static let landmarkTopAimHeightMeters: Double = 40

    /// Each place is probed at three heights; a tall landmark can be clear up top while its doorway is walled off.
    private enum RayTier: String, CaseIterable {
        case base, mid, top
    }

    // MARK: - State

    private struct Candidate {
        let id: String
        let coordinate: CLLocationCoordinate2D
        let isFarLandmark: Bool
        /// True when the aim point is a published street-side anchor rather than a possibly deep-footprint centroid.
        let hasStreetAnchor: Bool
    }

    private weak var source: (any OcclusionProbeSource)?
    private var candidates: [Candidate] = []
    /// Consecutive occluded verdicts per place; reset by any visible verdict or missing sample.
    private var streaks: [String: Int] = [:]
    private var loop: Task<Void, Never>?
    private var lastEvaluation: Date?
    private var lastEvaluationCoordinate: CLLocationCoordinate2D?
    private var forceEvaluation = false
    private var isEvaluating = false
    private var cancellables: Set<AnyCancellable> = []

    init(source: (any OcclusionProbeSource)?) {
        self.source = source
        observeAppLifecycle()
    }

    deinit {
        loop?.cancel()
    }

    // MARK: - Input

    /// New scan/search results: replaces the candidate set and forces an immediate evaluation.
    func setCandidates(_ places: [Place]) {
        let next = places.map {
            Candidate(id: $0.id, coordinate: $0.arCoordinate,
                      isFarLandmark: $0.isFarLandmark,
                      hasStreetAnchor: $0.anchorCoordinate != nil)
        }
        let changed = next.map(\.id) != candidates.map(\.id)
        candidates = next
        // A different candidate set invalidates every streak — verdicts are per result set.
        if changed { streaks.removeAll() }
        forceEvaluation = true
        if candidates.isEmpty {
            stopLoop()
            clearVerdicts()
        } else if source?.isLocalizedForOcclusion == true {
            // On the simulator and every fallback session there is nothing to ask, so no scheduler runs at all.
            startLoop()
        }
    }

    /// The AR path can answer again; re-arm the scheduler that `tick()` parked while it could not.
    func sourceDidLocalize() {
        guard !candidates.isEmpty else { return }
        forceEvaluation = true
        startLoop()
    }

    /// Backend demoted, results cleared, or the app backgrounded.
    func reset() {
        stopLoop()
        candidates = []
        clearVerdicts()
        lastEvaluation = nil
        lastEvaluationCoordinate = nil
        forceEvaluation = false
    }

    // MARK: - App lifecycle

    /// A backgrounded ARSession can answer nothing — stop the scheduler rather than tick questions into the void.
    private func observeAppLifecycle() {
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in self?.stopLoop() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in self?.resumeAfterForeground() }
            .store(in: &cancellables)
    }

    /// Candidates and verdicts survive the background trip; the first foreground tick re-evaluates immediately.
    private func resumeAfterForeground() {
        guard !candidates.isEmpty else { return }
        forceEvaluation = true
        startLoop()
    }

    // MARK: - Scheduling

    private func startLoop() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: UInt64(Self.tickInterval * 1_000_000_000))
            }
        }
    }

    private func stopLoop() {
        loop?.cancel()
        loop = nil
    }

    private func clearVerdicts() {
        streaks.removeAll()
        if !occludedIDs.isEmpty { occludedIDs = [] }
    }

    private func tick() async {
        guard !isEvaluating, !candidates.isEmpty else { return }
        // Not localized or a fallback backend: no answers ever, so park the scheduler until the phase sink re-arms it.
        guard let source, source.isLocalizedForOcclusion, let origin = source.localizedCoordinate else {
            clearVerdicts()
            stopLoop()
            return
        }
        // Localized but the meshes are still streaming in — that resolves within seconds, so keep ticking.
        guard source.hasStreetscapeGeometry else {
            clearVerdicts()
            return
        }

        let now = Date()
        var isDue = forceEvaluation
        if !isDue, let last = lastEvaluation, now.timeIntervalSince(last) >= Self.evaluationInterval { isDue = true }
        if !isDue, lastEvaluation == nil { isDue = true }
        if !isDue, let last = lastEvaluationCoordinate,
           distanceMeters(from: last, to: origin) > Self.movementThresholdMeters { isDue = true }
        guard isDue else { return }

        forceEvaluation = false
        lastEvaluation = now
        lastEvaluationCoordinate = origin

        let probes = candidates.flatMap { candidate in
            RayTier.allCases.map { tier in
                OcclusionProbe(id: Self.probeID(candidate.id, tier),
                               latitude: candidate.coordinate.latitude,
                               longitude: candidate.coordinate.longitude,
                               aimHeightMeters: Self.aimHeight(for: tier, isFarLandmark: candidate.isFarLandmark))
            }
        }

        isEvaluating = true
        let samples = await source.sampleOcclusion(probes)
        isEvaluating = false
        apply(samples)
    }

    // MARK: - Verdicts

    /// Place ids are URL-safe strings, so `#` can never occur in one — the tier rides inside the id the engine echoes back.
    private static func probeID(_ candidateID: String, _ tier: RayTier) -> String {
        "\(candidateID)#\(tier.rawValue)"
    }

    private static func aimHeight(for tier: RayTier, isFarLandmark: Bool) -> Double {
        switch tier {
        case .base: return baseAimHeightMeters
        case .mid: return midAimHeightMeters
        case .top: return isFarLandmark ? landmarkTopAimHeightMeters : topAimHeightMeters
        }
    }

    private func apply(_ samples: [OcclusionSample]) {
        // An empty answer set means the AR path could not measure anything — fail open.
        guard !samples.isEmpty else {
            clearVerdicts()
            return
        }

        var byID: [String: OcclusionSample] = [:]
        byID.reserveCapacity(samples.count)
        for sample in samples { byID[sample.id] = sample }

        var next: Set<String> = []
        var nextStreaks: [String: Int] = [:]
        for candidate in candidates {
            // A centroid aim point can sit deep in its own building, so its facade needs a much wider self-hit allowance.
            let allowance = candidate.hasStreetAnchor
                ? OcclusionPolicy.minSeparationMeters
                : OcclusionPolicy.centroidSeparationMeters
            var answered = 0
            var blocked = 0
            for tier in RayTier.allCases {
                // A missing ray is a missing answer, not a hidden place.
                guard let sample = byID[Self.probeID(candidate.id, tier)] else { continue }
                answered += 1
                if OcclusionPolicy.isOccluded(targetDistance: sample.targetDistanceMeters,
                                              nearestBuildingHit: sample.nearestBuildingHitMeters,
                                              nearestTerrainHit: sample.nearestTerrainHitMeters,
                                              selfHitAllowanceMeters: allowance) { blocked += 1 }
            }
            // Hidden only when every tier answered and every ray is blocked — one clear ray means the place peeks out somewhere.
            guard answered == RayTier.allCases.count, blocked == answered else { continue }
            let streak = (streaks[candidate.id] ?? 0) + 1
            nextStreaks[candidate.id] = streak
            if streak >= Self.occludedStreakToHide { next.insert(candidate.id) }
        }

        streaks = nextStreaks
        if next != occludedIDs { occludedIDs = next }
    }

    private func distanceMeters(from a: CLLocationCoordinate2D,
                                to b: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }
}
