import AVFoundation
import Combine
import SwiftUI
import UIKit

/// Owns the AR camera AVCaptureSession, run on a private serial queue; in the simulator `isAvailable` stays false.
@MainActor
final class CameraManager: ObservableObject {

    /// False in the simulator and whenever permission is denied or setup fails.
    @Published private(set) var isAvailable = false
    /// True once the user has explicitly denied (or is restricted from) camera access.
    @Published private(set) var permissionDenied = false

    let session = AVCaptureSession()

    #if !targetEnvironment(simulator)
    private let sessionQueue = DispatchQueue(label: "com.citylens.camera.session")
    #endif

    /// Safe to call repeatedly (e.g. on every foreground transition) — `configureAndRun()` no-ops on an already-running session.
    func start() {
        #if targetEnvironment(simulator)
        isAvailable = false
        #else
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            permissionDenied = false
            configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if granted {
                        self.permissionDenied = false
                        self.configureAndRun()
                    } else {
                        self.permissionDenied = true
                        self.isAvailable = false
                    }
                }
            }
        default:
            permissionDenied = true
            isAvailable = false
        }
        #endif
    }

    func stop() {
        #if !targetEnvironment(simulator)
        let box = SessionBox(session: session)
        sessionQueue.async { [weak self] in
            let session = box.session
            if session.isRunning { session.stopRunning() }
            Task { @MainActor [weak self] in
                self?.isAvailable = false
            }
        }
        #endif
    }

    #if !targetEnvironment(simulator)
    private var sessionObserverTokens: [NSObjectProtocol] = []

    /// Keeps `isAvailable` honest when the OS interrupts or resets the session — otherwise AR renders over a frozen feed.
    private func installSessionObserversIfNeeded() {
        guard sessionObserverTokens.isEmpty else { return }
        let nc = NotificationCenter.default
        let box = SessionBox(session: session)
        let queue = sessionQueue

        sessionObserverTokens.append(nc.addObserver(
            forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { [weak self] note in
            let wasReset = (note.userInfo?[AVCaptureSessionErrorKey] as? AVError)?.code == .mediaServicesWereReset
            queue.async {
                let session = box.session
                if wasReset, !session.isRunning {
                    session.startRunning()
                }
                let running = session.isRunning
                Task { @MainActor in self?.isAvailable = running }
            }
        })

        sessionObserverTokens.append(nc.addObserver(
            forName: .AVCaptureSessionWasInterrupted, object: session, queue: nil) { [weak self] _ in
            Task { @MainActor in self?.isAvailable = false }
        })

        sessionObserverTokens.append(nc.addObserver(
            forName: .AVCaptureSessionInterruptionEnded, object: session, queue: nil) { [weak self] _ in
            queue.async {
                let session = box.session
                // iOS doesn't always auto-resume the session here — kick it explicitly rather than racing that.
                if !session.isRunning {
                    session.startRunning()
                }
                let running = session.isRunning
                Task { @MainActor in self?.isAvailable = running }
            }
        })
    }

    private func configureAndRun() {
        installSessionObserversIfNeeded()
        let box = SessionBox(session: session)
        sessionQueue.async { [weak self] in
            let session = box.session
            var configured = !session.inputs.isEmpty
            if !configured {
                session.beginConfiguration()
                if session.canSetSessionPreset(.high) {
                    session.sessionPreset = .high
                }
                if let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                        for: .video,
                                                        position: .back),
                   let input = try? AVCaptureDeviceInput(device: device),
                   session.canAddInput(input) {
                    session.addInput(input)
                    configured = true
                }
                session.commitConfiguration()
            }
            if configured, !session.isRunning {
                session.startRunning()
            }
            let running = configured && session.isRunning
            Task { @MainActor [weak self] in
                self?.isAvailable = running
            }
        }
    }
    #endif
}

#if !targetEnvironment(simulator)
/// Sound: past init, every call into the boxed session (configure/start/stop/isRunning) runs on the one serial sessionQueue; all other contexts only pass the reference along.
private struct SessionBox: @unchecked Sendable {
    let session: AVCaptureSession
}
#endif

// MARK: - SwiftUI preview surface

/// Full-screen camera feed, UIView-backed so AVCaptureVideoPreviewLayer does per-frame work outside SwiftUI.
struct CameraPreviewView: UIViewRepresentable {

    private let session: AVCaptureSession

    init(session: AVCaptureSession) {
        self.session = session
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.session = session
        applyPortraitRotation(to: view)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
        }
        // The connection appears asynchronously with the input — re-apply so orientation locks in once available.
        applyPortraitRotation(to: uiView)
    }

    private func applyPortraitRotation(to view: PreviewView) {
        // The app is portrait-only; make sure the preview matches.
        guard let connection = view.previewLayer.connection,
              connection.isVideoRotationAngleSupported(90) else { return }
        if connection.videoRotationAngle != 90 {
            connection.videoRotationAngle = 90
        }
    }
}
