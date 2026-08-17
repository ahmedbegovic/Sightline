import Foundation
import Combine
import CoreLocation
import SwiftUI
import UIKit

@MainActor
final class AppState: ObservableObject {
    let pose: PoseManager
    let scene: SceneBackendCoordinator
    private let occlusion: StreetscapeOcclusionService
    let router = RouteManager()

    /// Bubble ids hidden by occlusion or the landmark rule. Ephemeral — never stored on Place, never persisted.
    @Published private(set) var hiddenBubbleIDs: Set<String> = []

    /// Where the current result set came from, and when/where a scan was taken — the landmark rule's freshness inputs.
    private(set) var resultsSource: ResultsSource = .other
    private(set) var scanOrigin: CLLocationCoordinate2D?
    private(set) var scanTimestamp: Date?

    @Published var places: [Place] = []
    // Opening a card or the assistant is what triggers the on-demand rich-field fetch.
    @Published var selectedPlace: Place? {
        didSet { loadDetailsIfNeeded(for: selectedPlace) }
    }
    @Published var isMapExpanded = false
    @Published var assistantPlace: Place? {
        didSet { loadDetailsIfNeeded(for: assistantPlace) }
    }

    /// Scan/search HUD state lives here, not on AppState — see ScanUIModel.
    let scanUI = ScanUIModel()

    // Non-published pass-throughs: every existing read, write and withAnimation site keeps working unchanged.
    var scanState: ScanState {
        get { scanUI.state }
        set { scanUI.state = newValue }
    }
    var searchText: String {
        get { scanUI.search.text }
        set { scanUI.search.text = newValue }
    }
    var resultsLabel: String? {
        get { scanUI.resultsLabel }
        set { scanUI.resultsLabel = newValue }
    }

    private var started = false
    /// Sustained-unlocalized value behind the current scan-state decision; only a flip re-decides, so the toast never re-flashes on a steady signal.
    private var lastSustainedUnlocalized = false
    private var searchTask: Task<Void, Never>?
    private var resetTask: Task<Void, Never>?
    private var visibilityTask: Task<Void, Never>?
    private var policyTickTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init() {
        // Locals first: `self` is off limits until every stored property is assigned.
        let pose = PoseManager()
        let scene = SceneBackendCoordinator(pose: pose)
        self.pose = pose
        self.scene = scene
        // The AR path is the only occlusion source; on every other backend it answers "don't know" and everything shows.
        self.occlusion = StreetscapeOcclusionService(source: scene.geoAR)
    }

    func start() {
        guard !started else { return }
        started = true
        #if DEBUG
        // The XCTest suite in SightlineTests now covers these; the launch asserts stay as a belt-and-suspenders debug check.
        // Detached so five synchronous test sweeps stay out of the first-frame window; they are pure statics.
        Task.detached(priority: .utility) {
            OcclusionPolicy.selfTest()
            TransitStopIdentity.selfTest()
            LandmarkVisibilityPolicy.selfTest()
            Angles.selfTest()
            ScanFailurePolicy.selfTest()
        }
        #endif
        pose.start()
        // The coordinator decides which backend runs and starts exactly one of them.
        scene.start()
        observeVisibilityInputs()
        Prewarm.run()
    }

    // MARK: - Hidden bubbles

    private func observeVisibilityInputs() {
        occlusion.$occludedIDs
            .sink { [weak self] ids in self?.recomputeHiddenBubbleIDs(occluded: ids) }
            .store(in: &cancellables)
        // A demotion leaves stale verdicts behind; clearing them is the fail-open direction.
        scene.$backend
            .sink { [weak self] backend in
                guard let self, !backend.isGeoAR else { return }
                self.occlusion.reset()
            }
            .store(in: &cancellables)
        // The service parks its scheduler whenever the source can't answer; localizing is what re-arms it.
        // @Published fires in willSet, so hop a turn — otherwise this closure still reads the previous phase.
        scene.$phase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in
                guard let self else { return }
                if phase == .localized { self.occlusion.sourceDidLocalize() }
                // Long-range claims are gated on this phase; flipping it either way must re-decide immediately.
                self.recomputeHiddenBubbleIDs()
                // Localizing zeroes sustained-unlocalized instantly — don't leave a stale "step outside" up for the next tick.
                self.reevaluateNeedsOutdoors()
            }
            .store(in: &cancellables)
        // A backgrounded session can't answer visibility questions — park the 1 Hz tick instead of waking a suspended app's runtime.
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                self?.policyTickTask?.cancel()
                self?.policyTickTask = nil
            }
            .store(in: &cancellables)
        // startPolicyTick re-guards on places; the immediate re-decide beats waiting a tick for the first foreground answer.
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                self.startPolicyTick()
                self.recomputeHiddenBubbleIDs()
                self.reevaluateNeedsOutdoors()
            }
            .store(in: &cancellables)
    }

    /// Occlusion verdicts arrive on their own schedule; the landmark rule is time-based, so it also needs a tick.
    private func recomputeHiddenBubbleIDs(occluded: Set<String>? = nil) {
        let occludedIDs = occluded ?? occlusion.occludedIDs
        let context = LandmarkVisibilityPolicy.Context(
            isGeoARAwaitingLocalization: scene.backend.isGeoAR && scene.phase != .localized,
            resultsSource: resultsSource,
            scanOrigin: scanOrigin,
            scanTimestamp: scanTimestamp,
            userCoordinate: pose.pose.coordinate,
            now: Date())
        let next = occludedIDs.union(LandmarkVisibilityPolicy.hiddenIDs(in: places, context: context))
        guard next != hiddenBubbleIDs else { return }
        hiddenBubbleIDs = next
    }

    private func startPolicyTick() {
        policyTickTask?.cancel()
        // Long range is a function of where the user is standing now, so the tick can't be gated on today's answer.
        guard !places.isEmpty else {
            policyTickTask = nil
            return
        }
        policyTickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.recomputeHiddenBubbleIDs()
                // The 15 s sustained-unlocalized clock can cross after results land; this tick is what notices.
                self.reevaluateNeedsOutdoors()
            }
        }
    }

    // MARK: - Scan

    func scan() {
        // A tap while scanning cancels instead of no-opping, so a slow request never locks the button.
        if scanState == .scanning {
            searchTask?.cancel()
            scanState = .idle
            return
        }
        guard let location = pose.pose.location else {
            flash(.failed(.noLocationFix))
            return
        }
        // Simulator metadata is synthetic (parked fallback fix, simctl injection, virtual compass) — nothing real to judge.
        // compassMeasuredUnreliable needs an actual degraded sample, so compass warm-up and the post-AR-demotion window still scan (as the baseline did); only measured compass trouble refuses.
        if !pose.isSimulated,
           let failure = ScanFailurePolicy.sensorFailure(location: location,
                                                         compassUnreliable: pose.compassMeasuredUnreliable) {
            flash(.failed(failure))
            return
        }
        let coordinate = location.coordinate
        // No haptic here: ScanButton ticks on press-down, and firing both double-taps the Taptic engine.
        scanState = .scanning
        let heading = pose.pose.headingDegrees
        // Long-range bubbles are only honest for a deliberate scan, taken here and now — applied only if results land.
        let context = ResultsContext(source: .scanCone, scanOrigin: coordinate, scanTimestamp: Date())
        searchTask?.cancel()
        searchTask = Task {
            do {
                let found = try await PlacesService.shared.scanCone(
                    from: coordinate, headingDegrees: heading,
                    coneDegrees: PlacesService.scanConeDegrees)
                guard !Task.isCancelled else { return }
                apply(results: found, label: found.isEmpty ? nil : "\(found.count) nearby",
                      context: context)
            } catch {
                guard !Task.isCancelled else { return }
                flash(.failed(ScanFailurePolicy.classify(error)))
            }
        }
    }

    // MARK: - Search

    func search() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        guard let coordinate = pose.pose.coordinate else {
            flash(.failed(.noLocationFix))
            return
        }
        scanState = .scanning
        // Search results keep their bubbles at any range — explicit intent is its own claim.
        let context = ResultsContext(source: .search, scanOrigin: nil, scanTimestamp: nil)
        searchTask?.cancel()
        searchTask = Task {
            do {
                let found = try await PlacesService.shared.searchNearby(
                    query: query, around: coordinate, radius: 5000)
                guard !Task.isCancelled else { return }
                apply(results: found,
                      label: found.isEmpty ? nil : "\(found.count) results for “\(query)”",
                      context: context)
            } catch {
                guard !Task.isCancelled else { return }
                flash(.failed(ScanFailurePolicy.classify(error)))
            }
        }
    }

    func clearResults() {
        searchTask?.cancel()
        visibilityTask?.cancel()
        policyTickTask?.cancel()
        policyTickTask = nil
        occlusion.reset()
        resultsSource = .other
        scanOrigin = nil
        scanTimestamp = nil
        lastSustainedUnlocalized = false
        hiddenBubbleIDs = []
        withAnimation(Theme.Motion.standard) {
            places = []
            selectedPlace = nil
            resultsLabel = nil
            searchText = ""
            scanState = .idle
        }
    }

    // MARK: - Navigation

    func navigate(to place: Place) {
        guard let coordinate = pose.pose.coordinate else { return }
        withAnimation(Theme.Motion.standard) {
            selectedPlace = nil
            isMapExpanded = false
        }
        Task { await router.startNavigation(to: place, from: coordinate) }
    }

    func stopNavigation() {
        router.stop()
    }

    // MARK: - Private

    /// The provenance of one result set. Applied with the results, never at request time — a failed request must not relabel what is still on screen.
    private struct ResultsContext {
        let source: ResultsSource
        let scanOrigin: CLLocationCoordinate2D?
        let scanTimestamp: Date?
    }

    private func apply(results: [Place], label: String?, context: ResultsContext) {
        // Fresh discovery results carry no rich fields; details already loaded for the same id ride along.
        var results = results
        let loaded = Dictionary(places.compactMap { place in place.details.map { (place.id, $0) } },
                                uniquingKeysWith: { first, _ in first })
        if !loaded.isEmpty {
            for index in results.indices where results[index].details == nil {
                results[index].details = loaded[results[index].id]
            }
        }
        resultsSource = context.source
        scanOrigin = context.scanOrigin
        scanTimestamp = context.scanTimestamp
        // Indoors the AR path never localizes: say so instead of counting bubbles that will never be placed.
        // Only a scan can ever carry long-range bubbles, and only a sustained failure to localize means "indoors" —
        // during ordinary outdoor convergence the localizing pill already says the right thing.
        let sustainedUnlocalized = scene.isSustainedUnlocalized
        lastSustainedUnlocalized = sustainedUnlocalized
        let withholdsLongRange = context.source == .scanCone
            && sustainedUnlocalized
            && LandmarkVisibilityPolicy.containsLongRange(results, userCoordinate: pose.pose.coordinate)

        places = results
        resultsLabel = label
        scanState = results.isEmpty ? .empty : (withholdsLongRange ? .needsOutdoors : .found)
        // Keep an open detail card in sync when fresh data arrives for the same place.
        if let current = selectedPlace,
           let fresh = results.first(where: { $0.id == current.id }) {
            selectedPlace = fresh
        }
        if !results.isEmpty { Haptics.success() }
        scheduleScanStateReset()
        refreshStreetVisibility(for: results)
        // Occlusion enforces "bubble = physically visible" for discovery; a search bubble is a compass the user asked for, so it must survive a building in the way.
        occlusion.setCandidates(context.source == .search ? [] : results)
        startPolicyTick()
        recomputeHiddenBubbleIDs()
    }

    /// needsOutdoors is decided when results land, but the sustained-unlocalized clock keeps running afterwards — a later flip in either direction re-decides it.
    private func reevaluateNeedsOutdoors() {
        // An in-flight scan re-derives on landing; apply() resyncs the flip tracker, absorbing anything skipped here.
        guard scanState != .scanning else { return }
        let sustained = scene.isSustainedUnlocalized
        guard sustained != lastSustainedUnlocalized else { return }
        lastSustainedUnlocalized = sustained
        // Search results are exempt by design: explicit intent shows at any range, indoors included.
        guard resultsSource == .scanCone, !places.isEmpty else { return }
        if sustained {
            // Long range is a function of where the user stands now, so it is re-asked, not cached from apply().
            guard LandmarkVisibilityPolicy.containsLongRange(places, userCoordinate: pose.pose.coordinate) else { return }
            scanState = .needsOutdoors
            scheduleScanStateReset()
        } else if scanState == .needsOutdoors {
            // Localization arrived: the withheld long-range bubbles are placeable now, so the hint would be a lie.
            scanState = .found
            scheduleScanStateReset()
        }
    }

    // MARK: - Street-visibility demotion

    /// Probes Street View in the background and re-ranks when the answers land; bubbles never wait on it.
    private func refreshStreetVisibility(for results: [Place]) {
        visibilityTask?.cancel()
        // Every source is probed: the metadata endpoint needs only a lat/lng, and a failed probe stays neutral on its own.
        let probes = results.map { StreetViewProbe(id: $0.id, coordinate: $0.arCoordinate) }
        guard !probes.isEmpty else { return }

        visibilityTask = Task { [weak self] in
            let verdicts = await StreetViewVisibilityService.shared.verdicts(for: probes)
            guard !Task.isCancelled, let self else { return }
            self.applyVisibility(verdicts)
        }
    }

    private func applyVisibility(_ verdicts: [String: Bool]) {
        var updated = places
        var changed = false
        for index in updated.indices {
            guard let unlikely = verdicts[updated[index].id],
                  updated[index].streetVisibilityUnlikely != unlikely else { continue }
            updated[index].streetVisibilityUnlikely = unlikely
            changed = true
        }
        guard changed else { return }
        places = updated
        if let current = selectedPlace,
           let fresh = updated.first(where: { $0.id == current.id }) {
            selectedPlace = fresh
        }
    }

    // MARK: - On-demand place details

    /// Second-stage fetch for rich listing fields; the service dedupes and caches per id, so repeat opens are free.
    private func loadDetailsIfNeeded(for place: Place?) {
        guard let place, place.details == nil else { return }
        Task { [weak self] in
            do {
                let details = try await GooglePlacesService.shared.placeDetails(id: place.id)
                self?.attach(details, to: place.id, includingResults: true)
            } catch {
                // No hard error: the open card falls back to discovery fields. The result set keeps details nil, so the next open retries.
                self?.attach(PlaceDetails(), to: place.id, includingResults: false)
            }
        }
    }

    private func attach(_ details: PlaceDetails, to id: String, includingResults: Bool) {
        if includingResults,
           let index = places.firstIndex(where: { $0.id == id }),
           places[index].details != details {
            places[index].details = details
        }
        // Enriching in place re-fires the didSet observers; their details-loaded guard is what stops the loop.
        if var current = selectedPlace, current.id == id, current.details != details {
            current.details = details
            selectedPlace = current
        }
        if var current = assistantPlace, current.id == id, current.details != details {
            current.details = details
            assistantPlace = current
        }
    }

    private func flash(_ state: ScanState) {
        // A failed scan or search otherwise gives no feedback at all.
        Haptics.warning()
        scanState = state
        scheduleScanStateReset()
    }

    private func scheduleScanStateReset() {
        resetTask?.cancel()
        resetTask = Task {
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            guard !Task.isCancelled, scanState != .scanning else { return }
            withAnimation(.easeOut(duration: 0.3)) { scanState = .idle }
        }
    }
}
