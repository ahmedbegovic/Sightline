import SwiftUI
import UIKit
import FoundationModels

/// First-use costs that would otherwise land on the first Scan or Search press, moved to launch.
/// Exists because the very first Scan press visibly stuttered in a 2026-08-16 field test; warming these paths removed the hitch.
@MainActor
enum Prewarm {
    static func run() {
        Haptics.warmUp()
        warmServices()
        warmSymbols()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            warmKeyboard()
        }
    }

    private static func warmServices() {
        // URLSession + NSCache setup, off-main, off the press path.
        Task.detached(priority: .utility) {
            _ = GooglePlacesService.shared
        }
        // Loads the on-device model's assets so the first scan doesn't pay for it.
        if SystemLanguageModel.default.availability == .available {
            LanguageModelSession(instructions: SceneIdentifier.instructions).prewarm()
        }
    }

    /// Symbol images are cached per exact (name, pointSize, weight); warming a size the app never draws
    /// warms nothing. Every entry below is a size and weight that some view actually renders.
    private static let chromeSymbols = [
        "binoculars", "location.slash",
        "wifi.exclamationmark", "exclamationmark.triangle", "exclamationmark.triangle.fill",
        "magnifyingglass", "xmark.circle.fill", "xmark", "hand.draw",
        "location.north.line", "dot.viewfinder", "sparkles", "star.fill", "star",
        "mappin", "mappin.and.ellipse", "phone.fill", "safari.fill", "location.fill",
        "figure.walk", "map", "checkmark.circle.fill", "chevron.left", "chevron.right",
        "arrow.up", "arrow.turn.up.left", "arrow.turn.up.right", "camera.fill",
        "arrow.up.left.and.arrow.down.right",
    ]

    /// 8–16 covers every HUD glyph; the three large ones are the arrival check, the mini-map badge and the detail row.
    private static let chromeSizes: [CGFloat] = [8, 9, 10, 11, 12, 13, 14, 15, 16, 44]

    /// CategoryBadge draws its glyph at size * 0.43 — these are the badge sizes the app instantiates (26/30/34/40/44),
    /// plus the 13 pt bare glyph used by the edge indicators.
    private static let badgeGlyphSizes: [CGFloat] = [11.18, 12.9, 13, 14.62, 17.2, 18.92]

    private static func warmSymbols() {
        // First render of a (symbol, size, weight) pair rasterizes on the main thread; the scan path lands ~20 new glyphs at once.
        let categoryNames = PlaceCategory.allCases.map(\.symbolName)
        let chromeNames = chromeSymbols
        let chromeSizes = Self.chromeSizes
        let badgeSizes = badgeGlyphSizes
        Task.detached(priority: .utility) {
            for name in categoryNames {
                for size in badgeSizes {
                    _ = image(name, size, .semibold)
                }
            }
            for name in chromeNames {
                for size in chromeSizes {
                    _ = image(name, size, .semibold)
                    _ = image(name, size, .bold)
                }
            }
        }
    }

    private nonisolated static func image(_ name: String, _ size: CGFloat,
                                          _ weight: UIImage.SymbolWeight) -> UIImage? {
        UIImage(systemName: name,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: weight))
    }

    /// Relocates first-responder cost to launch; it does not remove it. A hidden field is refused first-responder
    /// status outright, so the field stays visible-but-invisible: offscreen, 1x1, alpha above UIKit's 0.01 floor.
    private static func warmKeyboard() {
        guard UIApplication.shared.applicationState == .active,
              let window = UIApplication.shared.connectedScenes
                  .compactMap({ $0 as? UIWindowScene }).first?
                  .windows.first(where: \.isKeyWindow) else { return }
        // The user may already be typing by now; stealing focus would dismiss their keyboard.
        guard !hasFirstResponder(window) else { return }

        let field = UITextField(frame: CGRect(x: -200, y: -200, width: 1, height: 1))
        field.alpha = 0.02
        field.autocorrectionType = .no
        window.addSubview(field)
        // Resign in the same runloop turn: becoming first responder is what loads the keyboard stack, while the
        // presentation itself is committed at the end of the turn — cancelling it avoids a visible keyboard flash.
        field.becomeFirstResponder()
        field.resignFirstResponder()
        field.removeFromSuperview()
    }

    private static func hasFirstResponder(_ view: UIView) -> Bool {
        if view.isFirstResponder { return true }
        return view.subviews.contains(where: hasFirstResponder)
    }
}
