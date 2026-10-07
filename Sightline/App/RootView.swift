import SwiftUI
import UIKit

/// Scan-toast copy. The icon has to vary with the kind — a wifi glyph on an API error is its own small lie.
private extension ScanFailure {
    var symbolName: String {
        switch self {
        case .noCamera: return "camera.fill"
        case .offline: return "wifi.exclamationmark"
        case .serviceBusy: return "clock.arrow.circlepath"
        case .other: return "exclamationmark.triangle"
        }
    }

    var message: String {
        switch self {
        case .noCamera: return "The camera isn't running — scanning needs it."
        case .offline: return "Check your connection and try again."
        case .serviceBusy: return "Maps is busy — try again in a moment."
        case .other: return "Something went wrong — try again."
        }
    }

    /// Nothing but the glyph distinguished a failure from a progress toast before this.
    var tone: HUDPillTone {
        switch self {
        case .noCamera, .offline, .serviceBusy: return .warning
        case .other: return .danger
        }
    }
}

// MARK: - Root composition

/// The main screen: camera, AR bubbles, guidance, HUD, detail card, mini-map and assistant sheet layered in one ZStack.
struct RootView: View {
    @EnvironmentObject var app: AppState
    @State private var dragHintDismissed = false
    @Environment(\.scenePhase) private var scenePhase

    init() {}

    var body: some View {
        ZStack {
            // 1–2. Camera (AR feed, AVCapture preview or simulator backdrop) + look-around drag.
            RootCameraLayer(camera: app.camera, pose: app.pose) {
                dismissDragHint()
            }

            RootScrim()

            // 3. AR bubbles — hidden while navigating or while the map is expanded.
            RootBubbleLayer(router: app.router,
                            places: app.places,
                            pose: app.pose,
                            selected: $app.selectedPlace,
                            isMapExpanded: app.isMapExpanded)

            // 3b. Aim point: a scan names what sits under it.
            AimReticle(scanUI: app.scanUI, router: app.router,
                       covered: app.selectedPlace != nil || app.isMapExpanded)

            // 4. Navigation guidance — always mounted; the ribbon canvas ignores the safe area, the HUD must not.
            GuidanceOverlayView(router: app.router,
                                poseManager: app.pose,
                                onStop: { app.stopNavigation() })

            // 5–6. Search bar, results pill, scan-state toast.
            RootTopHUD(app: app, scanUI: app.scanUI, router: app.router)

            // 7. Scan button + mini-map.
            RootBottomBar(app: app,
                          scanUI: app.scanUI,
                          router: app.router,
                          showDragHint: app.pose.isSimulated && !dragHintDismissed)
                .zIndex(app.isMapExpanded ? 60 : 10)

            // 8. Place detail card.
            RootDetailLayer(app: app)
                .zIndex(50)

            // 9. Location permission overlay.
            RootLocationDeniedOverlay(flags: app.pose.flags)
                .zIndex(70)

        }
        .background(Color.black.ignoresSafeArea())
        // 10. Assistant sheet.
        .sheet(item: $app.assistantPlace) { place in
            AssistantView(place: place, userLocation: app.pose.pose.location)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .preferredColorScheme(.dark)
        }
        // 11. Boot + status bar.
        .task { app.start() }
        .task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            dismissDragHint()
        }
        // Camera sessions get killed by interruptions the OS doesn't always resume on its own — retry on return to foreground.
        // An ARSession left running in the background is a battery and thermal problem, so route both directions.
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active: app.resumeForForeground()
            case .inactive, .background: app.pauseForBackground()
            @unknown default: break
            }
        }
        .statusBarHidden(false)
    }

    private func dismissDragHint() {
        guard !dragHintDismissed else { return }
        withAnimation(Theme.Motion.standard) {
            dragHintDismissed = true
        }
    }
}

// MARK: - Camera layer

private struct RootCameraLayer: View {
    @ObservedObject var camera: ARCameraEngine
    let pose: PoseManager
    let onLookAround: () -> Void

    @State private var lastTranslation: CGSize = .zero

    var body: some View {
        Group {
            #if targetEnvironment(simulator)
            MockStreetBackdrop(poseManager: pose)
            #else
            switch camera.failure {
            case nil: ARCameraContainer(session: camera.session)
            case .permissionDenied: CameraPermissionDeniedOverlay()
            case .unavailable: CameraUnavailableOverlay()
            }
            #endif
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .gesture(lookGesture, including: pose.isSimulated ? .all : .subviews)
    }

    private var lookGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let dx = value.translation.width - lastTranslation.width
                let dy = value.translation.height - lastTranslation.height
                lastTranslation = value.translation
                // Dragging the world left looks right; dragging down looks up.
                pose.nudgeVirtualHeading(byDegrees: -dx * 0.22)
                pose.nudgeVirtualPitch(byDegrees: dy * 0.12)
                onLookAround()
            }
            .onEnded { _ in lastTranslation = .zero }
    }
}

// MARK: - Camera failure (device only — MockStreetBackdrop is a simulator artifact)

/// Real device, ARKit could not run, but permission isn't the problem.
private struct CameraUnavailableOverlay: View {
    var body: some View {
        ZStack {
            Color.black
            PermissionCard(symbol: "camera.fill",
                           title: "Camera unavailable",
                           message: nil)
        }
        .ignoresSafeArea()
    }
}

/// Real device, camera access explicitly denied (or restricted).
private struct CameraPermissionDeniedOverlay: View {
    var body: some View {
        ZStack {
            Color.black
            PermissionCard(symbol: "camera.fill",
                           title: "Camera access needed",
                           message: "Sightline uses your camera to overlay places on the world around you.",
                           actionTitle: "Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Legibility scrim

/// Proportional, not fixed: 180/220 pt swallowed the scan glow on a small device and stopped short on a Pro Max.
private struct RootScrim: View {
    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.50), .black.opacity(0.16), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: geo.size.height * 0.20)
                Spacer(minLength: 0)
                LinearGradient(colors: [.clear, .black.opacity(0.18), .black.opacity(0.55)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: geo.size.height * 0.26)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - Bubble layer

private struct RootBubbleLayer: View {
    @ObservedObject var router: RouteManager
    let places: [Place]
    let pose: PoseManager
    @Binding var selected: Place?
    let isMapExpanded: Bool

    var body: some View {
        ZStack {
            if router.route == nil && !isMapExpanded {
                BubbleOverlayView(places: places, poseManager: pose, selected: $selected)
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: router.route == nil)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isMapExpanded)
    }
}

// MARK: - Aim reticle

/// Marks the centre of the frame — the thing under it is what a scan names first.
private struct AimReticle: View {
    @ObservedObject var scanUI: ScanUIModel
    @ObservedObject var router: RouteManager
    let covered: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let scanning = scanUI.state == .scanning
        ZStack {
            Circle()
                .strokeBorder(Theme.textPrimary.opacity(0.75), lineWidth: 1.5)
                .frame(width: 54, height: 54)
                .scaleEffect(scanning && !reduceMotion ? 0.82 : 1)
                .animation(scanning && !reduceMotion
                           ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true) : .default,
                           value: scanning)
            Circle()
                .fill(Theme.textPrimary.opacity(0.9))
                .frame(width: 4, height: 4)
        }
        .shadow(color: .black.opacity(0.35), radius: 3)
        .opacity(covered || router.route != nil ? 0 : 1)
        .animation(Theme.Motion.standard, value: covered)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }
}

// MARK: - Top HUD (search + results + toast)

/// One transient message at a time, cross-faded in place: scanning -> empty -> failed keeps the same pill.
private struct ToastSpec: Equatable {
    let symbol: String?
    let text: String
    let tone: HUDPillTone
}

private struct RootTopHUD: View {
    @ObservedObject var app: AppState
    @ObservedObject var scanUI: ScanUIModel
    @ObservedObject var router: RouteManager

    private var isNavigating: Bool { router.route != nil }

    private var toast: ToastSpec? {
        switch scanUI.state {
        case .scanning:
            return ToastSpec(symbol: nil, text: "Scanning…", tone: .info)
        case .empty:
            return ToastSpec(symbol: "binoculars",
                             text: "Nothing recognised — put it in the circle and try again.", tone: .neutral)
        case .failed(let failure):
            return ToastSpec(symbol: failure.symbolName, text: failure.message, tone: failure.tone)
        case .idle, .found:
            // .found shows nothing — the bubbles are the feedback.
            return nil
        }
    }

    var body: some View {
        VStack(spacing: Theme.Space.s + 2) {
            HUDStatusPill(flags: app.pose.flags)

            if !isNavigating {
                RootSearchField(search: scanUI.search,
                                isBusy: scanUI.state == .scanning,
                                onSubmit: { app.search() },
                                onClear: { app.clearResults() })
                    .transition(.move(edge: .top).combined(with: .opacity))

                if let label = scanUI.resultsLabel {
                    resultsPill(label)
                        .transition(.scale.combined(with: .opacity))
                }
            }

            if let toast {
                HUDPill(tone: toast.tone,
                        text: toast.text,
                        symbol: toast.symbol,
                        leading: toast.symbol == nil
                            ? AnyView(SpinnerRing(size: 14, lineWidth: 1.8))
                            : nil)
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, Theme.Space.xs + 2)
        .animation(Theme.Motion.standard, value: isNavigating)
        .animation(Theme.Motion.standard, value: scanUI.state)
        .animation(Theme.Motion.standard, value: scanUI.resultsLabel)
    }

    private func resultsPill(_ label: String) -> some View {
        HStack(spacing: 0) {
            Text(label)
                .font(Theme.Typography.hudLabel)
                .foregroundStyle(Theme.textPrimary)
            Button {
                app.clearResults()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 44, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear results")
        }
        .padding(.leading, 14)
        .hudPillChrome()
    }
}

/// Owns the keystroke: the field observes the text model directly, so typing invalidates this view and
/// nothing above it. Hoisting the binding into RootTopHUD re-bodied the HUD on every character.
private struct RootSearchField: View {
    @ObservedObject var search: SearchTextModel
    let isBusy: Bool
    let onSubmit: () -> Void
    let onClear: () -> Void

    var body: some View {
        SearchBarView(text: $search.text,
                      isBusy: isBusy,
                      onSubmit: onSubmit,
                      onClear: onClear)
    }
}

// MARK: - Bottom bar (scan button + mini-map)

private struct RootBottomBar: View {
    @ObservedObject var app: AppState
    @ObservedObject var scanUI: ScanUIModel
    @ObservedObject var router: RouteManager
    let showDragHint: Bool

    private var isNavigating: Bool { router.route != nil }
    private var hidesScan: Bool {
        isNavigating || app.selectedPlace != nil || app.isMapExpanded
    }
    private var hidesMap: Bool {
        app.selectedPlace != nil && !app.isMapExpanded
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if !hidesScan {
                VStack(spacing: Theme.Space.m) {
                    if showDragHint {
                        HUDPill(tone: .neutral, text: "Drag to look around", symbol: "hand.draw")
                            .allowsHitTesting(false)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                    ScanButton(state: scanUI.state) { app.scan() }
                }
                .padding(.bottom, 10)
                .transition(.scale(scale: 0.85).combined(with: .opacity))
            }

            MiniMapView(poseManager: app.pose,
                        places: app.places,
                        router: router,
                        selected: $app.selectedPlace,
                        isExpanded: $app.isMapExpanded)
                .padding(.leading, app.isMapExpanded ? 0 : 14)
                .padding(.bottom, app.isMapExpanded ? 0 : 6)
                .frame(maxWidth: .infinity,
                       maxHeight: .infinity,
                       alignment: app.isMapExpanded ? .center : .bottomLeading)
                .opacity(hidesMap ? 0 : 1)
                .scaleEffect(hidesMap ? 0.85 : 1, anchor: .bottomLeading)
                .allowsHitTesting(!hidesMap)
                .zIndex(app.isMapExpanded ? 60 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(Theme.Motion.standard, value: isNavigating)
        .animation(Theme.Motion.standard, value: app.selectedPlace?.id)
        .animation(Theme.Motion.gentle, value: app.isMapExpanded)
        .animation(Theme.Motion.standard, value: showDragHint)
    }
}

// MARK: - Detail card layer

private struct RootDetailLayer: View {
    @ObservedObject var app: AppState

    var body: some View {
        ZStack(alignment: .bottom) {
            if let place = app.selectedPlace {
                // Local, not full-screen: a full scrim would dim the camera and swallow taps on the bubbles behind.
                LinearGradient(colors: [.clear, .black.opacity(0.35)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 160)
                    .allowsHitTesting(false)
                    .transition(.opacity)

                PlaceDetailCard(
                    place: place,
                    distance: place.distance(from: app.pose.pose.location),
                    onNavigate: { app.navigate(to: place) },
                    onAsk: { app.assistantPlace = place },
                    onClose: {
                        withAnimation(Theme.Motion.gentle) {
                            app.selectedPlace = nil
                        }
                    })
                    .padding(.bottom, Theme.Space.s)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(Theme.Motion.gentle, value: app.selectedPlace?.id)
    }
}

// MARK: - Location denied

private struct RootLocationDeniedOverlay: View {
    /// PoseFlags, not PoseManager — one flag is not worth a body pass per pose tick.
    @ObservedObject var flags: PoseFlags

    var body: some View {
        if flags.locationDenied {
            PermissionCard(symbol: "location.slash",
                           title: "Location needed",
                           message: "Sightline uses your location to find places around you.",
                           actionTitle: "Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        }
    }
}
