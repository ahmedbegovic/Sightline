import Foundation

/// Shared angle math — the compass path, the AR path and the projector all used to carry private copies of this.
enum Angles {

    static func normalized(_ degrees: Double) -> Double {
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value < 0 { value += 360 }
        return value
    }

    /// Shortest signed arc `to - from` in -180...180; negative means `to` is to the left.
    static func shortestDelta(from: Double, to: Double) -> Double {
        var delta = (to - from).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return delta
    }

    /// Exponential moving average over the shortest arc (handles the 359 -> 1 wrap).
    static func ema(current: Double, target: Double, alpha: Double) -> Double {
        normalized(current + alpha * shortestDelta(from: current, to: target))
    }

    // MARK: - Adaptive smoothing

    /// Below this a frame-to-frame change is sensor noise; 1 degree of heading is ~6 pt of bubble swim.
    static let noiseDegrees: Double = 0.4
    /// At or above this the user is deliberately turning and any smoothing is felt as lag.
    static let motionDegrees: Double = 2.0
    static let minAlpha: Double = 0.08
    static let maxAlpha: Double = 0.5

    /// Smooth hard when the signal is noise, barely at all when it is motion — a fixed alpha has to pick one.
    static func adaptiveAlpha(forDelta delta: Double) -> Double {
        let magnitude = abs(delta)
        if magnitude <= noiseDegrees { return minAlpha }
        if magnitude >= motionDegrees { return maxAlpha }
        let t = (magnitude - noiseDegrees) / (motionDegrees - noiseDegrees)
        return minAlpha + (maxAlpha - minAlpha) * t
    }
}

#if DEBUG
extension Angles {
    /// One-shot assertions run from AppState.start() in DEBUG; this project has no test target.
    static func selfTest() {
        assert(normalized(-10) == 350)
        assert(shortestDelta(from: 350, to: 10) == 20)
        assert(shortestDelta(from: 10, to: 350) == -20)
        assert(abs(ema(current: 350, target: 10, alpha: 0.5) - 0) < 0.0001)
        assert(adaptiveAlpha(forDelta: 0.1) == minAlpha)
        assert(adaptiveAlpha(forDelta: -5) == maxAlpha)
        assert(adaptiveAlpha(forDelta: 1.2) > minAlpha && adaptiveAlpha(forDelta: 1.2) < maxAlpha)
    }
}
#endif
