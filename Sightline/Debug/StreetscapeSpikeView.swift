// Whole spike is DEBUG-only so release builds carry none of it.
#if DEBUG

import SwiftUI
import ARKit
import SceneKit
import CoreLocation
import CoreImage
import ImageIO
import simd

#if canImport(ARCoreGeospatial)
import ARCoreGARSession
import ARCoreGeospatial
#endif

// MARK: - Entry point

/// Self-contained feasibility spike for ARCore Streetscape Geometry — additive, DEBUG-only, touches nothing else in the app.
struct StreetscapeSpikeView: View {
    var onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            #if canImport(ARCoreGeospatial) && !targetEnvironment(simulator)
            StreetscapeSpikeLiveView()
            #else
            StreetscapeSpikeUnavailableView()
            #endif

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .glassCard(cornerRadius: 19)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 16)
            .padding(.top, 10)
            .zIndex(100)
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(false)
    }
}

// MARK: - Simulator / SDK-missing placeholder

private struct StreetscapeSpikeUnavailableView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
            Text("Device only")
                .font(.headline)
                .foregroundStyle(.white)
            Text("Streetscape Geometry needs ARKit world tracking and Google VPS. Run this on a real iPhone, outdoors.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .glassCard()
        .padding(.horizontal, 36)
    }
}

#if canImport(ARCoreGeospatial) && !targetEnvironment(simulator)

// MARK: - Live spike

private struct StreetscapeSpikeLiveView: View {
    @StateObject private var engine = StreetscapeSpikeEngine()

    var body: some View {
        ZStack(alignment: .top) {
            ARSessionContainer(session: engine.arSession)
                .ignoresSafeArea()

            diagnostics
                .padding(.horizontal, 12)
                .padding(.top, 56)

            VStack {
                Spacer()
                crosshair
                Spacer()
            }
            .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onTapGesture { engine.raycastFromScreenCenter() }
        .onAppear { engine.start() }
        .onDisappear { engine.stop() }
    }

    private var crosshair: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.85), lineWidth: 1.5)
                .frame(width: 22, height: 22)
            Circle()
                .fill(.white.opacity(0.9))
                .frame(width: 3, height: 3)
        }
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(engine.lines, id: \.self) { line in
                Text(line)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("tap anywhere to raycast screen centre")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.accent.opacity(0.9))
                .padding(.top, 4)
        }
        .padding(12)
        .glassCard(cornerRadius: 16)
    }
}

// MARK: - AR view host

private struct ARSessionContainer: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = session
        view.automaticallyUpdatesLighting = true
        view.scene = SCNScene()
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

// MARK: - Session recorder

/// Writes a JSONL event log + periodic camera JPEGs to Documents/SpikeLogs/session-*/ so the run can be debugged after the fact.
private final class SpikeSessionRecorder {
    private let io = DispatchQueue(label: "com.citylens.spike.recorder", qos: .utility)
    private let ciContext = CIContext()
    private var handle: FileHandle?
    private(set) var directory: URL?
    private var startedAt = Date()
    private var eventCount = 0
    private var photoCount = 0
    private var lastStateLog: CFTimeInterval = 0
    private var lastPhoto: CFTimeInterval = 0

    var statusLine: String {
        guard directory != nil else { return "rec: OFF (log dir failed)" }
        return "● rec \(eventCount) events, \(photoCount) photos → Files ▸ Sightline ▸ SpikeLogs"
    }

    func begin() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("SpikeLogs/session-\(formatter.string(from: Date()))", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let logURL = dir.appendingPathComponent("log.jsonl")
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            handle = try FileHandle(forWritingTo: logURL)
            directory = dir
            startedAt = Date()
            log("session_start", ["device": UIDevice.current.model, "ios": UIDevice.current.systemVersion])
        } catch {
            directory = nil
        }
    }

    func end() {
        log("session_end")
        let handle = handle
        io.async { try? handle?.close() }
        self.handle = nil
    }

    /// Appends one JSONL line ({"t": seconds-since-start, "e": event, ...payload}); safe from any thread.
    func log(_ event: String, _ payload: [String: Any] = [:]) {
        guard let handle else { return }
        var entry = payload
        entry["e"] = event
        entry["t"] = (Date().timeIntervalSince(startedAt) * 1000).rounded() / 1000
        eventCount += 1
        io.async {
            guard JSONSerialization.isValidJSONObject(entry),
                  var data = try? JSONSerialization.data(withJSONObject: entry) else { return }
            data.append(0x0A)
            try? handle.write(contentsOf: data)
        }
    }

    /// 1 Hz gate for state logging, 5 s gate for automatic photos.
    func shouldLogState(now: CFTimeInterval) -> Bool {
        guard now - lastStateLog >= 1 else { return false }
        lastStateLog = now
        return true
    }

    func shouldCapturePhoto(now: CFTimeInterval) -> Bool {
        guard now - lastPhoto >= 5 else { return false }
        lastPhoto = now
        return true
    }

    /// Rotates to portrait, downscales to ≤1280 px, and writes a JPEG next to the log; encode is synchronous but runs at most every 5 s.
    func capturePhoto(from pixelBuffer: CVPixelBuffer, label: String) {
        guard let directory else { return }
        photoCount += 1
        var image = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)
        let maxDim = max(image.extent.width, image.extent.height)
        if maxDim > 1280 {
            let scale = 1280 / maxDim
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let data = ciContext.jpegRepresentation(
                of: image,
                colorSpace: colorSpace,
                options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.6])
        else { return }
        let name = String(format: "photo-%03d-%@.jpg", photoCount, label)
        let url = directory.appendingPathComponent(name)
        io.async { try? data.write(to: url) }
        log("photo", ["file": name, "label": label])
    }
}

// MARK: - Engine

/// Owns the ARSession + GARSession pair and publishes a flat list of diagnostic lines.
private final class StreetscapeSpikeEngine: NSObject, ObservableObject, ARSessionDelegate, CLLocationManagerDelegate {
    @Published var lines: [String] = ["starting…"]

    let arSession = ARSession()
    private let locationManager = CLLocationManager()
    private let recorder = SpikeSessionRecorder()
    private var garSession: GARSession?
    private var lastCameraTransform: simd_float4x4?
    private var vpsFuture: GARVPSAvailabilityFuture?
    private var didRequestVPS = false
    private var isRunning = false
    private var wantsTapPhoto = false
    private var lastGeometryDetailLog: CFTimeInterval = 0
    private var lastGPSLog: CFTimeInterval = 0
    // Structured copies of the latest readouts, merged into each 1 Hz "state" log entry.
    private var geoStats: [String: Any] = [:]
    private var meshStats: [String: Any] = [:]

    // Latest values, re-rendered into `lines` on every frame.
    private var setupError: String?
    private var vpsText = "VPS: not checked yet"
    private var raycastText = "raycast: (none yet)"
    private var earthText = "earth: waiting for first GARFrame"
    private var transformText = "geo: —"
    private var geometryText = "streetscape: —"
    private var accuracyText = ""

    override init() {
        super.init()
        locationManager.delegate = self
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true

        recorder.begin()
        locationManager.requestWhenInUseAuthorization()
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.startUpdatingLocation()
        refreshAccuracyHint()
        recorder.log("accuracy_authorization", ["reduced": locationManager.accuracyAuthorization == .reducedAccuracy])

        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravityAndHeading
        config.planeDetection = []
        arSession.delegate = self
        arSession.run(config, options: [.resetTracking, .removeExistingAnchors])
        recorder.log("ar_session_run")

        createGARSession()
        render()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        arSession.pause()
        arSession.delegate = nil
        garSession = nil
        locationManager.stopUpdatingLocation()
        recorder.end()
    }

    // MARK: Setup

    private func createGARSession() {
        do {
            // bundleIdentifier: nil makes ARCore use the app's own bundle id for the API-key restriction check.
            let session = try GARSession(apiKey: Secrets.googleAPIKey, bundleIdentifier: nil)
            guard session.isGeospatialModeSupported(.enabled) else {
                setupError = "GARSession: geospatial mode NOT supported on this device"
                recorder.log("setup_error", ["message": setupError ?? ""])
                return
            }
            let configuration = GARSessionConfiguration()
            configuration.geospatialMode = .enabled
            configuration.streetscapeGeometryMode = .enabled
            var configError: NSError?
            session.setConfiguration(configuration, error: &configError)
            if let configError {
                setupError = "setConfiguration failed: \(configError.localizedDescription)"
                recorder.log("setup_error", ["message": setupError ?? ""])
                return
            }
            garSession = session
            setupError = nil
            recorder.log("gar_session_created", ["geospatialSupported": true])
        } catch {
            setupError = "GARSession init failed: \(error.localizedDescription)"
        }
        if let setupError { recorder.log("setup_error", ["message": setupError]) }
    }

    // MARK: ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        lastCameraTransform = frame.camera.transform
        guard let garSession else { render(); return }

        do {
            let garFrame = try garSession.update(frame)
            update(with: garFrame)
        } catch {
            earthText = "GARSession.update failed: \(error.localizedDescription)"
        }
        requestVPSIfNeeded()
        record(frame: frame)
        render()
    }

    /// 1 Hz state entries, a JPEG every 5 s, and an extra JPEG right after each raycast tap.
    private func record(frame: ARFrame) {
        let now = CACurrentMediaTime()
        if recorder.shouldLogState(now: now) {
            var payload: [String: Any] = ["earth": earthText, "vps": vpsText, "arTracking": "\(frame.camera.trackingState)"]
            payload.merge(geoStats) { current, _ in current }
            if !meshStats.isEmpty { payload["mesh"] = meshStats }
            let t = frame.camera.transform
            payload["camPos"] = [Double(t.columns.3.x), Double(t.columns.3.y), Double(t.columns.3.z)]
            payload["camFwd"] = [Double(-t.columns.2.x), Double(-t.columns.2.y), Double(-t.columns.2.z)]
            recorder.log("state", payload)
        }
        if wantsTapPhoto {
            wantsTapPhoto = false
            recorder.capturePhoto(from: frame.capturedImage, label: "tap")
        } else if recorder.shouldCapturePhoto(now: now) {
            recorder.capturePhoto(from: frame.capturedImage, label: "auto")
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        setupError = "ARSession failed: \(error.localizedDescription)"
        recorder.log("ar_session_error", ["message": error.localizedDescription])
        render()
    }

    // MARK: Frame readout

    private func update(with garFrame: GARFrame) {
        guard let earth = garFrame.earth else {
            earthText = "earth: nil (geospatial not yet initialised)"
            return
        }

        earthText = "earth: tracking=\(Self.trackingName(earth.trackingState)) state=\(Self.earthStateName(earth.earthState))"

        if let transform = earth.cameraGeospatialTransform {
            let heading = Self.headingDegrees(from: transform.eastUpSouthQTarget)
            transformText = String(
                format: "geo: %.6f, %.6f  ±%.1fm | alt %.1fm ±%.1fm | hdg %.0f° ±%.0f°",
                transform.coordinate.latitude,
                transform.coordinate.longitude,
                transform.horizontalAccuracy,
                transform.altitude,
                transform.verticalAccuracy,
                heading,
                transform.orientationYawAccuracy)
            geoStats = [
                "lat": transform.coordinate.latitude,
                "lon": transform.coordinate.longitude,
                "hAcc": transform.horizontalAccuracy,
                "alt": transform.altitude,
                "vAcc": transform.verticalAccuracy,
                "hdg": heading,
                "yawAcc": transform.orientationYawAccuracy,
            ]
        } else {
            transformText = "geo: no camera transform yet"
            geoStats = [:]
        }

        summarise(garFrame.streetscapeGeometries)
        logGeometryDetailIfDue(garFrame.streetscapeGeometries)
    }

    /// Every 10 s: one compact line per geometry (capped at 60) so mesh arrival/quality can be replayed offline.
    private func logGeometryDetailIfDue(_ geometries: [GARStreetscapeGeometry]?) {
        let now = CACurrentMediaTime()
        guard let geometries, !geometries.isEmpty, now - lastGeometryDetailLog >= 10 else { return }
        lastGeometryDetailLog = now
        let detail = geometries.prefix(60).map { g -> [String: Any] in
            let o = g.meshTransform.columns.3
            return [
                "id": String(g.identifier.uuidString.prefix(8)),
                "type": g.type.rawValue == 1 ? "building" : "terrain",
                "q": g.quality.rawValue,
                "verts": Int(g.mesh.vertexCount),
                "tris": Int(g.mesh.triangleCount),
                "pos": [Double(o.x), Double(o.y), Double(o.z)],
            ]
        }
        recorder.log("geometries", ["count": geometries.count, "detail": detail])
    }

    private func summarise(_ geometries: [GARStreetscapeGeometry]?) {
        guard let geometries else {
            geometryText = "streetscape: nil (mode off or not yet available)"
            meshStats = [:]
            return
        }
        guard !geometries.isEmpty else {
            geometryText = "streetscape: 0 geometries"
            meshStats = ["total": 0]
            return
        }

        var buildings = 0
        var terrain = 0
        var qualityNone = 0
        var lod1 = 0
        var lod2 = 0
        var vertices = 0
        var triangles = 0
        var tracked = 0

        for geometry in geometries {
            // Raw values dodge any Swift-name drift on the imported ObjC enums: terrain=0, building=1.
            if geometry.type.rawValue == 1 { buildings += 1 } else { terrain += 1 }
            switch geometry.quality.rawValue {
            case 1: lod1 += 1
            case 2: lod2 += 1
            default: qualityNone += 1
            }
            if geometry.trackingState.rawValue == 0 { tracked += 1 }
            // GARMesh counts come across as NSUInteger.
            vertices += Int(geometry.mesh.vertexCount)
            triangles += Int(geometry.mesh.triangleCount)
        }

        geometryText = """
        streetscape: \(geometries.count) total (\(tracked) tracking)
          building=\(buildings)  terrain=\(terrain)
          quality: none=\(qualityNone) LOD1=\(lod1) LOD2=\(lod2)
          verts=\(vertices)  tris=\(triangles)
        """
        meshStats = [
            "total": geometries.count, "tracked": tracked,
            "buildings": buildings, "terrain": terrain,
            "lod1": lod1, "lod2": lod2, "qNone": qualityNone,
            "verts": vertices, "tris": triangles,
        ]
    }

    // MARK: VPS

    private func requestVPSIfNeeded() {
        guard !didRequestVPS, let garSession, let coordinate = locationManager.location?.coordinate else { return }
        didRequestVPS = true
        vpsText = "VPS: checking…"
        vpsFuture = garSession.checkVPSAvailability(coordinate: coordinate) { [weak self] availability in
            DispatchQueue.main.async {
                self?.vpsText = "VPS: \(Self.vpsName(availability))"
                self?.recorder.log("vps_result", [
                    "result": Self.vpsName(availability),
                    "lat": coordinate.latitude, "lon": coordinate.longitude,
                ])
                self?.render()
            }
        }
    }

    // MARK: Raycast

    /// Screen centre is the camera's optical axis, so the ray is just the camera position along its -Z.
    func raycastFromScreenCenter() {
        guard let garSession else {
            raycastText = "raycast: no GARSession"
            render()
            return
        }
        guard let transform = lastCameraTransform else {
            raycastText = "raycast: no camera transform"
            render()
            return
        }

        let origin = simd_float3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        let forward = -simd_float3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        let direction = simd_normalize(forward)

        do {
            let results = try garSession.raycastStreetscapeGeometry(origin: origin, direction: direction)
            if let hit = results.first {
                let kind = hit.streetscapeGeometry.type.rawValue == 1 ? "building" : "terrain"
                raycastText = String(format: "raycast: HIT %@ @ %.2fm (%d results)", kind, hit.distance, results.count)
            } else {
                raycastText = "raycast: no hit"
            }
            recorder.log("raycast", [
                "origin": [Double(origin.x), Double(origin.y), Double(origin.z)],
                "direction": [Double(direction.x), Double(direction.y), Double(direction.z)],
                "hits": results.map { [
                    "distance": Double($0.distance),
                    "type": $0.streetscapeGeometry.type.rawValue == 1 ? "building" : "terrain",
                    "id": String($0.streetscapeGeometry.identifier.uuidString.prefix(8)),
                ] },
            ])
        } catch {
            raycastText = "raycast failed: \(error.localizedDescription)"
            recorder.log("raycast_error", ["message": error.localizedDescription])
        }
        wantsTapPhoto = true
        // Only reached from the view's tap gesture; Haptics is main-actor isolated and this engine is not.
        MainActor.assumeIsolated { Haptics.tap() }
        render()
    }

    // MARK: Location

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        refreshAccuracyHint()
        recorder.log("accuracy_authorization", ["reduced": manager.accuracyAuthorization == .reducedAccuracy])
        render()
    }

    /// CoreLocation's own fix, logged at ≤1 Hz — the independent baseline to compare against ARCore's geospatial transform.
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let now = CACurrentMediaTime()
        guard now - lastGPSLog >= 1 else { return }
        lastGPSLog = now
        recorder.log("gps", [
            "lat": location.coordinate.latitude,
            "lon": location.coordinate.longitude,
            "hAcc": location.horizontalAccuracy,
            "alt": location.altitude,
            "vAcc": location.verticalAccuracy,
            "speed": location.speed,
            "course": location.course,
        ])
    }

    private func refreshAccuracyHint() {
        switch locationManager.accuracyAuthorization {
        case .fullAccuracy:
            accuracyText = ""
        case .reducedAccuracy:
            accuracyText = "⚠︎ Precise Location is OFF — Geospatial needs full accuracy (Settings ▸ Sightline ▸ Location)"
        @unknown default:
            accuracyText = "⚠︎ unknown location accuracy authorization"
        }
    }

    // MARK: Rendering

    private func render() {
        var output: [String] = []
        output.append("ARCore Streetscape spike")
        if let setupError { output.append("✕ \(setupError)") }
        if !accuracyText.isEmpty { output.append(accuracyText) }
        output.append(vpsText)
        output.append(earthText)
        output.append(transformText)
        output.append(contentsOf: geometryText.components(separatedBy: "\n"))
        output.append(raycastText)
        output.append(recorder.statusLine)

        let snapshot = output
        if Thread.isMainThread {
            lines = snapshot
        } else {
            DispatchQueue.main.async { [weak self] in self?.lines = snapshot }
        }
    }

    // MARK: Naming helpers

    private static func trackingName(_ state: GARTrackingState) -> String {
        switch state.rawValue {
        case 0: return "tracking"
        case 1: return "paused"
        case 2: return "stopped"
        default: return "raw(\(state.rawValue))"
        }
    }

    private static func earthStateName(_ state: GAREarthState) -> String {
        switch state.rawValue {
        case 0: return "enabled"
        case -1: return "ERROR_INTERNAL"
        case -2: return "ERROR_NOT_AUTHORIZED"
        case -3: return "ERROR_RESOURCE_EXHAUSTED"
        default: return "raw(\(state.rawValue))"
        }
    }

    private static func vpsName(_ availability: GARVPSAvailability) -> String {
        switch availability.rawValue {
        case 0: return "UNKNOWN"
        case 1: return "AVAILABLE"
        case 2: return "UNAVAILABLE"
        case -1: return "ERROR_INTERNAL"
        case -2: return "ERROR_NETWORK"
        case -3: return "ERROR_NOT_AUTHORIZED (enable ARCore API in Cloud console)"
        case -4: return "ERROR_RESOURCE_EXHAUSTED"
        default: return "raw(\(availability.rawValue))"
        }
    }

    /// `heading` on GARGeospatialTransform is deprecated since 1.35, so derive it from the East-Up-South quaternion.
    private static func headingDegrees(from eastUpSouthQTarget: simd_quatf) -> Double {
        let forward = simd_act(eastUpSouthQTarget, simd_float3(0, 0, -1))
        let east = Double(forward.x)
        let north = Double(-forward.z)
        var degrees = atan2(east, north) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        return degrees
    }
}

#endif

#endif
