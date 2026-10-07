import Foundation
import CoreLocation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    let pose: PoseManager
    let camera: ARCameraEngine
    let router = RouteManager()

    @Published var places: [Place] = []
    // Opening a card or the guide is what triggers the on-demand Google fetch.
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
    private var searchTask: Task<Void, Never>?
    private var resetTask: Task<Void, Never>?

    init() {
        let pose = PoseManager()
        self.pose = pose
        self.camera = ARCameraEngine(pose: pose)
    }

    func start() {
        guard !started else { return }
        started = true
        pose.start()
        camera.start()
        Prewarm.run()
    }

    /// An ARSession left running in the background is a battery and thermal problem.
    func pauseForBackground() {
        pose.pauseForBackground()
        camera.pause()
    }

    func resumeForForeground() {
        pose.resumeForForeground()
        camera.resume()
    }

    // MARK: - Scan

    /// Identifies what the camera sees right now and pops up the card for the main subject.
    func scan() {
        // A tap while scanning cancels instead of no-opping, so a slow request never locks the button.
        if scanState == .scanning {
            searchTask?.cancel()
            scanState = .idle
            return
        }
        scanState = .scanning
        searchTask?.cancel()
        searchTask = Task {
            let frame = await camera.capture()
            #if !targetEnvironment(simulator)
            // The simulator has no camera and scans from candidates alone; a device without a frame has nothing to look at.
            guard frame.image != nil else { return flash(.failed(.noCamera)) }
            #endif
            do {
                let found = try await SceneIdentifier.identify(frame)
                guard !Task.isCancelled else { return }
                let label = found.count > 1 ? "\(found.count) things recognised" : found.first?.name
                apply(results: found, label: label)
                // The pop-up: the thing the user aimed at gets its card straight away.
                if let first = found.first {
                    withAnimation(Theme.Motion.gentle) { selectedPlace = first }
                }
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
        scanState = .scanning
        let near = pose.pose.coordinate
        searchTask?.cancel()
        searchTask = Task {
            do {
                let found = try await MapKitPlaces.search(query, near: near)
                guard !Task.isCancelled else { return }
                apply(results: found,
                      label: found.isEmpty ? nil : "\(found.count) results for “\(query)”")
            } catch {
                guard !Task.isCancelled else { return }
                flash(.failed(ScanFailurePolicy.classify(error)))
            }
        }
    }

    func clearResults() {
        searchTask?.cancel()
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
        guard place.isLocated, let coordinate = pose.pose.coordinate else { return }
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

    private func apply(results: [Place], label: String?) {
        // Details already loaded for the same id ride along.
        var results = results
        let loaded = Dictionary(places.compactMap { place in place.details.map { (place.id, $0) } },
                                uniquingKeysWith: { first, _ in first })
        for index in results.indices where results[index].details == nil {
            results[index].details = loaded[results[index].id]
        }
        places = results
        resultsLabel = label
        scanState = results.isEmpty ? .empty : .found
        if let current = selectedPlace, let fresh = results.first(where: { $0.id == current.id }) {
            selectedPlace = fresh
        }
        if !results.isEmpty { Haptics.success() }
        scheduleScanStateReset()
    }

    // MARK: - On-demand place details

    /// Second-stage fetch for Google fields; the service dedupes and caches per id, so repeat opens are free.
    private func loadDetailsIfNeeded(for place: Place?) {
        guard let place, place.isLocated, place.details == nil else { return }
        Task { [weak self] in
            do {
                let details = try await GooglePlacesService.shared.details(for: place)
                self?.attach(details, to: place.id, includingResults: true)
            } catch {
                // No hard error: the card keeps its MapKit data. Results keep details nil, so the next open retries.
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
