import SwiftUI
import Combine
import CoreLocation

/// AR navigation overlay: animated ground ribbon, flowing chevrons, destination marker, and a slim instruction HUD.
struct GuidanceOverlayView: View {
    @ObservedObject private var router: RouteManager
    private let poseManager: PoseManager
    private let onStop: () -> Void

    // HUD state — refreshed once per second, never per frame.
    @State private var hudRemaining: CLLocationDistance = 0
    @State private var hudTime: TimeInterval = 0
    @State private var hudInstruction: String?
    @State private var arrivalShown = false
    @State private var stopScheduled = false
    @State private var stopTask: Task<Void, Never>?
    @State private var errorVisible = false
    @State private var lastDestinationID: String?
    /// Start of the ribbon's arc-length reveal; nil once the route clears.
    @State private var routeRevealStart: Date?
    /// Reference type so per-frame Canvas evaluation can refresh it without a SwiftUI state write.
    @State private var pathCache = PathCache()

    // @State, not a stored property: a stored publisher is rebuilt on every body pass and re-installs the runloop subscription.
    @State private var hudTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(router: RouteManager, poseManager: PoseManager, onStop: @escaping () -> Void) {
        _router = ObservedObject(wrappedValue: router)
        self.poseManager = poseManager
        self.onStop = onStop
    }

    var body: some View {
        ZStack {
            if let route = router.route {
                routeContent(route)
            } else if router.isCalculating {
                statusOverlay { calculatingPill }
            } else if let message = router.lastError {
                statusOverlay { errorPill(message) }
                    .opacity(errorVisible ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if let route = router.route {
                handleRouteChange(route)
                refreshHUD()
            }
        }
        .onReceive(hudTimer) { _ in refreshHUD() }
        .onReceive(router.$route) { handleRouteChange($0) }
        .task(id: router.lastError) { await animateErrorPill() }
    }

    // MARK: - Layers

    private func routeContent(_ route: ActiveRoute) -> some View {
        ZStack {
            GeometryReader { geo in
                TimelineView(.animation) { timeline in
                    let frame = computeFrame(size: geo.size, date: timeline.date)
                    Canvas { context, canvasSize in
                        if let frame {
                            draw(frame, in: &context, size: canvasSize)
                        }
                    }
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 8) {
                topCard(route)
                if let instruction = hudInstruction, !arrivalShown {
                    instructionPill(instruction)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .animation(Theme.Motion.standard, value: hudInstruction)

            if arrivalShown {
                arrivalCard(route)
                    .transition(.scale(scale: 0.90).combined(with: .opacity))
            }
        }
    }

    private func statusOverlay<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack {
            content()
            Spacer()
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity)
    }

    // MARK: - HUD pieces

    private func topCard(_ route: ActiveRoute) -> some View {
        HStack(spacing: 10) {
            CategoryBadge(category: route.destination.category, size: 34, silhouette: .circle)

            VStack(alignment: .leading, spacing: 2) {
                Text(route.destination.name)
                    .font(Theme.Typography.hudTitle)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text("\(Format.distance(hudRemaining)) · \(Format.duration(hudTime)) · walking")
                    .font(Theme.Typography.micro)
                    .foregroundStyle(Theme.textSecondary)
                    .monospacedDigit()
            }

            Spacer(minLength: Theme.Space.s)

            Button {
                Haptics.tap()
                onStop()
            } label: {
                Text("End")
                    .font(Theme.Typography.chipLabel)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Theme.Space.l)
                    .frame(height: 36)
                    .background(Theme.danger.opacity(0.9), in: Capsule())
                    .frame(height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("End navigation")
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .glassCard()
    }

    private func instructionPill(_ text: String) -> some View {
        HUDPill(tone: .info, text: text, symbol: Self.arrowSymbol(for: text))
    }

    private var calculatingPill: some View {
        HUDPill(tone: .neutral, text: "Finding route…",
                leading: AnyView(SpinnerRing(size: 14, lineWidth: 1.8, tint: Theme.accent)))
    }

    private func errorPill(_ message: String) -> some View {
        HUDPill(tone: .warning, text: message, symbol: "exclamationmark.triangle.fill")
    }

    private func arrivalCard(_ route: ActiveRoute) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(Theme.positive)
                .symbolEffect(.bounce, value: arrivalShown)
            Text("You've arrived")
                .font(Theme.Typography.cardTitle)
                .foregroundStyle(Theme.textPrimary)
            Text(route.destination.name)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, Theme.Space.xxl)
        .glassCard(cornerRadius: Theme.Radius.sheet, elevation: .high)
    }

    private static func arrowSymbol(for instruction: String) -> String {
        let lower = instruction.lowercased()
        if lower.contains("left") { return "arrow.turn.up.left" }
        if lower.contains("right") { return "arrow.turn.up.right" }
        return "arrow.up"
    }

    // MARK: - HUD refresh (1 Hz, not per frame)

    private func refreshHUD() {
        guard router.route != nil,
              let location = poseManager.pose.location,
              let prog = router.progress(from: location) else { return }

        hudRemaining = prog.remainingDistance
        hudTime = prog.remainingTime
        hudInstruction = prog.nextInstruction

        if prog.hasArrived, !arrivalShown {
            withAnimation(Theme.Motion.gentle) {
                arrivalShown = true
            }
            Haptics.success()
            if !stopScheduled {
                stopScheduled = true
                stopTask = Task {
                    try? await Task.sleep(nanoseconds: 3_500_000_000)
                    guard !Task.isCancelled else { return }
                    onStop()
                }
            }
        }
    }

    private func handleRouteChange(_ newRoute: ActiveRoute?) {
        // Every route swap (including same-destination reroutes) invalidates the cached geo path.
        pathCache.clear()
        // Cancel any pending arrival auto-stop so a stale timer can't kill a new route.
        guard let newRoute else {
            stopTask?.cancel()
            stopTask = nil
            arrivalShown = false
            stopScheduled = false
            lastDestinationID = nil
            hudInstruction = nil
            routeRevealStart = nil
            return
        }
        if newRoute.destination.id != lastDestinationID {
            stopTask?.cancel()
            stopTask = nil
            lastDestinationID = newRoute.destination.id
            arrivalShown = false
            stopScheduled = false
            // Only a genuinely new destination re-reveals; .onAppear with a live route must not replay it.
            routeRevealStart = Date()
        }
        hudRemaining = newRoute.totalDistance
        hudTime = newRoute.expectedTravelTime
        hudInstruction = newRoute.steps.first?.instruction
    }

    private func animateErrorPill() async {
        guard router.lastError != nil else {
            errorVisible = false
            return
        }
        withAnimation(.easeOut(duration: 0.25)) { errorVisible = true }
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.6)) { errorVisible = false }
    }

    // MARK: - Per-frame geometry

    /// Holds the ~8 Hz location-dependent path so the per-frame pass only projects.
    private final class PathCache {
        var stampedAt: TimeInterval = -1
        var progress: RouteProgress?
        var coords: [CLLocationCoordinate2D] = []
        var approxDist: [Double] = []

        func clear() {
            stampedAt = -1
            progress = nil
            coords.removeAll(keepingCapacity: true)
            approxDist.removeAll(keepingCapacity: true)
        }
    }

    private struct GuidanceFrame {
        enum DestinationMark {
            case hidden
            case onScreen(CGPoint)
            case offScreen(isLeft: Bool, distance: CLLocationDistance)
        }

        var center: [CGPoint] = []
        var halfWidths: [CGFloat] = []
        var opacities: [Double] = []
        var arcLengths: [CGFloat] = []
        var chevronPhase: CGFloat = 0
        var pulse: Double = 0
        var destination: DestinationMark = .hidden
        /// 0…1 arc-length growth applied to the ribbon; 1 once the reveal has finished.
        var reveal: Double = 1
    }

    private func computeFrame(size: CGSize, date: Date) -> GuidanceFrame? {
        guard size.width > 1, size.height > 1 else { return nil }
        guard let route = router.route else { return nil }
        let pose = poseManager.pose
        guard let location = pose.location, let userCoord = pose.coordinate else { return nil }

        // Location-dependent path refresh runs at ~8 Hz; everything below tracks the camera every frame.
        let now = date.timeIntervalSinceReferenceDate
        if pathCache.progress == nil || now - pathCache.stampedAt >= 0.125 {
            pathCache.stampedAt = now
            pathCache.progress = router.progress(from: location)
            rebuildPath(around: userCoord)
        }
        guard let prog = pathCache.progress else { return nil }
        let coords = pathCache.coords
        let approxDist = pathCache.approxDist

        var frame = GuidanceFrame()
        let t = date.timeIntervalSinceReferenceDate
        // The ribbon itself must still track the camera every frame; only the decorative motion freezes.
        frame.chevronPhase = reduceMotion ? 0 : CGFloat((t * 34).truncatingRemainder(dividingBy: 46))
        frame.pulse = reduceMotion ? 0 : (t / 1.5).truncatingRemainder(dividingBy: 1)
        frame.reveal = reduceMotion
            ? 1
            : (routeRevealStart.map { min(1, max(0, date.timeIntervalSince($0) / 0.45)) } ?? 1)

        // Keep only the first contiguous run of projectable points; joining across gaps draws a ribbon doubling back over itself.
        var pts: [CGPoint] = []
        var dists: [Double] = []
        pts.reserveCapacity(coords.count)
        dists.reserveCapacity(coords.count)
        for k in 0..<coords.count {
            // End the ribbon where the path bends out of the forward cone — the projector's x-clamp would mirror the far leg back on screen.
            let pointBearing = ARProjector.bearing(from: userCoord, to: coords[k])
            let delta = abs(Angles.shortestDelta(from: pose.headingDegrees, to: pointBearing))
            if delta > 55 {
                if pts.isEmpty { continue } else { break }
            }
            if let gp = ARProjector.groundPoint(for: coords[k], pose: pose, screenSize: size) {
                if let last = pts.last, abs(gp.x - last.x) > size.width * 0.5 { break }
                pts.append(gp)
                dists.append(approxDist[k])
            } else if !pts.isEmpty {
                break
            }
        }

        if pts.count >= 2 {
            // One smoothing pass (weighted midpoint averaging on interior points), in place: `prev` carries the pre-smoothing neighbor.
            if pts.count >= 3 {
                var prev = pts[0]
                for k in 1..<(pts.count - 1) {
                    let current = pts[k]
                    pts[k] = CGPoint(x: (prev.x + 2 * current.x + pts[k + 1].x) / 4,
                                     y: (prev.y + 2 * current.y + pts[k + 1].y) / 4)
                    prev = current
                }
            }
            frame.center = pts
            frame.halfWidths = dists.map { CGFloat(min(30.0, max(3.0, 950.0 / max($0, 1.0)))) }
            frame.opacities = dists.map { max(0.08, 1.0 - $0 / 320.0) }

            var arcs: [CGFloat] = [0]
            arcs.reserveCapacity(pts.count)
            for k in 1..<pts.count {
                arcs.append(arcs[k - 1] + hypot(pts[k].x - pts[k - 1].x,
                                                pts[k].y - pts[k - 1].y))
            }
            frame.arcLengths = arcs

            // Unroll the ribbon outward from the user's feet; drawChevrons already respects arcLengths.last.
            if frame.reveal < 1, let total = arcs.last, total > 0 {
                let limit = CGFloat(frame.reveal) * total
                let keep = max(2, arcs.firstIndex { $0 > limit } ?? arcs.count)
                if keep < arcs.count {
                    frame.center = Array(frame.center.prefix(keep))
                    frame.halfWidths = Array(frame.halfWidths.prefix(keep))
                    frame.opacities = Array(frame.opacities.prefix(keep))
                    frame.arcLengths = Array(arcs.prefix(keep))
                }
            }
        }

        // Destination marker: on-screen pin or an edge chip pointing the way.
        let destCoord = route.points.last ?? route.destination.coordinate
        if let gp = ARProjector.groundPoint(for: destCoord, pose: pose, screenSize: size),
           gp.x > -30, gp.x < size.width + 30, gp.y > -40, gp.y < size.height + 40 {
            frame.destination = .onScreen(gp)
        } else {
            let bearing = ARProjector.bearing(from: userCoord, to: destCoord)
            let delta = Angles.shortestDelta(from: pose.headingDegrees, to: bearing)
            frame.destination = .offScreen(isLeft: delta < 0, distance: prog.remainingDistance)
        }
        return frame
    }

    /// Refills the downsampled, lead-trimmed geo path from the cached progress; runs at ~8 Hz, never per frame.
    private func rebuildPath(around userCoord: CLLocationCoordinate2D) {
        pathCache.coords.removeAll(keepingCapacity: true)
        pathCache.approxDist.removeAll(keepingCapacity: true)
        guard let prog = pathCache.progress else { return }

        // Adaptive downsample (distance ≈ index * 4 m): every point near, every 3rd beyond 60 m, every 6th beyond 120 m.
        let lookahead = prog.lookahead
        let limit = min(lookahead.count, 1500)
        var i = 0
        while i < limit {
            let d = Double(i) * 4.0
            pathCache.coords.append(lookahead[i])
            pathCache.approxDist.append(d)
            if d < 60 {
                i += 1
            } else if d < 120 {
                i += 3
            } else {
                i += 6
            }
        }

        // Drop leading points closer than 1.5 m to the user.
        var lead = 0
        while lead < pathCache.coords.count,
              ARProjector.distanceMeters(from: userCoord, to: pathCache.coords[lead]) < 1.5 {
            lead += 1
        }
        if lead > 0 {
            pathCache.coords.removeFirst(lead)
            pathCache.approxDist.removeFirst(lead)
        }
    }

    // MARK: - Canvas drawing

    private func draw(_ frame: GuidanceFrame, in ctx: inout GraphicsContext, size: CGSize) {
        let center = frame.center
        if center.count >= 2 {
            let n = center.count

            // Ribbon polygon from perpendicular offsets in screen space.
            var left: [CGPoint] = []
            var right: [CGPoint] = []
            left.reserveCapacity(n)
            right.reserveCapacity(n)
            for k in 0..<n {
                let prev = center[max(0, k - 1)]
                let next = center[min(n - 1, k + 1)]
                var dx = next.x - prev.x
                var dy = next.y - prev.y
                let len = max(hypot(dx, dy), 0.001)
                dx /= len
                dy /= len
                let w = frame.halfWidths[k]
                left.append(CGPoint(x: center[k].x - dy * w, y: center[k].y + dx * w))
                right.append(CGPoint(x: center[k].x + dy * w, y: center[k].y - dx * w))
            }

            var ribbon = Path()
            ribbon.move(to: left[0])
            for k in 1..<n { ribbon.addLine(to: left[k]) }
            for k in stride(from: n - 1, through: 0, by: -1) { ribbon.addLine(to: right[k]) }
            ribbon.closeSubpath()

            ctx.fill(ribbon, with: .linearGradient(
                Gradient(colors: [Theme.accent.opacity(0.9),
                                  Theme.accentSecondary.opacity(0.15)]),
                startPoint: center[0],
                endPoint: center[n - 1]))

            // Bright center line, additive near the bottom, fading out with distance.
            var line = Path()
            line.move(to: center[0])
            for k in 1..<n { line.addLine(to: center[k]) }
            var glow = ctx
            glow.blendMode = .plusLighter
            glow.stroke(line, with: .linearGradient(
                Gradient(colors: [Color.white.opacity(0.65), Color.white.opacity(0)]),
                startPoint: center[0],
                endPoint: center[n - 1]),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

            drawChevrons(frame, in: &ctx)
        }
        drawDestination(frame, in: &ctx, size: size)
    }

    private func drawChevrons(_ frame: GuidanceFrame, in ctx: inout GraphicsContext) {
        let arcs = frame.arcLengths
        guard let total = arcs.last, total > 8 else { return }
        let center = frame.center

        var seg = 1
        var pos = frame.chevronPhase
        while pos < total {
            while seg < arcs.count, arcs[seg] < pos { seg += 1 }
            guard seg < arcs.count else { break }

            let a0 = arcs[seg - 1]
            let a1 = arcs[seg]
            let f: CGFloat = a1 > a0 ? (pos - a0) / (a1 - a0) : 0
            let p0 = center[seg - 1]
            let p1 = center[seg]
            var dx = p1.x - p0.x
            var dy = p1.y - p0.y
            let len = max(hypot(dx, dy), 0.001)
            dx /= len
            dy /= len

            let w = frame.halfWidths[seg - 1]
                + (frame.halfWidths[seg] - frame.halfWidths[seg - 1]) * f
            if w >= 5 {
                let op = frame.opacities[seg - 1]
                    + (frame.opacities[seg] - frame.opacities[seg - 1]) * Double(f)
                let px = p0.x + (p1.x - p0.x) * f
                let py = p0.y + (p1.y - p0.y) * f
                let s = min(13.0, max(4.0, w * 0.6))

                let tip = CGPoint(x: px + dx * s, y: py + dy * s)
                let backX = px - dx * s * 0.5
                let backY = py - dy * s * 0.5
                let wingL = CGPoint(x: backX - dy * s * 0.85, y: backY + dx * s * 0.85)
                let wingR = CGPoint(x: backX + dy * s * 0.85, y: backY - dx * s * 0.85)

                var chevron = Path()
                chevron.move(to: wingL)
                chevron.addLine(to: tip)
                chevron.addLine(to: wingR)
                ctx.stroke(chevron, with: .linearGradient(
                    Gradient(colors: [Color.white.opacity(op),
                                      Theme.accent.opacity(op * 0.85)]),
                    startPoint: tip,
                    endPoint: CGPoint(x: backX, y: backY)),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            }
            pos += 46
        }
    }

    private func drawDestination(_ frame: GuidanceFrame,
                                 in ctx: inout GraphicsContext,
                                 size: CGSize) {
        // The marker fades in just behind the ribbon head.
        let reveal = min(1, frame.reveal * 1.6)
        switch frame.destination {
        case .hidden:
            break

        case .onScreen(let pt):
            // Two expanding rings offset by half a cycle.
            let phases = [frame.pulse, (frame.pulse + 0.5).truncatingRemainder(dividingBy: 1)]
            for phase in phases {
                let r = 12 + CGFloat(phase) * 20
                let rect = CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)
                ctx.stroke(Path(ellipseIn: rect),
                           with: .color(Theme.accent.opacity((1 - phase) * 0.6 * reveal)),
                           lineWidth: 2)
            }
            let base = CGRect(x: pt.x - 12, y: pt.y - 12, width: 24, height: 24)
            ctx.fill(Path(ellipseIn: base), with: .color(Theme.accent.opacity(0.30 * reveal)))
            ctx.stroke(Path(ellipseIn: base),
                       with: .color(Theme.accent.opacity(0.95 * reveal)), lineWidth: 2)
            let pin = ctx.resolve(
                Text("\(Image(systemName: "mappin"))")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.white.opacity(reveal)))
            ctx.draw(pin, at: pt)

        case .offScreen(let isLeft, let distance):
            let cx: CGFloat = isLeft ? 36 : size.width - 36
            let cy = size.height * 0.35
            let r: CGFloat = 27
            let rect = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
            ctx.fill(Path(ellipseIn: rect), with: .color(Color.black.opacity(0.45 * reveal)))
            ctx.stroke(Path(ellipseIn: rect),
                       with: .color(Color.white.opacity(0.30 * reveal)), lineWidth: 1)
            let chevron = ctx.resolve(
                Text("\(Image(systemName: isLeft ? "chevron.left" : "chevron.right"))")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.accent.opacity(reveal)))
            ctx.draw(chevron, at: CGPoint(x: cx, y: cy - 7))
            let label = ctx.resolve(
                Text(Format.distance(distance))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.9 * reveal)))
            ctx.draw(label, at: CGPoint(x: cx, y: cy + 9))
        }
    }
}
