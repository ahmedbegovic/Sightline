import SwiftUI
import UIKit

/// Severity of a HUD pill. Only the glyph and an optional rim carry it — the text stays on the primary rung.
enum HUDPillTone: Equatable {
    case neutral, info, warning, danger, positive

    var glyph: Color {
        switch self {
        case .neutral: return Theme.textSecondary
        case .info: return Theme.accent
        case .warning: return Theme.warning
        case .danger: return Theme.danger
        case .positive: return Theme.positive
        }
    }

    var rim: Color? {
        self == .neutral ? nil : glyph.opacity(0.34)
    }
}

extension View {
    /// The one HUD capsule recipe. Every pill-shaped HUD surface goes through this so the geometry, rim and
    /// elevation cannot drift apart; callers own only their own inner padding.
    func hudPillChrome(tone: HUDPillTone = .neutral, minHeight: CGFloat = 34) -> some View {
        frame(minHeight: minHeight)
            .glassCapsule(elevation: .low)
            .overlay {
                if let rim = tone.rim {
                    Capsule(style: .continuous).strokeBorder(rim, lineWidth: 1)
                }
            }
            .compositingGroup()
    }
}

/// The one capsule every transient HUD message uses. Identity is meant to survive a content swap, so the
/// glyph and label cross-fade in place instead of re-inserting the pill.
struct HUDPill: View {
    let tone: HUDPillTone
    let text: String
    var symbol: String?
    /// Supplies its own leading view (a SpinnerRing) when there is no symbol.
    var leading: AnyView?

    init(tone: HUDPillTone, text: String, symbol: String? = nil, leading: AnyView? = nil) {
        self.tone = tone
        self.text = text
        self.symbol = symbol
        self.leading = leading
    }

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            leadingView
            Text(text)
                .font(Theme.Typography.hudLabel)
                .foregroundStyle(Theme.textPrimary)
                .contentTransition(.opacity)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .hudPillChrome(tone: tone)
    }

    @ViewBuilder
    private var leadingView: some View {
        if let leading {
            leading
        } else if let symbol {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tone.glyph)
                .contentTransition(.symbolEffect(.replace))
        }
    }
}

// MARK: - Status pill

/// The top HUD may only ever show one status at a time; without a priority it stacked three.
struct HUDStatusPill: View {
    /// PoseFlags, not PoseManager: observing the manager would re-body this glass subtree on every 60 Hz pose tick.
    @ObservedObject var flags: PoseFlags
    @ObservedObject var scene: SceneBackendCoordinator

    private enum Status: Equatable { case preciseOff, localizing(String), heading }

    private var status: Status? {
        if !flags.isSimulated && flags.preciseLocationOff { return .preciseOff }
        if scene.backend.isGeoAR && scene.phase != .localized {
            return .localizing(scene.phase == .localizing
                ? "Pinpointing your position — pan slowly across buildings"
                : "Starting AR — point your phone at the street")
        }
        if !flags.isSimulated && flags.headingDegraded { return .heading }
        return nil
    }

    var body: some View {
        Group {
            switch status {
            case .preciseOff:
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    HUDPill(tone: .warning,
                            text: "Turn on Precise Location for accurate AR",
                            symbol: "location.slash")
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .move(edge: .top)))

            case .localizing(let message):
                HUDPill(tone: .info, text: message, symbol: "dot.viewfinder")
                    .transition(.opacity.combined(with: .move(edge: .top)))

            case .heading:
                HUDPill(tone: .warning,
                        text: "Compass calibrating — step outside or wave phone in a figure-8",
                        symbol: "location.north.line")
                    .transition(.opacity.combined(with: .move(edge: .top)))

            case nil:
                EmptyView()
            }
        }
        .animation(Theme.Motion.standard, value: status)
    }
}
