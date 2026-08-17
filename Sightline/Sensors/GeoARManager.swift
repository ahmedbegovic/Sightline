import Foundation
import CoreLocation

#if canImport(ARCoreGeospatial) && !targetEnvironment(simulator)
import ARKit
#endif

/// Public face of the AR path. Names no ARCore type — every device-only line delegates to `GeoAREngine`.
final class GeoARManager: OcclusionProbeSource {

    /// Latest AR-path readout; always updated on the main thread.
    private(set) var snapshot = GeoARSnapshot(phase: .inactive)

    /// Set by the coordinator before start(); invoked on the main thread.
    var onSnapshot: ((GeoARSnapshot) -> Void)?
    var onFatalError: ((FallbackReason) -> Void)?

    #if canImport(ARCoreGeospatial) && !targetEnvironment(simulator)
    private lazy var engine: GeoAREngine = {
        let engine = GeoAREngine()
        engine.onSnapshot = { [weak self] snapshot in
            guard let self else { return }
            self.snapshot = snapshot
            self.onSnapshot?(snapshot)
        }
        engine.onFatalError = { [weak self] reason in
            self?.onFatalError?(reason)
        }
        return engine
    }()

    /// The live ARSession for the camera layer.
    var arSession: ARSession { engine.arSession }
    #endif

    // MARK: - Capability

    /// True when this build carries the ARCore SDK and is not a simulator slice.
    static var isBuildCapable: Bool {
        #if canImport(ARCoreGeospatial) && !targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    /// True when the build is capable and the hardware supports ARKit world tracking.
    static var isDeviceCapable: Bool {
        #if canImport(ARCoreGeospatial) && !targetEnvironment(simulator)
        return ARWorldTrackingConfiguration.isSupported
        #else
        return false
        #endif
    }

    // MARK: - Lifecycle

    func start() {
        #if canImport(ARCoreGeospatial) && !targetEnvironment(simulator)
        snapshot = GeoARSnapshot(phase: .starting)
        engine.start()
        #endif
    }

    func pause() {
        #if canImport(ARCoreGeospatial) && !targetEnvironment(simulator)
        engine.pause()
        #endif
    }

    func resume() {
        #if canImport(ARCoreGeospatial) && !targetEnvironment(simulator)
        engine.resume()
        #endif
    }

    func stop() {
        #if canImport(ARCoreGeospatial) && !targetEnvironment(simulator)
        // Drop the engine's callbacks first: a snapshot already hopping to main must not resurrect `.localized` after teardown.
        engine.onSnapshot = nil
        engine.onFatalError = nil
        engine.stop()
        #endif
        snapshot = GeoARSnapshot(phase: .inactive)
    }

    // MARK: - OcclusionProbeSource

    var isLocalizedForOcclusion: Bool { snapshot.phase == .localized }

    var localizedCoordinate: CLLocationCoordinate2D? {
        guard snapshot.phase == .localized else { return nil }
        return snapshot.location?.coordinate
    }

    var hasStreetscapeGeometry: Bool { snapshot.geometryCount > 0 }

    /// Stage 2 fills this in; on non-capable builds it always returns "no answer", which the policy reads as fail-open.
    func sampleOcclusion(_ probes: [OcclusionProbe]) async -> [OcclusionSample] {
        #if canImport(ARCoreGeospatial) && !targetEnvironment(simulator)
        return await engine.sampleOcclusion(probes)
        #else
        return []
        #endif
    }
}
