import SwiftUI
import CoreLocation
import UIKit

enum Theme {
    // Brand — accent mirrors Assets.xcassets/AccentColor; changing one requires changing both.
    static let accent = Color(red: 0.35, green: 0.78, blue: 1.00)
    static let accentSecondary = Color(red: 0.62, green: 0.47, blue: 1.00)

    // Semantic. Raw system colors read as OS chrome over a camera feed; these are tuned for glass.
    static let positive = Color(red: 0.36, green: 0.86, blue: 0.60)
    static let warning  = Color(red: 1.00, green: 0.72, blue: 0.32)
    static let danger   = Color(red: 1.00, green: 0.44, blue: 0.44)
    static let landmark = Color(red: 1.00, green: 0.82, blue: 0.42)
    static let star     = Color(red: 1.00, green: 0.78, blue: 0.24)

    /// The assistant sheet is the app's only opaque surface — everything else floats over the camera.
    static let sheetBackground = Color(red: 0.07, green: 0.08, blue: 0.11)

    // Text ladder — exactly four rungs. Nothing outside this file may invent a white opacity for text.
    static let textPrimary    = Color.white.opacity(0.95)
    static let textSecondary  = Color.white.opacity(0.72)
    static let textTertiary   = Color.white.opacity(0.50)
    static let textQuaternary = Color.white.opacity(0.30)

    // Fills
    static let fillSubtle  = Color.white.opacity(0.07)
    static let hairline    = Color.white.opacity(0.10)
    /// Darkens bubble glass so a chip stays legible against a bright sky.
    static let bubbleFloor = Color.black.opacity(0.16)

    static var accentGradient: LinearGradient {
        LinearGradient(colors: [accent, accentSecondary],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Subtle 1pt stroke used on glass surfaces.
    static var glassStroke: LinearGradient {
        LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.08)],
                       startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - Metrics

extension Theme {
    enum Radius {
        static let chip: CGFloat = 14
        static let pill: CGFloat = 18
        static let card: CGFloat = 22
        static let sheet: CGFloat = 28
    }

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
    }

    /// Shadow vocabulary. Applied to the backing shape, never the composite — see GlassKit.
    enum Elevation {
        case none, low, medium, high

        var color: Color {
            switch self {
            case .none: return .clear
            case .low: return .black.opacity(0.26)
            case .medium: return .black.opacity(0.32)
            case .high: return .black.opacity(0.42)
            }
        }

        var radius: CGFloat {
            switch self {
            case .none: return 0
            case .low: return 8
            case .medium: return 14
            case .high: return 22
            }
        }

        var y: CGFloat {
            switch self {
            case .none: return 0
            case .low: return 3
            case .medium: return 6
            case .high: return 10
            }
        }
    }

    /// Every animation in the app comes from here. Nothing exceeds ~0.5 s.
    enum Motion {
        static let snap      = Animation.spring(response: 0.26, dampingFraction: 0.80)
        static let standard  = Animation.spring(response: 0.38, dampingFraction: 0.84)
        static let gentle    = Animation.spring(response: 0.46, dampingFraction: 0.86)
        static let fade      = Animation.easeOut(duration: 0.18)
        static let quickFade = Animation.easeOut(duration: 0.12)

        /// The one Reduce Motion gate. `nil` means the value change applies with no animation at all —
        /// every animated surface routes through here so the setting is honored uniformly.
        static func gated(_ animation: Animation?, reduceMotion: Bool) -> Animation? {
            reduceMotion ? nil : animation
        }

        /// Same gate for surfaces that must still cross-fade under Reduce Motion (a hard cut reads as a glitch).
        static func gatedFade(_ animation: Animation, reduceMotion: Bool) -> Animation {
            reduceMotion ? fade : animation
        }
    }

    /// The app's full type ladder. Nothing outside this enum may name a font.
    enum Typography {
        static let hudLabel   = Font.caption.weight(.medium)
        static let hudTitle   = Font.subheadline.weight(.semibold)
        /// All-caps or bold chip labels: mini-map chips, the End button, the route pill.
        static let chipLabel  = Font.caption.weight(.bold)
        static let cardTitle  = Font.headline
        static let cardBody   = Font.footnote
        /// Values that have to out-weigh the body next to them: a rating number, a bubble name.
        static let cardBodyStrong = Font.footnote.weight(.semibold)
        /// Editable and conversational text — search field, assistant messages.
        static let body       = Font.callout
        static let button     = Font.subheadline.weight(.bold)
        static let buttonQuiet = Font.subheadline.weight(.semibold)
        static let meta       = Font.caption
        static let micro      = Font.caption2
    }
}

enum Format {
    static func distance(_ meters: CLLocationDistance) -> String {
        if meters < 1000 { return "\(Int(meters.rounded())) m" }
        let km = meters / 1000
        return km < 10 ? String(format: "%.1f km", km) : "\(Int(km.rounded())) km"
    }

    /// Bubble chips only: 1 m precision on a fix with a 15 m accuracy budget is fiction, and every change re-lays out the chip.
    static func bubbleDistance(_ meters: CLLocationDistance) -> String {
        guard meters < 1000 else { return distance(meters) }
        return "\(Int((meters / 5).rounded()) * 5) m"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }
}

/// Long-lived, prepared generators. A fresh generator per call pays the Taptic cold start on the calling thread.
@MainActor
enum Haptics {
    private static let impactLight = UIImpactFeedbackGenerator(style: .light)
    private static let impactMedium = UIImpactFeedbackGenerator(style: .medium)
    private static let notification = UINotificationFeedbackGenerator()

    static func warmUp() {
        impactLight.prepare()
        impactMedium.prepare()
        notification.prepare()
    }

    static func light() { impactLight.impactOccurred(); impactLight.prepare() }
    static func tap() { impactMedium.impactOccurred(); impactMedium.prepare() }
    static func success() { notification.notificationOccurred(.success); notification.prepare() }
    static func warning() { notification.notificationOccurred(.warning); notification.prepare() }
}
