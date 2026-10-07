import Foundation
import Combine
import CoreLocation
import QuartzCore

#if !targetEnvironment(simulator)
import CoreMotion
#endif

/// Who owns heading and pitch: the device's own compass + CoreMotion, or the AR path pushing samples in.
enum PoseSource { case deviceSensors, external }

/// Split off `PoseManager` on purpose: `pose` republishes at up to 61 Hz, and a view that only needs these
/// flags must not re-body on every tick. Observe this, never `PoseManager`, to read them.
@MainActor
final class PoseFlags: ObservableObject {
    @Published fileprivate(set) var locationDenied = false
    /// True while the compass fix is degraded or absent; drives the "compass calibrating" hint. Always false in the simulator and on the AR path.
    @Published fileprivate(set) var headingDegraded: Bool
    /// True when Precise Location is off — scan candidates need a precise fix. Always false in the simulator.
    @Published fileprivate(set) var preciseLocationOff = false

    var isSimulated: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    init() {
        #if targetEnvironment(simulator)
        headingDegraded = false
        #else
        headingDegraded = true // no heading fix yet
        #endif
    }
}

/// Publishes device pose at up to 60 Hz; simulator uses a nudgeable virtual heading/pitch with an SF location fallback.
@MainActor
final class PoseManager: NSObject, ObservableObject {

    @Published private(set) var pose: DevicePose

    /// The low-rate flags. Views observe this, not `self` — see PoseFlags.
    let flags = PoseFlags()

    var locationDenied: Bool { flags.locationDenied }
    var headingDegraded: Bool { flags.headingDegraded }
    var preciseLocationOff: Bool { flags.preciseLocationOff }

    var isSimulated: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    private let locationManager = CLLocationManager()
    #if !targetEnvironment(simulator)
    private let motionManager = CMMotionManager()
    #endif

    private var started = false
    private var isBackgrounded = false
    private var source: PoseSource = .deviceSensors
    private var latestLocation: CLLocation?
    private var externalHeading: Double = 0
    private var externalPitch: Double = 0
    private var lastPublishTime: CFTimeInterval = 0
    /// Just under 1/60 s so a 60 Hz AR sample is never beat-skipped; the device sensors never reach this rate anyway.
    private let minPublishInterval: CFTimeInterval = 1.0 / 61.0

    #if targetEnvironment(simulator)
    private var virtualHeading: Double = 15
    private var virtualPitch: Double = 2
    #else
    private var smoothedHeading: Double = 0
    private var hasHeadingFix = false
    private var smoothedPitch: Double = 0
    #endif

    override init() {
        #if targetEnvironment(simulator)
        pose = DevicePose(location: nil, headingDegrees: 15, pitchDegrees: 2)
        #else
        pose = DevicePose(location: nil, headingDegrees: 0, pitchDegrees: 0)
        #endif
        super.init()
    }

    // MARK: - Public API

    func start() {
        guard !started else { return }
        started = true
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
        #if targetEnvironment(simulator)
        scheduleLocationFallback()
        #else
        flags.preciseLocationOff = locationManager.accuracyAuthorization == .reducedAccuracy
        guard source == .deviceSensors else { return }
        locationManager.headingFilter = 1
        locationManager.startUpdatingHeading()
        startMotionUpdates()
        #endif
    }

    /// scenePhase background: stop the sensor pumps so nothing keeps publishing; all state survives for the resume.
    func pauseForBackground() {
        guard started, !isBackgrounded else { return }
        isBackgrounded = true
        locationManager.stopUpdatingLocation()
        #if !targetEnvironment(simulator)
        locationManager.stopUpdatingHeading()
        motionManager.stopDeviceMotionUpdates()
        #endif
    }

    /// scenePhase active: restart only what the current source owns — the AR path keeps heading while external.
    func resumeForForeground() {
        guard started, isBackgrounded else { return }
        isBackgrounded = false
        locationManager.startUpdatingLocation()
        #if !targetEnvironment(simulator)
        if source == .deviceSensors {
            locationManager.startUpdatingHeading()
            startMotionUpdates()
        }
        #endif
    }

    // MARK: - External pose source (AR path)

    /// Hands pose ownership to the AR path: stops the compass and CoreMotion, keeps CoreLocation for permission + backstop.
    func adoptExternalSource() {
        guard source == .deviceSensors else { return }
        source = .external
        #if !targetEnvironment(simulator)
        locationManager.stopUpdatingHeading()
        motionManager.stopDeviceMotionUpdates()
        #endif
        // The AR path has its own quality pill; the compass-calibrating copy would be nonsense here.
        if flags.headingDegraded { flags.headingDegraded = false }
    }

    /// Returns pose ownership to the compass + CoreMotion path (demotion to fallback).
    func resumeDeviceSensors() {
        guard source == .external else { return }
        source = .deviceSensors
        #if !targetEnvironment(simulator)
        // Carry the last AR pose over: bubbles are un-suppressed immediately and must not swing to north-locked 0°.
        smoothedHeading = Angles.normalized(externalHeading)
        smoothedPitch = externalPitch
        // Still no compass fix, so the first real sample snaps rather than easing in from this seed.
        hasHeadingFix = false
        flags.headingDegraded = true
        // A mid-background demotion leaves the pumps off; the foreground resume restarts them for this source.
        guard !isBackgrounded else { return }
        locationManager.headingFilter = 1
        locationManager.startUpdatingHeading()
        startMotionUpdates()
        #endif
    }

    /// AR path sample. `location == nil` keeps the last CoreLocation fix as a backstop.
    func submitExternalPose(location: CLLocation?, headingDegrees: Double, pitchDegrees: Double) {
        guard source == .external else { return }
        if let location { latestLocation = location }
        externalHeading = headingDegrees
        externalPitch = pitchDegrees
        publishIfDue()
    }

    /// Simulator only: rotate the virtual camera. No-op on a real device.
    func nudgeVirtualHeading(byDegrees delta: Double) {
        #if targetEnvironment(simulator)
        virtualHeading = Angles.normalized(virtualHeading + delta)
        publishNow()
        #endif
    }

    /// Simulator only: tilt the virtual camera. No-op on a real device.
    func nudgeVirtualPitch(byDegrees delta: Double) {
        #if targetEnvironment(simulator)
        virtualPitch = min(35, max(-35, virtualPitch + delta))
        publishNow()
        #endif
    }

    // MARK: - Sensor intake (main actor)

    private func applyLocation(_ location: CLLocation) {
        let isFirstFix = latestLocation == nil
        latestLocation = location
        publishIfDue(force: isFirstFix)
    }

    private func applyAuthorization(_ status: CLAuthorizationStatus, reducedAccuracy: Bool) {
        #if !targetEnvironment(simulator)
        if flags.preciseLocationOff != reducedAccuracy { flags.preciseLocationOff = reducedAccuracy }
        #endif
        switch status {
        case .denied, .restricted:
            flags.locationDenied = true
        case .authorizedWhenInUse, .authorizedAlways:
            flags.locationDenied = false
            // While backgrounded the foreground resume restarts these; starting them here would leak sensor work into the background.
            guard !isBackgrounded else { break }
            locationManager.startUpdatingLocation()
            #if !targetEnvironment(simulator)
            // The AR path owns heading while external; restarting the compass here would fight it.
            if source == .deviceSensors { locationManager.startUpdatingHeading() }
            #endif
        case .notDetermined:
            break
        @unknown default:
            break
        }
    }

    #if !targetEnvironment(simulator)
    /// Accepts degraded compass samples (indoors this is often all we ever get) but trusts them less.
    private func applyHeading(_ degrees: Double, accuracy: Double) {
        guard source == .deviceSensors, degrees >= 0 else { return }
        // Assign only on change — @Published fires objectWillChange on every write, bypassing the 30 Hz coalescing.
        let degraded = accuracy > 25
        if degraded != flags.headingDegraded { flags.headingDegraded = degraded }
        if hasHeadingFix {
            // A fixed alpha has to trade lag against noise; scale it by how much the sample actually moved.
            let delta = Angles.shortestDelta(from: smoothedHeading, to: degrees)
            var alpha = Angles.adaptiveAlpha(forDelta: delta)
            // A degraded fix is mostly noise; trust it proportionally less.
            if headingDegraded { alpha = max(0.05, alpha * (25.0 / accuracy)) }
            smoothedHeading = Angles.ema(current: smoothedHeading, target: degrees, alpha: alpha)
        } else {
            // First fix of any quality snaps directly rather than easing in from the stale 0° default.
            smoothedHeading = Angles.normalized(degrees)
            hasHeadingFix = true
        }
        publishIfDue()
    }

    private func applyPitch(_ degrees: Double) {
        guard source == .deviceSensors else { return }
        // Vertical gain is ~11 pt per degree, so the same noise-vs-motion split matters more here than on heading.
        smoothedPitch += Angles.adaptiveAlpha(forDelta: degrees - smoothedPitch) * (degrees - smoothedPitch)
        publishIfDue()
    }

    private func startMotionUpdates() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 30.0
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] motion, _ in
            guard let motion else { return }
            // Portrait camera pitch from gravity: horizon => ~0, sky => positive, ground => negative.
            let gravity = motion.gravity
            let raw = atan2(gravity.z, -gravity.y) * 180.0 / .pi
            let clamped = min(80.0, max(-80.0, raw))
            MainActor.assumeIsolated { // updates are delivered on the main queue
                self?.applyPitch(clamped)
            }
        }
    }
    #endif

    // MARK: - Simulator location fallback

    #if targetEnvironment(simulator)
    private func scheduleLocationFallback() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, self.latestLocation == nil else { return }
            // No simulated fix arrived — park at Union Square, SF; a later real fix replaces this.
            self.latestLocation = CLLocation(latitude: 37.7880, longitude: -122.4074)
            self.publishNow()
        }
    }
    #endif

    // MARK: - Publishing (coalesced to the publish interval)

    private func publishIfDue(force: Bool = false) {
        let now = CACurrentMediaTime()
        guard force || now - lastPublishTime >= minPublishInterval else { return }
        publishNow(at: now)
    }

    private func publishNow(at time: CFTimeInterval = CACurrentMediaTime()) {
        lastPublishTime = time
        #if targetEnvironment(simulator)
        pose = DevicePose(location: latestLocation,
                          headingDegrees: virtualHeading,
                          pitchDegrees: virtualPitch)
        #else
        if source == .external {
            pose = DevicePose(location: latestLocation,
                              headingDegrees: externalHeading,
                              pitchDegrees: externalPitch)
        } else {
            pose = DevicePose(location: latestLocation,
                              headingDegrees: smoothedHeading,
                              pitchDegrees: smoothedPitch)
        }
        #endif
    }
}

// MARK: - CLLocationManagerDelegate

extension PoseManager: CLLocationManagerDelegate {

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        Task { @MainActor [weak self] in
            self?.applyLocation(latest)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateHeading newHeading: CLHeading) {
        #if !targetEnvironment(simulator)
        // Only drop truly invalid samples — degraded accuracy is still better than the frozen default.
        guard newHeading.headingAccuracy >= 0 else { return }
        // Bearings are true-north relative; never substitute magneticHeading while trueHeading is invalid (-1 until first fix).
        guard newHeading.trueHeading >= 0 else { return }
        let degrees = newHeading.trueHeading
        let accuracy = newHeading.headingAccuracy
        Task { @MainActor [weak self] in
            self?.applyHeading(degrees, accuracy: accuracy)
        }
        #endif
    }

    nonisolated func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool {
        // Heading drives all AR alignment — allow the iOS compass calibration prompt.
        true
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        let reduced = manager.accuracyAuthorization == .reducedAccuracy
        Task { @MainActor [weak self] in
            self?.applyAuthorization(status, reducedAccuracy: reduced)
        }
    }
}
