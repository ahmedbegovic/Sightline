import SwiftUI
import CoreLocation
import UIKit

/// Bottom glass card for a selected place; RootView owns presentation and transitions, this only lays out content.
struct PlaceDetailCard: View {

    private let place: Place
    private let distance: CLLocationDistance?
    private let onNavigate: () -> Void
    private let onAsk: () -> Void
    private let onClose: () -> Void

    @State private var contentHeight: CGFloat = 0
    @State private var dragY: CGFloat = 0
    @State private var appeared = false

    init(place: Place, distance: CLLocationDistance?,
         onNavigate: @escaping () -> Void,
         onAsk: @escaping () -> Void,
         onClose: @escaping () -> Void) {
        self.place = place
        self.distance = distance
        self.onNavigate = onNavigate
        self.onAsk = onAsk
        self.onClose = onClose
    }

    /// Hard clamp on the scrollable region; the action row lives outside it so Navigate is always reachable.
    private var contentCap: CGFloat { place.photoResource == nil ? 260 : 430 }
    private var scrollHeight: CGFloat {
        contentHeight > 0 ? min(contentHeight, contentCap) : contentCap
    }

    var body: some View {
        VStack(spacing: 0) {
            grabber
            ScrollView {
                content
                    .background {
                        GeometryReader { geo in
                            Color.clear.preference(key: CardHeightKey.self, value: geo.size.height)
                        }
                    }
            }
            .scrollIndicators(.hidden)
            .frame(height: scrollHeight)
            actionRow
                .padding(.top, Theme.Space.m)
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: Theme.Radius.sheet, elevation: .high)
        .padding(.horizontal, 14)
        .offset(y: dragY)
        .opacity(1 - min(0.5, dragY / 320))
        // The > 0.5 guard keeps a measurement that differs by rounding from looping back into layout.
        .onPreferenceChange(CardHeightKey.self) { height in
            if abs(height - contentHeight) > 0.5 { contentHeight = height }
        }
        .onAppear { appeared = true }
    }

    // MARK: - Grabber (drag target)

    /// The gesture lives here, not on the card: on the card it fights the ScrollView.
    private var grabber: some View {
        Capsule()
            .fill(Theme.textQuaternary)
            .frame(width: 36, height: 5)
            .padding(.top, 6)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        // Rubber-band upward; downward tracks the finger.
                        dragY = value.translation.height > 0
                            ? value.translation.height
                            : value.translation.height / 4
                    }
                    .onEnded { value in
                        if value.translation.height > 90
                            || value.predictedEndTranslation.height > 180 {
                            dragY = 0
                            onClose()
                        } else {
                            withAnimation(Theme.Motion.gentle) { dragY = 0 }
                        }
                    }
            )
            .accessibilityHidden(true)
    }

    // MARK: - Scrollable content

    private var content: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Group {
                if let resource = place.photoResource {
                    PlacePhotoHeader(resource: resource)
                }
                header
            }
            .modifier(StaggerIn(appeared: appeared, index: 0))

            Group {
                ratingRow
                // Second-stage fields (photo, hours, address, reviews, contact) are still in flight.
                if place.details == nil {
                    detailsPendingRow
                }
                if let address = place.address {
                    addressRow(address)
                }
            }
            .modifier(StaggerIn(appeared: appeared, index: 1))

            Group {
                if !place.reviews.isEmpty {
                    reviewList
                }
                Text("Data from Google")
                    .font(Theme.Typography.micro)
                    .foregroundStyle(Theme.textQuaternary)
            }
            .modifier(StaggerIn(appeared: appeared, index: 2))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            CategoryBadge(category: place.category, size: 44, silhouette: .rounded)

            VStack(alignment: .leading, spacing: 3) {
                Text(place.name)
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                Text(subtitle)
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Theme.Space.s)

            Button {
                Haptics.light()
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(Theme.Typography.chipLabel)
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 32, height: 32)
                    .glassCircle(elevation: .low)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
    }

    private var subtitle: String {
        var parts = [place.category.displayName]
        if !place.priceLabel.isEmpty { parts.append(place.priceLabel) }
        if let distance { parts.append(Format.distance(distance)) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Rating

    private var ratingRow: some View {
        HStack(spacing: Theme.Space.xs + 2) {
            if place.rating > 0 {
                starRow(stars: Int(place.rating.rounded()), size: 11)
                Text(String(format: "%.1f", place.rating))
                    .font(Theme.Typography.cardBodyStrong)
                    .foregroundStyle(Theme.textPrimary)
                Text("· \(place.reviewCount) reviews")
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.textTertiary)
            } else {
                Text("No ratings yet")
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.textTertiary)
            }
            if let open = place.isOpenNow {
                Text(open ? "Open now" : "Closed")
                    .font(Theme.Typography.micro.weight(.semibold))
                    .foregroundStyle(open ? Theme.positive : Theme.danger)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background((open ? Theme.positive : Theme.danger).opacity(0.14), in: Capsule())
            }
        }
    }

    private func starRow(stars: Int, size: CGFloat) -> some View {
        HStack(spacing: 1.5) {
            ForEach(0..<5, id: \.self) { index in
                Image(systemName: index < stars ? "star.fill" : "star")
                    .font(.system(size: size))
                    .foregroundStyle(Theme.star)
            }
        }
        .accessibilityHidden(true)
    }

    /// Discovery data renders immediately; this quiet row stands in for the on-demand fields. A failed fetch clears it and the card simply keeps its discovery content.
    private var detailsPendingRow: some View {
        HStack(spacing: Theme.Space.s) {
            SpinnerRing(size: 12, lineWidth: 1.6)
            Text("Loading details…")
                .font(Theme.Typography.meta)
                .foregroundStyle(Theme.textTertiary)
        }
    }

    // MARK: - Address

    private func addressRow(_ address: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "mappin.and.ellipse")
                .font(Theme.Typography.meta)
            Text(address)
                .font(Theme.Typography.meta)
                .lineLimit(1)
        }
        .foregroundStyle(Theme.textSecondary)
    }

    // MARK: - Reviews

    private var reviewList: some View {
        let reviews = Array(place.reviews.prefix(2))
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            ForEach(Array(reviews.enumerated()), id: \.element.id) { index, review in
                if index > 0 {
                    Rectangle()
                        .fill(Theme.hairline)
                        .frame(height: 1)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(review.author)
                            .font(Theme.Typography.micro.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                        starRow(stars: review.stars, size: 9)
                    }
                    Text(review.text)
                        .font(Theme.Typography.meta)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - Actions

    /// Deterministic overflow rule — with a phone and a website there is no room for the "Ask AI" label.
    private var compact: Bool { place.phone != nil && place.url != nil }

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button {
                Haptics.tap()
                onNavigate()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "location.fill")
                    Text("Navigate")
                }
                .font(Theme.Typography.button)
                .foregroundStyle(.white)
                .frame(minWidth: compact ? 140 : 0, maxWidth: .infinity, minHeight: 46)
                .background(Theme.accentGradient, in: Capsule())
            }
            .buttonStyle(.plain)

            Button {
                Haptics.light()
                onAsk()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                    if !compact { Text("Ask AI") }
                }
                .font(Theme.Typography.buttonQuiet)
                .foregroundStyle(.white)
                .frame(width: compact ? 46 : nil, height: 46)
                .padding(.horizontal, compact ? 0 : Theme.Space.l)
                .glassCapsule(elevation: .low)
                .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.55), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Ask AI")

            if let phone = place.phone, let telURL = Self.telURL(for: phone) {
                roundGlassButton(symbol: "phone.fill", label: "Call") {
                    UIApplication.shared.open(telURL)
                }
            }
            if let url = place.url {
                roundGlassButton(symbol: "safari.fill", label: "Open website") {
                    UIApplication.shared.open(url)
                }
            }
        }
    }

    private func roundGlassButton(symbol: String,
                                  label: String,
                                  action: @escaping () -> Void) -> some View {
        Button {
            Haptics.light()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 46, height: 46)
                .glassCircle(elevation: .low)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private static func telURL(for phone: String) -> URL? {
        let digits = phone.filter { $0.isNumber || $0 == "+" }
        guard !digits.isEmpty else { return nil }
        return URL(string: "tel://\(digits)")
    }
}

// MARK: - Content stagger

/// Three groups only; total added latency 0.09 s.
private struct StaggerIn: ViewModifier {
    let appeared: Bool
    let index: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            // Reduce Motion keeps the fade but drops the travel and the stagger.
            .offset(y: appeared || reduceMotion ? 0 : 8)
            .animation(reduceMotion
                        ? Theme.Motion.fade
                        : Theme.Motion.standard.delay(Double(index) * 0.045),
                       value: appeared)
    }
}

/// ScrollView does not size to its content, so the height clamp has to measure it.
private struct CardHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Place photo loaded via `GooglePlacesService` (media endpoint needs API-key headers, so `AsyncImage` can't fetch it).
private struct PlacePhotoHeader: View {
    let resource: String
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Theme.fillSubtle)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            }
        }
        .frame(height: 120)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.pill, style: .continuous))
        // Bottom scrim so the header text below still reads against a bright photo.
        .overlay(alignment: .bottom) {
            LinearGradient(colors: [.clear, .black.opacity(0.45)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 44)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.pill, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.pill, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
        .allowsHitTesting(false)  // scaledToFill overflow is clipped visually but would still eat taps above the card
        .task(id: resource) {
            image = nil  // reset so switching places never keeps the previous photo
            guard let data = try? await GooglePlacesService.shared.photoData(resource: resource,
                                                                            maxWidthPx: 800) else { return }
            // Decode off the main actor: UIImage(data:) defers the real work to draw time, which lands on the main thread.
            let loaded = await Task.detached(priority: .userInitiated) {
                UIImage(data: data)?.preparingForDisplay()
            }.value
            guard let loaded, !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.25)) { image = loaded }
        }
    }
}
