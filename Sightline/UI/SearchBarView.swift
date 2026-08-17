import SwiftUI

/// Glass search field for the top HUD: "Find tacos, coffee, ATMs…".
struct SearchBarView: View {
    @Binding private var text: String
    private let isBusy: Bool
    private let onSubmit: () -> Void
    private let onClear: () -> Void

    @FocusState private var isFocused: Bool

    init(text: Binding<String>,
         isBusy: Bool,
         onSubmit: @escaping () -> Void,
         onClear: @escaping () -> Void) {
        _text = text
        self.isBusy = isBusy
        self.onSubmit = onSubmit
        self.onClear = onClear
    }

    /// One equatable key for the three things that change this field's look.
    private struct VisualState: Equatable {
        let focused: Bool
        let busy: Bool
        let empty: Bool
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isFocused ? Theme.accent : Theme.textTertiary)
                .scaleEffect(isFocused ? 1.06 : 1.0)

            TextField("",
                      text: $text,
                      prompt: Text("Find tacos, coffee, ATMs…")
                          .foregroundStyle(Theme.textTertiary))
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.textPrimary)
                .tint(Theme.accent)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($isFocused)
                .onSubmit {
                    isFocused = false
                    onSubmit()
                }

            if isBusy {
                SpinnerRing(size: 16, lineWidth: 1.8)
            } else if !text.isEmpty {
                Button {
                    isFocused = false
                    onClear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 32, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .frame(height: 48)
        .glassCapsule(elevation: .low)
        // Stroke width, not opacity: no blur and no shadow here, both would force an offscreen pass every focused frame.
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Theme.accentGradient, lineWidth: isFocused ? 1.6 : 0)
        }
        .background {
            if isFocused {
                Capsule(style: .continuous).fill(Theme.accent.opacity(0.06))
            }
        }
        .animation(Theme.Motion.standard,
                   value: VisualState(focused: isFocused, busy: isBusy, empty: text.isEmpty))
    }
}
