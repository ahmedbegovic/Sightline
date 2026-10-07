import SwiftUI
import UIKit

#if !targetEnvironment(simulator)
import ARKit
import SceneKit

// MARK: - AR camera feed

/// Hosts the live ARSession's video feed. Renders no SceneKit content and attaches no gestures — bubble taps must win.
struct ARCameraContainer: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = session
        view.scene = SCNScene()
        view.automaticallyUpdatesLighting = false
        view.antialiasingMode = .none
        // Video and overlay must run on the same clock; at 30 vs ~33 Hz the bubble is drawn against a frame it does not match.
        view.preferredFramesPerSecond = 60
        view.rendersContinuously = false
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        if uiView.session !== session { uiView.session = session }
    }
}

#endif
