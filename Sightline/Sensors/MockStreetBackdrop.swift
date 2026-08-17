import SwiftUI

/// Simulator stand-in for the camera feed: pans with heading (buildings repeat per 360°), shifts with pitch, redraws only on pose change.
struct MockStreetBackdrop: View {

    @ObservedObject private var poseManager: PoseManager

    init(poseManager: PoseManager) {
        self.poseManager = poseManager
    }

    var body: some View {
        let heading = poseManager.pose.headingDegrees
        let pitch = poseManager.pose.pitchDegrees
        Canvas(opaque: true, rendersAsynchronously: false) { context, size in
            DuskCityPainter.draw(in: &context, size: size,
                                 headingDegrees: heading, pitchDegrees: pitch)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

// MARK: - Painter

/// Layout is precomputed once; per-frame work is just rectangle fills, cheap at 30 Hz.
fileprivate enum DuskCityPainter {

    // MARK: World model (normalized units)

    struct LitWindow {
        var x: Double           // fraction of the layer period
        var width: Double       // fraction of the layer period
        var yFromBase: Double   // fraction of screen height above the building base
        var height: Double      // fraction of screen height
        var warmth: Double      // 0 = cool fluorescent, 1 = deep amber
        var alpha: Double
    }

    struct Building {
        var x: Double           // fraction of the layer period
        var width: Double       // fraction of the layer period
        var height: Double      // fraction of screen height above the base line
        var shade: Double       // 0...1 brightness jitter
        var hasSpire: Bool
        var windows: [LitWindow]
    }

    struct Star {
        var x: Double             // fraction of the layer period
        var yAboveHorizon: Double // fraction of screen height
        var radius: Double        // points
        var alpha: Double
    }

    // MARK: Tuning

    /// Near-layer period: 3 screen widths scroll past per full 360° turn.
    private static let tileScreenMultiple: CGFloat = 3
    /// Far layer scrolls at 0.35x the near; each layer's period equals its travel per revolution so both wrap seamlessly at 360°.
    private static let farParallax: CGFloat = 0.35
    // Kept in lockstep with ARProjector.horizonY so ribbons and leader lines land on the painted street.
    private static let baseHorizonFraction: CGFloat = 0.5
    /// Vertical shift per degree of pitch, as a fraction of screen height.
    private static let pitchShiftPerDegree: CGFloat = 1.0 / CGFloat(ARProjector.verticalFOV)

    // MARK: Cached world (built once from fixed seeds)

    private static let farBuildings: [Building] = makeBuildings(
        seed: 11, count: 14, minHeight: 0.09, maxHeight: 0.26,
        spireChance: 0.22, windowed: false)

    private static let nearBuildings: [Building] = makeBuildings(
        seed: 47, count: 9, minHeight: 0.17, maxHeight: 0.40,
        spireChance: 0.08, windowed: true)

    private static let stars: [Star] = makeStars(seed: 5, count: 46)

    // MARK: Palette

    private static let skyGradient = Gradient(stops: [
        .init(color: Color(red: 0.020, green: 0.022, blue: 0.070), location: 0.00), // near-black indigo
        .init(color: Color(red: 0.055, green: 0.050, blue: 0.150), location: 0.42),
        .init(color: Color(red: 0.120, green: 0.090, blue: 0.230), location: 0.74), // deep blue-violet
        .init(color: Color(red: 0.240, green: 0.140, blue: 0.230), location: 0.90),
        .init(color: Color(red: 0.400, green: 0.240, blue: 0.170), location: 1.00), // faint warm amber band
    ])

    private static let groundGradient = Gradient(stops: [
        .init(color: Color(red: 0.100, green: 0.090, blue: 0.125), location: 0.00),
        .init(color: Color(red: 0.048, green: 0.046, blue: 0.075), location: 0.30),
        .init(color: Color(red: 0.016, green: 0.016, blue: 0.034), location: 1.00),
    ])

    private static let hazeGradient = Gradient(stops: [
        .init(color: .clear, location: 0),
        .init(color: Color(red: 0.55, green: 0.34, blue: 0.20).opacity(0.14), location: 1),
    ])

    private static let streetGlowGradient = Gradient(colors: [
        Color(red: 0.55, green: 0.42, blue: 0.25).opacity(0.20),
        Color(red: 0.55, green: 0.42, blue: 0.25).opacity(0.0),
    ])

    private static let vignetteGradient = Gradient(stops: [
        .init(color: .clear, location: 0.00),
        .init(color: .clear, location: 0.55),
        .init(color: Color.black.opacity(0.40), location: 1.00),
    ])

    private static let farBuildingColor = Color(red: 0.105, green: 0.110, blue: 0.185)
    private static let nearBuildingColor = Color(red: 0.040, green: 0.045, blue: 0.090)

    // MARK: Drawing

    static func draw(in context: inout GraphicsContext, size: CGSize,
                     headingDegrees: Double, pitchDegrees: Double) {
        let w = size.width
        let h = size.height
        guard w > 1, h > 1 else { return }

        // Tilting the camera up moves the world (and the horizon) down.
        let fraction = min(max(baseHorizonFraction + CGFloat(pitchDegrees) * pitchShiftPerDegree, 0.08), 0.92)
        let horizonY = (h * fraction).rounded()
        let nearPeriod = w * tileScreenMultiple
        let farPeriod = nearPeriod * farParallax
        let cycle = CGFloat(headingDegrees / 360.0)
        let nearOffset = wrapped(cycle * nearPeriod, period: nearPeriod)
        let farOffset = wrapped(cycle * farPeriod, period: farPeriod)

        // 1. Sky
        context.fill(Path(CGRect(x: 0, y: 0, width: w, height: max(1, horizonY))),
                     with: .linearGradient(skyGradient,
                                           startPoint: .zero,
                                           endPoint: CGPoint(x: 0, y: horizonY)))

        // Stars (drawn before the skylines so buildings occlude them)
        for star in stars {
            let y = horizonY - CGFloat(star.yAboveHorizon) * h
            guard y > -2, y < horizonY - h * 0.05 else { continue }
            let r = CGFloat(star.radius)
            let base = CGFloat(star.x) * farPeriod - farOffset
            for t in -1...1 {
                let x = base + CGFloat(t) * farPeriod
                guard x > -2, x < w + 2 else { continue }
                context.fill(Path(ellipseIn: CGRect(x: x, y: y - r * 0.5, width: r, height: r)),
                             with: .color(.white.opacity(star.alpha)))
            }
        }

        // 2. Far skyline silhouette (parallax 0.35)
        for building in farBuildings {
            let bw = CGFloat(building.width) * farPeriod
            let bh = CGFloat(building.height) * h
            let base = CGFloat(building.x) * farPeriod - farOffset
            let color = farBuildingColor.opacity(0.88 + 0.12 * building.shade)
            for t in -1...1 {
                let x = base + CGFloat(t) * farPeriod
                guard x + bw > 0, x < w else { continue }
                context.fill(Path(CGRect(x: x, y: horizonY - bh, width: bw, height: bh)),
                             with: .color(color))
                if building.hasSpire {
                    let sw = max(1.2, bw * 0.05)
                    let sh = bh * 0.16
                    context.fill(Path(CGRect(x: x + (bw - sw) * 0.5,
                                             y: horizonY - bh - sh,
                                             width: sw, height: sh)),
                                 with: .color(color))
                }
            }
        }

        // Atmospheric haze seating the far skyline into the horizon
        let hazeHeight = h * 0.09
        context.fill(Path(CGRect(x: 0, y: horizonY - hazeHeight, width: w, height: hazeHeight)),
                     with: .linearGradient(hazeGradient,
                                           startPoint: CGPoint(x: 0, y: horizonY - hazeHeight),
                                           endPoint: CGPoint(x: 0, y: horizonY)))

        // 4a. Street: dark asphalt (drawn before the near layer so buildings sit on it)
        let groundRect = CGRect(x: 0, y: horizonY, width: w, height: max(1, h - horizonY))
        context.fill(Path(groundRect),
                     with: .linearGradient(groundGradient,
                                           startPoint: CGPoint(x: 0, y: horizonY),
                                           endPoint: CGPoint(x: 0, y: h)))

        // 3. Near buildings (parallax 1.0) with sparse warm lit windows
        let nearBaseY = horizonY + h * 0.022
        for building in nearBuildings {
            let bw = CGFloat(building.width) * nearPeriod
            let bh = CGFloat(building.height) * h
            let base = CGFloat(building.x) * nearPeriod - nearOffset
            let color = nearBuildingColor.opacity(0.94 + 0.06 * building.shade)
            for t in -1...1 {
                let x = base + CGFloat(t) * nearPeriod
                guard x + bw > 0, x < w else { continue }
                context.fill(Path(CGRect(x: x, y: nearBaseY - bh, width: bw, height: bh)),
                             with: .color(color))
                // Hairline rooftop edge so the layer separates from the sky
                context.fill(Path(CGRect(x: x, y: nearBaseY - bh, width: bw, height: 1)),
                             with: .color(.white.opacity(0.045)))
                let dx = x - CGFloat(building.x) * nearPeriod // this instance's shift
                for window in building.windows {
                    let wx = CGFloat(window.x) * nearPeriod + dx
                    let ww = max(1.5, CGFloat(window.width) * nearPeriod)
                    guard wx + ww > 0, wx < w else { continue }
                    let wh = max(2, CGFloat(window.height) * h)
                    let wy = nearBaseY - CGFloat(window.yFromBase) * h - wh
                    context.fill(Path(CGRect(x: wx, y: wy, width: ww, height: wh)),
                                 with: .color(windowColor(warmth: window.warmth, alpha: window.alpha)))
                }
            }
        }

        // 4b. Street details: center vanishing-point glow + faint sidewalk line
        let glowCenter = CGPoint(x: w * 0.5, y: horizonY + h * 0.012)
        context.fill(Path(groundRect),
                     with: .radialGradient(streetGlowGradient,
                                           center: glowCenter,
                                           startRadius: 0,
                                           endRadius: w * 0.55))

        var sidewalk = Path()
        let sidewalkY = (horizonY + h * 0.055).rounded() + 0.5
        sidewalk.move(to: CGPoint(x: 0, y: sidewalkY))
        sidewalk.addLine(to: CGPoint(x: w, y: sidewalkY))
        context.stroke(sidewalk, with: .color(.white.opacity(0.05)), lineWidth: 1)

        // 5. Vignette
        context.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .radialGradient(vignetteGradient,
                                           center: CGPoint(x: w * 0.5, y: h * 0.46),
                                           startRadius: 0,
                                           endRadius: sqrt(w * w + h * h) * 0.62))
    }

    private static func windowColor(warmth: Double, alpha: Double) -> Color {
        if warmth < 0.18 {
            return Color(red: 0.72, green: 0.82, blue: 0.95).opacity(alpha * 0.8) // cool fluorescent
        }
        return Color(red: 1.0, green: 0.72 + 0.10 * (1 - warmth), blue: 0.40).opacity(alpha)
    }

    private static func wrapped(_ value: CGFloat, period: CGFloat) -> CGFloat {
        let remainder = value.truncatingRemainder(dividingBy: period)
        return remainder < 0 ? remainder + period : remainder
    }

    // MARK: World generation (runs once)

    private static func makeBuildings(seed: Int, count: Int,
                                      minHeight: Double, maxHeight: Double,
                                      spireChance: Double, windowed: Bool) -> [Building] {
        var buildings: [Building] = []
        buildings.reserveCapacity(count)
        let slot = 1.0 / Double(count)
        for column in 0..<count {
            let width = slot * (0.60 + 0.50 * noise(seed, column, 0))
            let x = Double(column) * slot + slot * 0.35 * (noise(seed, column, 1) - 0.5)
            let height = minHeight + (maxHeight - minHeight) * ease(noise(seed, column, 2))
            let shade = noise(seed, column, 3)
            let hasSpire = noise(seed, column, 4) < spireChance
            let windows = windowed
                ? makeWindows(seed: seed, column: column,
                              buildingX: x, buildingWidth: width, buildingHeight: height)
                : []
            buildings.append(Building(x: x, width: width, height: height,
                                      shade: shade, hasSpire: hasSpire, windows: windows))
        }
        return buildings
    }

    private static func makeWindows(seed: Int, column: Int, buildingX: Double,
                                    buildingWidth: Double, buildingHeight: Double) -> [LitWindow] {
        var result: [LitWindow] = []
        let cols = 2 + Int(noise(seed, column, 5) * 2.999) // 2...4
        let insetX = buildingWidth * 0.16
        let colStep = (buildingWidth - insetX * 2) / Double(cols)
        let windowWidth = min(colStep * 0.45, 0.0038)
        let rowStep = 0.033
        let firstRowY = 0.018
        let topLimit = buildingHeight - 0.028
        let rows = max(1, min(12, Int((topLimit - firstRowY) / rowStep)))
        for row in 0..<rows {
            for col in 0..<cols {
                let cell = row * 16 + col
                guard noise(seed, column, 100 + cell) < 0.17 else { continue } // sparse
                let wx = buildingX + insetX + Double(col) * colStep + (colStep - windowWidth) * 0.5
                let wy = firstRowY + Double(row) * rowStep + 0.005 * noise(seed, column, 3000 + cell)
                result.append(LitWindow(x: wx,
                                        width: windowWidth,
                                        yFromBase: wy,
                                        height: 0.0052,
                                        warmth: noise(seed, column, 1000 + cell),
                                        alpha: 0.30 + 0.50 * noise(seed, column, 2000 + cell)))
            }
        }
        return result
    }

    private static func makeStars(seed: Int, count: Int) -> [Star] {
        (0..<count).map { index in
            let brightness = noise(seed, index, 3)
            return Star(x: noise(seed, index, 0),
                        yAboveHorizon: 0.16 + 0.78 * noise(seed, index, 1),
                        radius: 0.6 + 0.9 * noise(seed, index, 2),
                        alpha: 0.18 + 0.55 * brightness * brightness)
        }
    }

    /// Smoothstep bias so building heights cluster pleasantly around the middle.
    private static func ease(_ t: Double) -> Double { t * t * (3 - 2 * t) }

    /// Deterministic SplitMix64-style hash in [0, 1) — never Double.random, so the world is stable across frames and launches.
    private static func noise(_ seed: Int, _ index: Int, _ salt: Int) -> Double {
        var h = UInt64(bitPattern: Int64(seed)) &+ 0x9E3779B97F4A7C15
        h = (h ^ (h >> 30)) &* 0xBF58476D1CE4E5B9
        h &+= UInt64(bitPattern: Int64(index)) &* 0x94D049BB133111EB
        h = (h ^ (h >> 27)) &* 0x9E3779B97F4A7C15
        h &+= UInt64(bitPattern: Int64(salt)) &* 0xBF58476D1CE4E5B9
        h = (h ^ (h >> 31)) &* 0x94D049BB133111EB
        h ^= h >> 29
        return Double(h & 0x000F_FFFF) / Double(0x0010_0000)
    }
}
