import Foundation
import Combine
import CoreImage
import CoreLocation
import QuartzCore
import UIKit

#if !targetEnvironment(simulator)
import ARKit
#endif

/// What the camera saw at the moment Scan was pressed. Pose is frozen here because inference takes seconds and the user keeps moving.
struct ScanFrame {
    /// Upright, cropped to what the screen shows; nil in the simulator or before the first frame.
    let image: CGImage?
    let headingDegrees: Double
    let pitchDegrees: Double
    let location: CLLocation?
    /// Horizontal field of view of `image` (the screen-visible crop), in degrees.
    let horizontalFOV: Double
}

/// Plain ARKit world tracking: the live camera feed, heading/pitch for the pose, and frame capture for scans.
/// No geospatial localization, so nothing here depends on height, indoor/outdoor or a remote service.
@MainActor
final class ARCameraEngine: NSObject, ObservableObject {

    enum Failure: Equatable { case permissionDenied, unavailable }

    /// Non-nil once the camera can't run; the compass takes over heading and the root view shows why.
    @Published private(set) var failure: Failure?

    private unowned let pose: PoseManager
    private var started = false
    private let ciContext = CIContext()

    #if !targetEnvironment(simulator)
    let session = ARSession()
    private let delegateQueue = DispatchQueue(label: "com.sightline.arkit.delegate")
    private let relay = FrameRelay()
    #endif

    init(pose: PoseManager) {
        self.pose = pose
    }

    var isLive: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return started && failure == nil
        #endif
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        #if !targetEnvironment(simulator)
        guard ARWorldTrackingConfiguration.isSupported else { return fail(.unavailable) }
        relay.onPose = { [weak self] heading, pitch in
            self?.pose.submitExternalPose(location: nil, headingDegrees: heading, pitchDegrees: pitch)
        }
        relay.onCalibrate = { size, intrinsics in Self.calibrateProjector(imageSize: size, intrinsics: intrinsics) }
        relay.onFailure = { [weak self] denied in self?.fail(denied ? .permissionDenied : .unavailable) }
        pose.adoptExternalSource()
        session.delegateQueue = delegateQueue
        session.delegate = relay
        session.run(Self.configuration(), options: [.resetTracking])
        #endif
    }

    func pause() {
        #if !targetEnvironment(simulator)
        guard isLive else { return }
        session.pause()
        #endif
    }

    func resume() {
        #if !targetEnvironment(simulator)
        guard isLive else { return }
        // No reset: tracking continues in the same world frame, so on-screen sightings stay put.
        session.run(Self.configuration(), options: [])
        #endif
    }

    // MARK: - Capture

    /// Freezes pose + frame. The image is converted off the main actor; the pose is read now.
    func capture() async -> ScanFrame {
        let current = pose.pose
        let fov = ARProjector.horizontalFOV
        var image: CGImage?
        #if !targetEnvironment(simulator)
        if isLive, let buffer = session.currentFrame?.capturedImage {
            let screen = Self.screenSize
            let context = ciContext
            image = await Task.detached(priority: .userInitiated) {
                Self.uprightCrop(buffer, screen: screen, context: context)
            }.value
        }
        #endif
        return ScanFrame(image: image,
                         headingDegrees: current.headingDegrees,
                         pitchDegrees: current.pitchDegrees,
                         location: current.location,
                         horizontalFOV: fov)
    }

    /// Portrait-rotates, crops to the screen's aspect-fill window (so the model sees what the user sees) and caps the long side.
    nonisolated static func uprightCrop(_ buffer: CVPixelBuffer, screen: CGSize, context: CIContext) -> CGImage? {
        var image = CIImage(cvPixelBuffer: buffer).oriented(.right)
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, screen.width > 0, screen.height > 0 else { return nil }
        let screenAspect = screen.width / screen.height
        var crop = extent
        if extent.width / extent.height > screenAspect {
            crop.size.width = extent.height * screenAspect
            crop.origin.x = extent.midX - crop.width / 2
        } else {
            crop.size.height = extent.width / screenAspect
            crop.origin.y = extent.midY - crop.height / 2
        }
        image = image.cropped(to: crop)
        let scale = min(1, 1024 / max(crop.width, crop.height))
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(image, from: image.extent)
    }

    // MARK: - Private

    private static var screenSize: CGSize {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds.size ?? .zero
    }

    private func fail(_ reason: Failure) {
        guard failure == nil else { return }
        failure = reason
        #if !targetEnvironment(simulator)
        session.pause()
        #endif
        pose.resumeDeviceSensors()
    }

    #if !targetEnvironment(simulator)
    private static func configuration() -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        // World +X east, +Y up, +Z south: camera azimuth is a true-north heading with no extra service.
        config.worldAlignment = .gravityAndHeading
        config.planeDetection = []
        return config
    }

    /// Replaces ARProjector's assumed lens model with the real one for the portrait aspect-fill crop.
    private static func calibrateProjector(imageSize: CGSize, intrinsics: simd_float3x3) {
        let fx = Double(intrinsics.columns.0.x)
        let fy = Double(intrinsics.columns.1.y)
        guard fx > 1, fy > 1 else { return }
        // The sensor image is landscape-native; in portrait its y axis runs across the screen.
        let wp = Double(imageSize.height), hp = Double(imageSize.width)
        let screen = screenSize
        let sw = Double(screen.width), sh = Double(screen.height)
        guard sw > 0, sh > 0 else { return }
        let scale = max(sw / wp, sh / hp)
        let visibleW = min(wp, sw / scale)
        let visibleH = min(hp, sh / scale)
        let hFOV = 2 * atan((visibleW / 2) / fy) * 180 / .pi
        let vFOV = 2 * atan((visibleH / 2) / fx) * 180 / .pi
        ARProjector.calibrate(horizontalFOV: hFOV, verticalFOV: vFOV)
    }
    #endif
}

#if !targetEnvironment(simulator)
/// ARSessionDelegate on the delegate queue; hops only small values to main, never the ARFrame (holding frames starves ARKit).
private final class FrameRelay: NSObject, ARSessionDelegate, @unchecked Sendable {
    // Set once on main before the session runs, read on the delegate queue.
    var onPose: (@MainActor (Double, Double) -> Void)?
    var onCalibrate: (@MainActor (CGSize, simd_float3x3) -> Void)?
    var onFailure: (@MainActor (Bool) -> Void)?

    private var lastPublish: CFTimeInterval = 0
    private var lastHeading: Double = 0
    private var calibrated = false

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        if !calibrated {
            calibrated = true
            let size = frame.camera.imageResolution
            let intrinsics = frame.camera.intrinsics
            DispatchQueue.main.async { [onCalibrate] in onCalibrate?(size, intrinsics) }
        }
        let now = CACurrentMediaTime()
        guard now - lastPublish >= 1.0 / 61.0 else { return }
        lastPublish = now

        let t = frame.camera.transform
        let forward = -simd_float3(t.columns.2.x, t.columns.2.y, t.columns.2.z)
        // Near-vertical camera: azimuth is degenerate, so hold the last heading.
        if simd_length(simd_float2(forward.x, forward.z)) >= 0.25 {
            var heading = atan2(Double(forward.x), Double(-forward.z)) * 180 / .pi
            if heading < 0 { heading += 360 }
            lastHeading = heading
        }
        let pitch = asin(Double(max(-1, min(1, forward.y)))) * 180 / .pi
        let heading = lastHeading
        DispatchQueue.main.async { [onPose] in onPose?(heading, pitch) }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        let denied = (error as? ARError)?.code == .cameraUnauthorized
        DispatchQueue.main.async { [onFailure] in onFailure?(denied) }
    }
}
#endif
