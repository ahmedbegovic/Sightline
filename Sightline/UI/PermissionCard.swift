import SwiftUI

/// One card for every "we need this permission" overlay — camera, location, and anything added later.
struct PermissionCard: View {
    let symbol: String
    let title: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: Theme.Space.s + 2) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Theme.accent)
            Text(title)
                .font(Theme.Typography.cardTitle)
                .foregroundStyle(Theme.textPrimary)
            if let message {
                Text(message)
                    .font(Theme.Typography.cardBody)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, Theme.Space.xxl)
                        .frame(height: 44)
                        .background(Theme.accentGradient, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, Theme.Space.xs)
            }
        }
        .padding(Theme.Space.xxl)
        .glassCard(cornerRadius: Theme.Radius.sheet, elevation: .high)
        .padding(.horizontal, 40)
    }
}
