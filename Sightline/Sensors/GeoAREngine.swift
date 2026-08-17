// Every ARKit/ARCore type in the app lives inside this one condition — the simulator build is the guard that none escaped.
#if canImport(ARCoreGeospatial) && !targetEnvironment(simulator)

import Foundation
import ARKit
import CoreLocation
import QuartzCore
import UIKit
import simd

import ARCoreGARSession
import ARCoreGeospatial

/// Owns the ARSession + GARSession pair. Every GARSession call happens on `arQueue`; callbacks are delivered on main.
/// Unchecked because that queue split is enforced by contract, not by the type system — see the state MARKs below.
final class GeoAREngine: NSObject, ARSessionDelegate, CLLocationManagerDelegate, @unchecked Sendable {

    let arSession = ARSession()

    /// Invoked on the main thread at ~30 Hz.
    var onSnapshot: ((GeoARSnapshot) -> Void)?
    /// Invoked on the main thread at most once per session.
    var onFatalError: ((FallbackReason) -> Void)?

    /// The single serial queue that owns GARSession; also the ARSession delegate queue.
    private let arQueue = DispatchQueue(label: "com.citylens.geoar.session")
    private let locationManager = CLLocationManager()

    // MARK: State — main thread only

    private var isRunning = false
    private var didFail = false

    // MARK: State — arQueue only

    private var garSession: GARSession?
    private var vpsFuture: GARVPSAvailabilityFuture?
    private var didRequestVPS = false
    private var didCalibrateProjector = false
    private var consecutiveUpdateFailures = 0
    private var lastCameraTransform: simd_float4x4?
    /// Retained for occlusion probing between frames; ARCore's frame is a light wrapper, unlike ARFrame.
    private var lastGARFrame: GARFrame?
    private var lastPublishTime: CFTimeInterval = 0
    private var lastLocalizedTime: CFTimeInterval = 0
    private var hasHeadingFix = false
    private var smoothedHeading: Double = 0
    private var smoothedPitch: Double = 0
    private var snapshot = GeoARSnapshot(phase: .starting)

    /// Matches PoseManager.minPublishInterval — one pose per ARFrame, so the overlay and the 60 Hz video share a clock.
    private let minPublishInterval: CFTimeInterval = 1.0 / 61.0
    /// Consecutive GARSession.update throws before the AR path is abandoned.
    private let updateFailureBudget = 30

    // MARK: Raw-value mirrors of ARCore enums

    /// GARTrackingState.tracking.
    private static let trackingStateTracking = 0
    /// GAREarthState.errorNotAuthorized.
    private static let earthStateErrorNotAuthorized = -2
    /// GARVPSAvailability.unavailable.
    private static let vpsAvailabilityUnavailable = 2

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true

        locationManager.delegate = self
        // Coarse on purpose: this manager only seeds the one-shot VPS availability check — PoseManager owns the precise fix, and GARSession runs its own internal location.
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.startUpdatingLocation()

        let config = ARWorldTrackingConfiguration()
        // World +X east, +Y up, +Z south — true-north aligned, matching the geospatial EUS frame.
        config.worldAlignment = .gravityAndHeading
        config.planeDetection = []
        arSession.delegateQueue = arQueue
        arSession.delegate = self
        arSession.run(config, options: [.resetTracking, .removeExistingAnchors])

        arQueue.async { [weak self] in self?.createGARSession() }
    }

    /// scenePhase background — the camera stops, the GARSession stays configured.
    func pause() {
        guard isRunning else { return }
        arSession.pause()
    }

    /// scenePhase active — re-run without resetting tracking so the localized world frame survives.
    func resume() {
        guard isRunning else { return }
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravityAndHeading
        config.planeDetection = []
        arSession.run(config, options: [])
    }

    /// Teardown on demotion. Pauses synchronously on the caller's thread so AVCapture can take the camera next.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        arSession.delegate = nil
        arSession.pause()
        locationManager.stopUpdatingLocation()
        arQueue.async { [weak self] in
            self?.garSession = nil
            self?.vpsFuture = nil
            self?.lastGARFrame = nil
        }
    }

    // MARK: - Setup (arQueue)

    private func createGARSession() {
        do {
            // bundleIdentifier: nil makes ARCore use the app's own bundle id for the API-key restriction check.
            let session = try GARSession(apiKey: Secrets.googleAPIKey, bundleIdentifier: nil)
            guard session.isGeospatialModeSupported(.enabled) else {
                fail(.geospatialUnsupported)
                return
            }
            let configuration = GARSessionConfiguration()
            configuration.geospatialMode = .enabled
            configuration.streetscapeGeometryMode = .enabled
            var configError: NSError?
            // setConfiguration does NOT bridge to throws — it takes an NSErrorPointer.
            session.setConfiguration(configuration, error: &configError)
            if configError != nil {
                fail(.garConfigFailed)
                return
            }
            garSession = session
        } catch {
            fail(.garInitFailed)
        }
    }

    // MARK: - ARSessionDelegate (arQueue)

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        lastCameraTransform = frame.camera.transform
        calibrateProjectorIfNeeded(frame)

        guard let garSession else {
            applyPreLocalizationPose()
            hopIfDue()
            return
        }

        do {
            let garFrame = try garSession.update(frame)
            consecutiveUpdateFailures = 0
            ingest(garFrame)
        } catch {
            consecutiveUpdateFailures += 1
            // The ARKit camera transform is unaffected by a GAR failure, so pitch keeps tracking either way.
            applyPitchFromCamera()
            // Once localized, a transient throw must not swing the heading back to the ARKit estimate.
            if snapshot.phase != .localized {
                applyPreLocalizationHeading()
                snapshot.location = nil
            }
            if consecutiveUpdateFailures >= updateFailureBudget { fail(.garUpdateFailing) }
        }
        requestVPSIfNeeded()
        hopIfDue()
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        fail(.arSessionFailed)
    }

    // MARK: - Frame ingestion (arQueue)

    private func ingest(_ garFrame: GARFrame) {
        lastGARFrame = garFrame
        snapshot.geometryCount = garFrame.streetscapeGeometries?.count ?? 0

        guard let earth = garFrame.earth else {
            snapshot.phase = .starting
            applyPreLocalizationPose()
            return
        }
        // ERROR_NOT_AUTHORIZED means the API key / Cloud project is wrong — no amount of panning fixes it.
        if earth.earthState.rawValue == Self.earthStateErrorNotAuthorized {
            fail(.notAuthorized)
            return
        }

        let isTracking = earth.trackingState.rawValue == Self.trackingStateTracking
        guard isTracking, let transform = earth.cameraGeospatialTransform else {
            demotePhaseAfterGrace()
            // Gravity-derived pitch survives geospatial tracking loss, so only the heading is ever held.
            applyPitchFromCamera()
            // Inside the grace window we are still nominally localized — don't swing the heading to the ARKit estimate.
            if snapshot.phase != .localized {
                applyPreLocalizationHeading()
                snapshot.location = nil
            }
            return
        }

        updatePhase(yawAccuracy: transform.orientationYawAccuracy,
                    horizontalAccuracy: transform.horizontalAccuracy)

        // Looking straight up: hold the last heading rather than amplify its noise.
        if lastCameraTransform.map(Self.hasStableAzimuth) ?? true {
            applyHeading(Self.headingDegrees(from: transform.eastUpSouthQTarget))
        }
        applyPitchFromCamera()
        snapshot.location = CLLocation(coordinate: transform.coordinate,
                                       altitude: transform.altitude,
                                       horizontalAccuracy: transform.horizontalAccuracy,
                                       verticalAccuracy: transform.verticalAccuracy,
                                       timestamp: Date())
    }

    /// Before localization ARKit's own gravityAndHeading frame is the heading source; location stays nil so PoseManager keeps its GPS backstop.
    private func applyPreLocalizationPose() {
        applyPreLocalizationHeading()
        applyPitchFromCamera()
        snapshot.location = nil
    }

    /// Heading half of the pre-localization pose, separated so a tracking hiccup can hold heading without freezing pitch.
    private func applyPreLocalizationHeading() {
        guard let transform = lastCameraTransform, Self.hasStableAzimuth(transform) else { return }
        applyHeading(Self.headingDegrees(fromCamera: transform))
    }

    private func applyHeading(_ degrees: Double) {
        if hasHeadingFix {
            // Accurate but frame-jittery — the same adaptive EMA the compass path uses.
            let alpha = Angles.adaptiveAlpha(forDelta: Angles.shortestDelta(from: smoothedHeading, to: degrees))
            smoothedHeading = Angles.ema(current: smoothedHeading, target: degrees, alpha: alpha)
        } else {
            smoothedHeading = Angles.normalized(degrees)
            hasHeadingFix = true
        }
        snapshot.headingDegrees = smoothedHeading
    }

    /// Pitch always comes from the ARKit camera transform: gravity-aligned, available before localization, less jitter.
    private func applyPitchFromCamera() {
        guard let t = lastCameraTransform else { return }
        let f = -simd_float3(t.columns.2.x, t.columns.2.y, t.columns.2.z)
        let raw = asin(Double(max(-1, min(1, f.y)))) * 180 / .pi
        let clamped = min(80, max(-80, raw))
        smoothedPitch += Angles.adaptiveAlpha(forDelta: clamped - smoothedPitch) * (clamped - smoothedPitch)
        snapshot.pitchDegrees = smoothedPitch
    }

    // MARK: - Phase (arQueue)

    private func updatePhase(yawAccuracy: Double, horizontalAccuracy: Double) {
        let now = CACurrentMediaTime()
        if snapshot.phase == .localized {
            if yawAccuracy > GeoARThresholds.yawAccuracyExit
                || horizontalAccuracy > GeoARThresholds.horizontalAccuracyExit {
                snapshot.phase = .localizing
            } else {
                lastLocalizedTime = now
            }
        } else if yawAccuracy <= GeoARThresholds.yawAccuracyEnter
                    && horizontalAccuracy <= GeoARThresholds.horizontalAccuracyEnter {
            snapshot.phase = .localized
            lastLocalizedTime = now
        } else {
            snapshot.phase = .localizing
        }
    }

    /// A momentary tracking dropout must not blink the bubbles off — hold `.localized` for the grace window.
    private func demotePhaseAfterGrace() {
        if snapshot.phase == .localized,
           CACurrentMediaTime() - lastLocalizedTime < GeoARThresholds.trackingLossGrace {
            return
        }
        snapshot.phase = .localizing
    }

    // MARK: - VPS (arQueue)

    private var pendingVPSCoordinate: CLLocationCoordinate2D?

    private func requestVPSIfNeeded() {
        guard !didRequestVPS, let garSession, let coordinate = pendingVPSCoordinate else { return }
        didRequestVPS = true
        // One coordinate is all the availability check needs — release the GPS as soon as the request is in flight.
        DispatchQueue.main.async { [weak self] in self?.locationManager.stopUpdatingLocation() }
        vpsFuture = garSession.checkVPSAvailability(coordinate: coordinate) { [weak self] availability in
            let raw = availability.rawValue
            self?.arQueue.async {
                guard let self else { return }
                // UNKNOWN and the negative error codes fail open; only a definite UNAVAILABLE gives up the AR path.
                if raw == Self.vpsAvailabilityUnavailable { self.fail(.vpsUnavailable) }
            }
        }
    }

    // MARK: - FOV calibration (arQueue -> main, once)

    /// Replaces ARProjector's assumed lens model with the real one; portrait, aspect-fill.
    private func calibrateProjectorIfNeeded(_ frame: ARFrame) {
        guard !didCalibrateProjector else { return }
        didCalibrateProjector = true
        let resolution = frame.camera.imageResolution
        let intrinsics = frame.camera.intrinsics
        DispatchQueue.main.async {
            let fx = Double(intrinsics.columns.0.x)
            let fy = Double(intrinsics.columns.1.y)
            guard fx > 1, fy > 1 else { return }

            // The image is landscape-native; in portrait its y axis runs across the screen.
            let wp = Double(resolution.height)
            let hp = Double(resolution.width)
            let fxP = fy
            let fyP = fx

            let screen = UIScreen.main.bounds.size
            let sw = Double(screen.width)
            let sh = Double(screen.height)
            guard sw > 0, sh > 0 else { return }

            let scale = max(sw / wp, sh / hp)
            let visibleW = min(wp, sw / scale)
            let visibleH = min(hp, sh / scale)

            let hFOV = 2 * atan((visibleW / 2) / fxP) * 180 / .pi
            let vFOV = 2 * atan((visibleH / 2) / fyP) * 180 / .pi
            ARProjector.calibrate(horizontalFOV: hFOV, verticalFOV: vFOV)
        }
    }

    // MARK: - Occlusion probing

    /// Assumed height of the phone above the ground the user is standing on.
    private static let eyeHeightMeters: Double = 1.5
    /// Orientation is irrelevant when the target is only a point.
    private static let identityQuaternion = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    /// GARStreetscapeGeometryType.building; the terrain case is rawValue 0.
    private static let buildingGeometryType = 1

    /// Bridges the caller onto `arQueue` — every GARSession call in the app happens there. An empty result fails open.
    func sampleOcclusion(_ probes: [OcclusionProbe]) async -> [OcclusionSample] {
        guard !probes.isEmpty else { return [] }
        return await withCheckedContinuation { continuation in
            arQueue.async { [weak self] in
                continuation.resume(returning: self?.probeOcclusion(probes) ?? [])
            }
        }
    }

    /// arQueue only. Any missing answer is simply omitted from the result, which the policy reads as "visible".
    private func probeOcclusion(_ probes: [OcclusionProbe]) -> [OcclusionSample] {
        guard let garSession,
              let earth = lastGARFrame?.earth,
              earth.trackingState.rawValue == Self.trackingStateTracking,
              let geo = earth.cameraGeospatialTransform,
              let camTransform = lastCameraTransform
        else { return [] }

        let origin = simd_float3(camTransform.columns.3.x,
                                 camTransform.columns.3.y,
                                 camTransform.columns.3.z)
        // Both altitudes are WGS-84 ellipsoid heights, so no geoid correction is needed.
        let groundAltitude = geo.altitude - Self.eyeHeightMeters

        var samples: [OcclusionSample] = []
        samples.reserveCapacity(probes.count)

        for probe in probes {
            let coordinate = CLLocationCoordinate2D(latitude: probe.latitude, longitude: probe.longitude)
            guard CLLocationCoordinate2DIsValid(coordinate) else { continue }

            // ARCore owns the geodetic -> world conversion; hand-rolled ENU would drift from the localized frame.
            guard let targetTransform = try? garSession.transform(
                    coordinate: coordinate,
                    altitude: groundAltitude + probe.aimHeightMeters,
                    eastUpSouthQTarget: Self.identityQuaternion)
            else { continue }

            let target = simd_float3(targetTransform.columns.3.x,
                                     targetTransform.columns.3.y,
                                     targetTransform.columns.3.z)
            let delta = target - origin
            let targetDistance = Double(simd_length(delta))
            guard targetDistance > 1 else { continue }

            guard let hits = try? garSession.raycastStreetscapeGeometry(
                    origin: origin, direction: simd_normalize(delta))
            else { continue }

            // The hit array carries no ordering guarantee, so reduce rather than take the first.
            var nearestBuilding: Double?
            var nearestTerrain: Double?
            for hit in hits {
                let distance = Double(hit.distance)
                if hit.streetscapeGeometry.type.rawValue == Self.buildingGeometryType {
                    nearestBuilding = min(nearestBuilding ?? .greatestFiniteMagnitude, distance)
                } else {
                    nearestTerrain = min(nearestTerrain ?? .greatestFiniteMagnitude, distance)
                }
            }

            samples.append(OcclusionSample(id: probe.id,
                                           targetDistanceMeters: targetDistance,
                                           nearestBuildingHitMeters: nearestBuilding,
                                           nearestTerrainHitMeters: nearestTerrain))
        }
        return samples
    }

    // MARK: - Publishing

    private func hopIfDue() {
        let now = CACurrentMediaTime()
        guard now - lastPublishTime >= minPublishInterval else { return }
        lastPublishTime = now
        let value = snapshot
        DispatchQueue.main.async { [weak self] in self?.onSnapshot?(value) }
    }

    /// Fires at most once; a GAR failure never tears down the ARSession here — the coordinator decides.
    private func fail(_ reason: FallbackReason) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.didFail else { return }
            self.didFail = true
            self.onFatalError?(reason)
        }
    }

    // MARK: - CLLocationManagerDelegate (main)

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        arQueue.async { [weak self] in
            guard let self, !self.didRequestVPS else { return }
            self.pendingVPSCoordinate = coordinate
        }
    }

    // MARK: - Angle math

    /// `GARGeospatialTransform.heading` is deprecated since 1.35 — derive it from the East-Up-South quaternion.
    static func headingDegrees(from eastUpSouthQTarget: simd_quatf) -> Double {
        let forward = simd_act(eastUpSouthQTarget, simd_float3(0, 0, -1))
        let east = Double(forward.x)
        let north = Double(-forward.z)
        var degrees = atan2(east, north) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        return degrees
    }

    /// ARKit's gravityAndHeading world frame uses the same axes as EUS (x east, z south).
    static func headingDegrees(fromCamera transform: simd_float4x4) -> Double {
        let f = -simd_float3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        var degrees = atan2(Double(f.x), Double(-f.z)) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        return degrees
    }

    /// Below this the camera is near-vertical and the atan2 azimuth is degenerate — bearing is meaningless there anyway.
    private static let minAzimuthHorizontalComponent: Float = 0.25

    static func hasStableAzimuth(_ t: simd_float4x4) -> Bool {
        let f = -simd_float3(t.columns.2.x, t.columns.2.y, t.columns.2.z)
        return simd_length(simd_float2(f.x, f.z)) >= minAzimuthHorizontalComponent
    }
}

#endif
