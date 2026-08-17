import Foundation
import AVFoundation
import Combine
import CoreLocation

/// Decides once which camera backend runs, owns both, and bridges the AR path's pose into PoseManager.
@MainActor
final class SceneBackendCoordinator: ObservableObject {

    @Published private(set) var backend: SceneBackend = .undecided
    @Published private(set) var phase: GeoARPhase = .inactive

    /// Outdoors Geospatial converges in seconds; only a stretch this long without localizing reads as "indoors".
    static let sustainedUnlocalizedSeconds: TimeInterval = 15

    let camera = CameraManager()
    let geoAR = GeoARManager()

    private unowned let pose: PoseManager
    private var started = false
    private let locationManager = CLLocationManager()
    /// Start of the current non-localized stretch on the AR path; nil whenever localized or on the fallback backend.
    private var unlocalizedSince: Date?

    init(pose: PoseManager) {
        self.pose = pose
    }

    // MARK: - Derived state

    /// True while the AR path is up but not yet trustworthy — the bubble layer hides everything on this.
    var suppressesBubbles: Bool { backend.isGeoAR && phase != .localized }

    /// The AR path has been unable to localize long enough that "step outside" is a fair thing to say.
    /// Distinct from `suppressesBubbles`, which is also true during the first outdoor seconds.
    var isSustainedUnlocalized: Bool {
        guard suppressesBubbles, let since = unlocalizedSince else { return false }
        return Date().timeIntervalSince(since) >= Self.sustainedUnlocalizedSeconds
    }

    /// True when the AR camera layer should render instead of the AVCapture preview.
    var usesARCamera: Bool { backend.isGeoAR }

    // MARK: - Lifecycle

    /// Camera contention is the biggest crash risk, so exactly one backend is chosen before anything is started.
    func start() {
        guard !started else { return }
        started = true
        switch decideBackend() {
        case .geoAR:
            startGeoAR()
        case .fallback(let reason):
            backend = .fallback(reason)
            camera.start()
        case .undecided:
            break
        }
    }

    func resumeForForeground() {
        pose.resumeForForeground()
        switch backend {
        case .geoAR:
            geoAR.resume()
        case .fallback:
            // Camera sessions get killed by interruptions the OS doesn't always resume on its own.
            camera.start()
        case .undecided:
            break
        }
    }

    func pauseForBackground() {
        // The backend pause below releases the camera; the pose pumps stop too so nothing publishes from the background.
        pose.pauseForBackground()
        switch backend {
        case .geoAR:
            geoAR.pause()
        case .fallback:
            // The DEBUG spike runs its own ARSession, so AVCapture has to let go of the camera here too.
            camera.stop()
        case .undecided:
            break
        }
    }

    // MARK: - Decision ladder

    private func decideBackend() -> SceneBackend {
        #if targetEnvironment(simulator)
        return .fallback(.simulator)
        #else
        guard GeoARManager.isBuildCapable else { return .fallback(.sdkMissing) }
        guard GeoARManager.isDeviceCapable else { return .fallback(.deviceUnsupported) }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .denied, .restricted: return .fallback(.cameraPermission)
        default: break
        }
        switch locationManager.authorizationStatus {
        case .denied, .restricted: return .fallback(.locationPermission)
        default: break
        }
        // Geospatial needs full accuracy; reduced accuracy can never localize.
        if locationManager.accuracyAuthorization == .reducedAccuracy { return .fallback(.reducedAccuracy) }
        return .geoAR
        #endif
    }

    private func startGeoAR() {
        geoAR.onSnapshot = { [weak self] snapshot in
            guard let self else { return }
            self.apply(snapshot)
        }
        geoAR.onFatalError = { [weak self] reason in
            self?.demote(to: reason)
        }
        pose.adoptExternalSource()
        geoAR.start()
        backend = .geoAR
        phase = .starting
        unlocalizedSince = Date()
    }

    /// Snapshots land at ~30 Hz — only write the published mirrors when they actually change.
    private func apply(_ snapshot: GeoARSnapshot) {
        if phase != snapshot.phase {
            phase = snapshot.phase
            // Losing localization restarts the clock, so a mid-session dropout doesn't read as indoors immediately.
            unlocalizedSince = snapshot.phase == .localized ? nil : Date()
        }
        pose.submitExternalPose(location: snapshot.location,
                                headingDegrees: snapshot.headingDegrees,
                                pitchDegrees: snapshot.pitchDegrees)
    }

    /// The only transition ever allowed. Order matters: the ARSession must release the camera before AVCapture asks for it.
    /// Promotion back to geoAR is deliberately absent — relaunching ARKit mid-session would fight the live AVCapture session for the camera, the contention the single-backend rule exists to prevent.
    private func demote(to reason: FallbackReason) {
        guard backend == .geoAR else { return }
        // Drop the callbacks first: a snapshot already in flight on the main queue must not resurrect the AR phase.
        geoAR.onSnapshot = nil
        geoAR.onFatalError = nil
        geoAR.stop()
        pose.resumeDeviceSensors()
        backend = .fallback(reason)
        phase = .inactive
        unlocalizedSince = nil
        camera.start()
    }
}
